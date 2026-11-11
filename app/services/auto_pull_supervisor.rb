require "fileutils"

# Runs Hacker News pulls inside the Rails web process.
#
# tmp/auto-pull.enabled stays the source of truth: the dashboard writes it, and
# this supervisor pulls as soon as it appears, then once per interval until it
# is removed. A pid lock keeps a second web process on the same checkout from
# pulling alongside the first.
class AutoPullSupervisor
  DEFAULT_INTERVAL = 60
  # How often a disabled (or not yet due) supervisor looks for the flag again.
  POLL_SECONDS = 0.5

  def initialize(runner:, flag_path:, lock_path:, interval: DEFAULT_INTERVAL,
    clock: -> { Time.now.utc }, err: $stderr)
    @runner = runner
    @flag_path = flag_path.to_s
    @lock_path = lock_path.to_s
    @interval = interval
    @clock = clock
    @err = err
    @mutex = Mutex.new
    @wake = ConditionVariable.new
    @running = false
    @in_flight = false
    @pending = false
    @next_at = nil
    @last_run_at = nil
    @last_error = nil
    @lock_file = nil
    @thread = nil
  end

  # Acquires the pid lock and starts the supervision thread. Returns false when
  # another process already owns the lock.
  def start
    return false if @mutex.synchronize { @running }
    return false unless acquire_lock

    @mutex.synchronize do
      @running = true
      @pending = enabled?
      @next_at = nil
    end
    @thread = Thread.new { supervise }
    true
  rescue StandardError => error
    @err&.puts "Auto-pull supervisor could not start: #{error.message}"
    release_lock
    false
  end

  def stop
    thread = @mutex.synchronize do
      @running = false
      @pending = false
      @wake.broadcast
      @thread
    end
    thread&.join(10)
    @mutex.synchronize { @thread = nil }
    release_lock
    true
  end

  def running?
    @mutex.synchronize { @running }
  end

  def in_flight?
    @mutex.synchronize { @in_flight }
  end

  def enabled?
    File.file?(@flag_path)
  end

  def state
    @mutex.synchronize do
      {
        running: @running,
        last_run_at: @last_run_at&.utc&.iso8601,
        last_error: @last_error,
        in_flight: @in_flight
      }
    end
  end

  # Wakes the loop so an enabled flag is honored at once. A trigger that lands
  # while a pull is in flight is skipped rather than queued.
  def trigger
    @mutex.synchronize do
      return false if !@running || @in_flight

      @pending = true
      @wake.broadcast
      true
    end
  end

  private

  def supervise
    loop do
      wait_for_work
      break unless @mutex.synchronize { @running }
      next unless enabled?

      @mutex.synchronize { @pending = false }
      run_pull
    end
  end

  def wait_for_work
    @mutex.synchronize do
      loop do
        return unless @running
        return if @pending

        unless enabled?
          @next_at = nil
          @wake.wait(@mutex, POLL_SECONDS)
          next
        end

        @next_at ||= @clock.call + @interval
        remaining = @next_at - @clock.call
        return if remaining <= 0

        @wake.wait(@mutex, [remaining, POLL_SECONDS].min)
      end
    end
  end

  def run_pull
    @mutex.synchronize do
      return if @in_flight

      @in_flight = true
    end

    result = nil
    error = nil
    begin
      result = @runner.call
    rescue StandardError => exception
      error = "#{exception.class}: #{exception.message}"
    end

    @mutex.synchronize do
      @last_run_at = @clock.call
      @last_error = error
      if @last_error.nil? && result.respond_to?(:to_i) && result.to_i != 0
        @last_error = "Pull exited with status #{result}"
      end
      @next_at = @last_run_at + @interval
    end
  rescue StandardError => exception
    @mutex.synchronize do
      @last_run_at = @clock.call
      @last_error = "#{exception.class}: #{exception.message}"
    end
  ensure
    @mutex.synchronize { @in_flight = false }
  end

  # The lock file holds the owning pid and stays locked for the life of the
  # process. A crashed owner's lock is released by the OS, so a fresh start can
  # take it and overwrite the stale pid.
  def acquire_lock
    return true unless @lock_file.nil?

    FileUtils.mkdir_p(File.dirname(@lock_path))
    file = File.open(@lock_path, File::RDWR | File::CREAT, 0o644)
    unless file.flock(File::LOCK_EX | File::LOCK_NB)
      file.close
      @err&.puts "Auto-pull supervisor: #{@lock_path} is held by another process; not pulling."
      return false
    end

    file.truncate(0)
    file.write(Process.pid.to_s)
    file.flush
    @lock_file = file
    true
  end

  def release_lock
    file = @lock_file
    @lock_file = nil
    return unless file

    file.flock(File::LOCK_UN)
    file.close
  rescue StandardError
    nil
  end
end
