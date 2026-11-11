require "fileutils"

require_relative "auto_pull_policy"

# Runs Hacker News pulls inside the Rails web process.
#
# tmp/auto-pull.enabled stays the source of truth: the dashboard writes it, and
# this supervisor pulls as soon as it appears, then once per interval until it
# is removed. A pid lock keeps a second web process on the same checkout from
# pulling alongside the first.
#
# Every tick asks AutoPull::Policy first. The policy state (spend, summaries,
# breaker) lives in tmp/auto-pull.state.json so a restart keeps the day's
# counters and an open breaker; a :config latch is deliberately cleared on boot
# because it belongs to the process that saw the bad configuration.
class AutoPullSupervisor
  DEFAULT_INTERVAL = 60
  # How often a disabled (or not yet due) supervisor looks for the flag again.
  POLL_SECONDS = 0.5

  def initialize(runner:, flag_path:, lock_path:, interval: DEFAULT_INTERVAL,
    clock: -> { Time.now.utc }, err: $stderr, state_path: nil, budget: nil)
    @runner = runner
    @flag_path = flag_path.to_s
    @lock_path = lock_path.to_s
    @state_path = (state_path || File.join(File.dirname(@flag_path), "auto-pull.state.json")).to_s
    @interval = interval
    @clock = clock
    @err = err
    @budget = budget || AutoPull::Budget.from_env
    @budget_from_env = budget.nil?
    @store = AutoPull::StateStore.new(@state_path)
    @mutex = Mutex.new
    @policy_mutex = Mutex.new
    @wake = ConditionVariable.new
    @running = false
    @in_flight = false
    @pending = false
    @next_at = nil
    @last_run_at = nil
    @last_error = nil
    @reason = :ok
    @retry_at = nil
    @lock_file = nil
    @thread = nil
    @policy_state = load_policy_state
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

  def policy_state
    @policy_mutex.synchronize { @policy_state.dup }
  end

  # Extra fields ride along with the existing worker payload so the dashboard
  # can say "paused: daily budget" without new UI structure.
  def state
    @mutex.synchronize do
      policy = @policy_mutex.synchronize do
        { spent_usd: @policy_state["spent_usd"], summaries: @policy_state["summaries"],
          failures: @policy_state["failures"], day: @policy_state["day"] }
      end

      {
        running: @running,
        last_run_at: @last_run_at&.utc&.iso8601,
        last_error: @last_error,
        in_flight: @in_flight,
        reason: @reason.to_s,
        retry_at: @retry_at&.utc&.iso8601,
        spent_usd: policy[:spent_usd],
        summaries: policy[:summaries],
        failures: policy[:failures],
        day: policy[:day]
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

    now = @clock.call
    # An env-driven budget re-reads its Neo4j signature each tick, so fixing a
    # wrong password releases a :config latch without restarting the process.
    @budget.config_signature = AutoPull::Budget.signature(ENV) if @budget_from_env
    state = policy_state
    decision = AutoPull::Policy.decide(state: state, now: now, budget: @budget)
    return skip_run(decision, now) if decision[:action] == :skip

    meter = AutoPull::Meter.new(state: state, budget: @budget)
    result = nil
    error = nil
    begin
      result = call_runner(meter)
    rescue StandardError => exception
      error = exception
    end

    outcome = normalize_outcome(result, error)
    finished_at = @clock.call
    @mutex.synchronize do
      @last_run_at = finished_at
      @last_error = outcome[:failure] && outcome[:failure][:message]
      @next_at = @last_run_at + @interval
    end
    record_outcome(meter, outcome, finished_at)
  rescue StandardError => exception
    @mutex.synchronize do
      @last_run_at = @clock.call
      @last_error = "#{exception.class}: #{exception.message}"
    end
  ensure
    @mutex.synchronize { @in_flight = false }
  end

  # Procs, lambdas and callables all work; a runner that accepts an argument
  # gets the meter so it can stop mid-list at the cap.
  def call_runner(meter)
    arity = @runner.respond_to?(:arity) ? @runner.arity : @runner.method(:call).arity
    arity.zero? ? @runner.call : @runner.call(meter)
  end

  def normalize_outcome(result, error)
    if error
      return {
        summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil,
        failure: {
          kind: AutoPull::Failure.classify(error),
          message: "#{error.class}: #{error.message}",
          retry_after: AutoPull::Failure.retry_after(error)
        }
      }
    end

    case result
    when nil
      { summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil, failure: nil }
    when Hash
      failure = result[:failure]
      {
        summaries: result[:summaries].to_i,
        cost_usd: result[:cost_usd].to_f,
        new_stories: result[:new_stories].to_i,
        stopped: result[:stopped],
        failure: failure && {
          kind: failure[:kind].to_s.empty? ? "transient" : failure[:kind].to_s,
          message: failure[:message].to_s,
          retry_after: failure[:retry_after]
        }
      }
    else
      code = result.respond_to?(:to_i) ? result.to_i : 0
      return { summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil, failure: nil } if code.zero?

      {
        summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil,
        failure: { kind: "transient", message: "Pull exited with status #{code}", retry_after: nil }
      }
    end
  end

  def skip_run(decision, now)
    state = AutoPull::Policy.roll_day(policy_state, now)
    retry_at = decision[:retry_at]
    @mutex.synchronize { @next_at = retry_at || (now + @interval) }
    persist(state, decision[:reason], retry_at)
  end

  def record_outcome(meter, outcome, now)
    state = AutoPull::Policy.roll_day(policy_state, now)
    summaries = meter.summaries.positive? ? meter.summaries : outcome[:summaries].to_i
    cost_usd = meter.cost_usd.positive? ? meter.cost_usd : outcome[:cost_usd].to_f

    state = state.merge(
      "summaries" => state["summaries"].to_i + summaries,
      "spent_usd" => (state["spent_usd"].to_f + cost_usd).round(6)
    )

    retry_at = nil
    failure = outcome[:failure]
    if failure.nil?
      state = state.merge("failures" => 0, "open_until" => nil,
        "last_failure_kind" => nil, "last_error" => nil)
      reason = outcome[:stopped].to_s == "budget" ? :budget : :ok
    elsif failure[:kind].to_s == "config"
      state = state.merge("last_failure_kind" => "config",
        "config_signature" => @budget.config_signature,
        "open_until" => nil, "last_error" => failure[:message])
      reason = :config
    else
      failures = state["failures"].to_i + 1
      cooldown = [AutoPull::Policy.cooldown_for(failures), failure[:retry_after].to_i].max
      retry_at = now + cooldown
      state = state.merge("failures" => failures, "last_failure_kind" => "transient",
        "open_until" => retry_at.utc.iso8601, "last_error" => failure[:message])
      reason = :backoff
    end

    persist(state, reason, retry_at)
  end

  def persist(state, reason, retry_at)
    @store.save(state)
    @policy_mutex.synchronize do
      @policy_state = state
      @reason = reason
      @retry_at = retry_at
    end
  rescue StandardError => error
    @err&.puts "Auto-pull supervisor could not save #{@state_path}: #{error.message}"
  end

  # Budget counters and a transient breaker survive a restart. A :config latch
  # does not: it was the previous process's verdict on its own configuration.
  def load_policy_state
    state = @store.load
    if state["last_failure_kind"].to_s == "config"
      state = state.merge("last_failure_kind" => nil, "open_until" => nil,
        "config_signature" => nil)
    end
    AutoPull::Policy.roll_day(state, @clock.call)
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
