require "fileutils"
require "json"
require "rack/mock"
require "stringio"
require "tmpdir"
require "timeout"

require_relative "../../config/environment"
require_relative "../../app/services/auto_pull"
require_relative "../../app/services/auto_pull_supervisor"
require_relative "../support/assertions"

include TestReport

# A stand-in for one ingestion pull. It records every call and can block on a
# gate so a test can observe an in-flight pull without racing the supervisor.
class RecordingRunner
  def initialize(hold: false)
    @mutex = Mutex.new
    @runs = 0
    @started = Queue.new
    @gate = hold ? Queue.new : nil
  end

  def call
    @mutex.synchronize { @runs += 1 }
    @started << :started
    @gate.pop if @gate
    0
  end

  def runs
    @mutex.synchronize { @runs }
  end

  def wait_for_start(timeout: 5)
    Timeout.timeout(timeout) { @started.pop }
  end

  def release
    @gate&.push(:go)
  end
end

def wait_until(timeout: 5, message: "condition was not met")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.01
  end
end

def auto_pull_request(request, host, enabled)
  request.put("/auto-pull", host.merge(
    "CONTENT_TYPE" => "application/json",
    "HTTP_ORIGIN" => "http://127.0.0.1:3000",
    input: JSON.generate(enabled: enabled)
  ))
end

# Runs the block against a supervisor wired to a throwaway flag and lock file,
# with the fake runner and a short interval so nothing waits 60 seconds.
def with_supervisor(interval:, runner:, clock: -> { Time.now.utc })
  directory = Dir.mktmpdir("newsagg-auto-pull-")
  flag_path = File.join(directory, "auto-pull.enabled")
  lock_path = File.join(directory, "auto-pull-worker.lock")
  supervisor = AutoPullSupervisor.new(
    runner: runner, flag_path: flag_path, lock_path: lock_path,
    interval: interval, clock: clock
  )
  config = Rails.application.config.x
  previous = [config.auto_pull_flag_path, config.auto_pull_lock_path, config.auto_pull_supervisor]
  config.auto_pull_flag_path = flag_path
  config.auto_pull_lock_path = lock_path
  config.auto_pull_supervisor = supervisor
  yield supervisor, flag_path
ensure
  supervisor&.stop
  if config
    config.auto_pull_flag_path, config.auto_pull_lock_path, config.auto_pull_supervisor = previous
  end
  FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
end

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }

# Boots the config.ru entry point against throwaway flag, lock and state paths
# so a test exercises the real boot path without touching the checkout's tmp/.
def with_boot_paths
  previous = nil
  directory = Dir.mktmpdir("newsagg-auto-pull-boot-")
  paths = {
    flag: File.join(directory, "auto-pull.enabled"),
    lock: File.join(directory, "auto-pull-worker.lock"),
    state: File.join(directory, "auto-pull.state.json")
  }
  config = Rails.application.config.x
  previous = [config.auto_pull_flag_path, config.auto_pull_lock_path,
    config.auto_pull_state_path, config.auto_pull_supervisor]
  config.auto_pull_flag_path = paths[:flag]
  config.auto_pull_lock_path = paths[:lock]
  config.auto_pull_state_path = paths[:state]
  config.auto_pull_supervisor = nil
  yield paths
ensure
  config&.auto_pull_supervisor&.stop
  if previous
    config.auto_pull_flag_path, config.auto_pull_lock_path,
      config.auto_pull_state_path, config.auto_pull_supervisor = previous
  end
  FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
end

TestReport.run do
  check "enabling Auto-pull runs a pull immediately instead of waiting for the interval" do
    runner = RecordingRunner.new
    with_supervisor(interval: 600, runner: runner) do |supervisor, flag_path|
      assert(supervisor.start, "the supervisor refused to start")
      assert(!File.exist?(flag_path), "the flag should start disabled")

      response = auto_pull_request(request, host, true)
      assert(response.status == 200, "enabling failed with #{response.status}")

      runner.wait_for_start
      assert(runner.runs == 1, "expected the pull to start at once, got #{runner.runs} run(s)")
      sleep 0.1
      assert(runner.runs == 1, "expected a single pull, got #{runner.runs} run(s)")
    end
  end

  check "the next tick runs another pull while Auto-pull stays on" do
    runner = RecordingRunner.new
    with_supervisor(interval: 0.15, runner: runner) do |supervisor, _flag_path|
      assert(supervisor.start, "the supervisor refused to start")
      auto_pull_request(request, host, true)

      runner.wait_for_start
      runner.wait_for_start
      assert(runner.runs >= 2, "expected a repeated pull, got #{runner.runs} run(s)")
    end
  end

  check "turning Auto-pull off stops further pulls" do
    runner = RecordingRunner.new
    with_supervisor(interval: 0.05, runner: runner) do |supervisor, _flag_path|
      assert(supervisor.start, "the supervisor refused to start")
      auto_pull_request(request, host, true)
      runner.wait_for_start
      runner.wait_for_start

      response = auto_pull_request(request, host, false)
      assert(response.status == 200, "disabling failed with #{response.status}")
      wait_until { !supervisor.state[:in_flight] }
      sleep 0.15
      settled = runner.runs
      sleep 0.4
      assert(runner.runs == settled, "pulls continued after disabling (#{settled} then #{runner.runs})")
    end
  end

  check "a trigger during an in-flight pull is skipped instead of queued" do
    runner = RecordingRunner.new(hold: true)
    with_supervisor(interval: 600, runner: runner) do |supervisor, _flag_path|
      assert(supervisor.start, "the supervisor refused to start")
      auto_pull_request(request, host, true)
      runner.wait_for_start
      assert(supervisor.state[:in_flight], "the worker did not report the pull as in flight")

      response = auto_pull_request(request, host, true)
      assert(response.status == 200, "the second trigger failed with #{response.status}")
      assert(!supervisor.trigger, "a trigger during an in-flight pull must be skipped")
      sleep 0.1
      assert(runner.runs == 1, "expected one pull, got #{runner.runs} run(s)")

      runner.release
      wait_until { !supervisor.state[:in_flight] }
      sleep 0.1
      assert(runner.runs == 1, "the skipped trigger was queued (#{runner.runs} runs)")
    end
  end

  check "GET /auto-pull reports the toggle and the worker state" do
    clock = -> { Time.utc(2026, 11, 11, 17, 30, 0) }
    runner = RecordingRunner.new
    with_supervisor(interval: 600, runner: runner, clock: clock) do |supervisor, _flag_path|
      idle = JSON.parse(request.get("/auto-pull", host).body)
      assert(idle["enabled"] == false, "expected the toggle to start off")
      assert(idle.dig("worker", "running") == false, "expected no running worker before boot")

      assert(supervisor.start, "the supervisor refused to start")
      auto_pull_request(request, host, true)
      runner.wait_for_start
      wait_until { supervisor.state[:last_run_at] }

      payload = JSON.parse(request.get("/auto-pull", host).body)
      assert(payload["enabled"] == true, "expected the toggle to report on")
      worker = payload["worker"]
      assert(worker["running"] == true, "expected a running worker")
      assert(worker["in_flight"] == false, "expected the pull to have finished")
      assert(worker["last_run_at"] == "2026-11-11T17:30:00Z",
        "last_run_at was #{worker["last_run_at"].inspect}")
      assert(worker["last_error"].nil?, "expected no error, got #{worker["last_error"].inspect}")
    end
  end

  check "the dashboard shows the last pull time beside the toggle" do
    clock = -> { Time.utc(2026, 11, 11, 17, 30, 0) }
    runner = RecordingRunner.new
    with_supervisor(interval: 600, runner: runner, clock: clock) do |supervisor, _flag_path|
      assert(supervisor.start, "the supervisor refused to start")
      auto_pull_request(request, host, true)
      runner.wait_for_start
      wait_until { supervisor.state[:last_run_at] }

      page = request.get("/", host)
      assert(page.body.include?("id=\"auto-pull-status\""), "the toggle has no status line")
      assert(page.body.include?("Last pull"), "the last pull time is not shown")
    end
  end

  check "a second supervisor refuses to start while the lock is held" do
    directory = Dir.mktmpdir("newsagg-auto-pull-")
    flag_path = File.join(directory, "auto-pull.enabled")
    lock_path = File.join(directory, "auto-pull-worker.lock")
    first = AutoPullSupervisor.new(runner: -> { 0 }, flag_path: flag_path, lock_path: lock_path, interval: 600)
    second = AutoPullSupervisor.new(runner: -> { 0 }, flag_path: flag_path, lock_path: lock_path, interval: 600)
    begin
      assert(first.start, "the first supervisor refused to start")
      assert(!second.start, "a second supervisor started while the lock was held")
      assert(!second.running?, "the second supervisor reports running")
    ensure
      first.stop
      second.stop
      FileUtils.remove_entry(directory)
    end
  end

  check "a stale pid lock is reclaimed on start" do
    directory = Dir.mktmpdir("newsagg-auto-pull-")
    flag_path = File.join(directory, "auto-pull.enabled")
    lock_path = File.join(directory, "auto-pull-worker.lock")
    File.write(lock_path, "999999")
    supervisor = AutoPullSupervisor.new(runner: -> { 0 }, flag_path: flag_path, lock_path: lock_path, interval: 600)
    begin
      assert(supervisor.start, "the supervisor refused a stale lock")
      assert(supervisor.running?, "the supervisor is not running")
      supervisor.stop
      assert(File.read(lock_path).strip == Process.pid.to_s, "the lock still holds a dead pid")
    ensure
      supervisor.stop
      FileUtils.remove_entry(directory)
    end
  end

  check "a leftover Auto-pull flag is cleared on boot before anything pulls" do
    with_boot_paths do |paths|
      File.write(paths[:flag], "")
      runner = RecordingRunner.new
      log = StringIO.new

      supervisor = AutoPull.boot(root: Rails.root, env: {}, runner: runner,
        interval: 600, err: log)
      Rails.application.config.x.auto_pull_supervisor = supervisor

      assert(supervisor, "boot did not start a supervisor")
      assert(!File.exist?(paths[:flag]), "the leftover flag survived boot")
      assert(!supervisor.enabled?, "the supervisor reports Auto-pull on after boot")
      assert(log.string.include?("Auto-pull reset to off on boot"),
        "boot did not log the reset (#{log.string.inspect})")

      sleep 0.3
      assert(runner.runs.zero?, "boot pulled with a leftover flag (#{runner.runs} run(s))")
      assert(supervisor.state[:last_run_at].nil?, "a pull ran during boot")

      payload = JSON.parse(request.get("/auto-pull", host).body)
      worker = payload["worker"]
      assert(payload["enabled"] == false, "GET /auto-pull reports the toggle on")
      assert(worker["running"] == true, "GET /auto-pull reports no running worker")
      assert(worker["reason"] == "ok", "worker reason was #{worker["reason"].inspect}")
      assert(worker["last_error"].nil?, "worker error was #{worker["last_error"].inspect}")
      assert(worker["last_run_at"].nil?, "worker last_run_at was #{worker["last_run_at"].inspect}")
    end
  end

  check "boot leaves the Auto-pull policy state untouched" do
    with_boot_paths do |paths|
      seeded = {
        "day" => AutoPull::Policy.day_for(Time.now),
        "spent_usd" => 0.0431,
        "summaries" => 7,
        "failures" => 2,
        "open_until" => (Time.now.utc + 300).iso8601,
        "last_failure_kind" => "transient",
        "last_error" => "Hacker News returned HTTP 503",
        "config_signature" => "abc123"
      }
      File.write(paths[:state], JSON.pretty_generate(seeded))
      runner = RecordingRunner.new

      supervisor = AutoPull.boot(root: Rails.root, env: {}, runner: runner,
        interval: 600, err: StringIO.new)
      Rails.application.config.x.auto_pull_supervisor = supervisor
      assert(supervisor, "boot did not start a supervisor")

      stored = JSON.parse(File.read(paths[:state]))
      assert(stored == seeded, "boot rewrote the policy state (#{stored.inspect})")

      worker = supervisor.state
      assert(worker[:spent_usd].to_f == 0.0431, "boot reset spent_usd to #{worker[:spent_usd]}")
      assert(worker[:summaries].to_i == 7, "boot reset summaries to #{worker[:summaries]}")
      assert(worker[:failures].to_i == 2, "boot reset failures to #{worker[:failures]}")
    end
  end

  check "NEWSAGG_AUTO_PULL=0 boots no supervisor and no puller" do
    with_boot_paths do |paths|
      File.write(paths[:flag], "")
      runner = RecordingRunner.new

      supervisor = AutoPull.boot(root: Rails.root, env: { "NEWSAGG_AUTO_PULL" => "0" },
        runner: runner, interval: 600, err: StringIO.new)
      assert(supervisor.nil?, "boot started a supervisor despite NEWSAGG_AUTO_PULL=0")
      assert(!File.exist?(paths[:lock]), "a puller took the lock despite NEWSAGG_AUTO_PULL=0")

      sleep 0.2
      assert(runner.runs.zero?, "an opted-out process pulled")
    end
  end

  check "after the boot reset, enabling Auto-pull still pulls once at once" do
    with_boot_paths do |paths|
      File.write(paths[:flag], "")
      runner = RecordingRunner.new

      supervisor = AutoPull.boot(root: Rails.root, env: {}, runner: runner,
        interval: 600, err: StringIO.new)
      Rails.application.config.x.auto_pull_supervisor = supervisor
      assert(supervisor, "boot did not start a supervisor")

      sleep 0.2
      assert(runner.runs.zero?, "boot pulled before anyone enabled Auto-pull")

      response = auto_pull_request(request, host, true)
      assert(response.status == 200, "enabling failed with #{response.status}")
      runner.wait_for_start
      sleep 0.2
      assert(runner.runs == 1, "expected one immediate pull, got #{runner.runs} run(s)")
      assert(File.file?(paths[:flag]), "enabling did not write the flag")
    end
  end
end
