ENV["RAILS_ENV"] = "test"

require "fileutils"
require "json"
require "rack/mock"
require "stringio"
require "timeout"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../../app/services/auto_pull_supervisor"
require_relative "../../app/services/ingest_batch"
require_relative "../support/assertions"
require_relative "../support/signed_in"

include TestReport

# A settable clock so the policy and the supervisor never sleep for real.
class ManualClock
  def initialize(time)
    @time = time
  end

  def call
    @time
  end

  def advance(seconds)
    @time += seconds
  end
end

# Counts runs and delegates the work to a block. Records summaries and spend
# through the meter the supervisor hands over, exactly like a real batch run.
class ScriptedRunner
  def initialize(&block)
    @block = block || ->(_meter) { { summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil, failure: nil } }
    @mutex = Mutex.new
    @runs = 0
  end

  def call(meter = nil)
    @mutex.synchronize { @runs += 1 }
    @block.call(meter)
  end

  def runs
    @mutex.synchronize { @runs }
  end
end

# Returns a fixed provider payload, including the usage block DeepSeek sends.
class UsageHttp
  def initialize(usage: nil)
    @usage = usage
  end

  def post_json(url, headers:, body:, timeout:)
    raise "Unexpected summary URL: #{url}" unless url == "https://llm.example/api/chat/completions"
    raise "Missing bearer token" unless headers["authorization"] == "Bearer test-secret-key"

    content = JSON.generate(
      summary: "The fixture article describes a metered summarization call. " \
        "It captures the provider usage block before pricing the request. " \
        "No article length is ever used to guess the cost.",
      depth: "Overview",
      topics: ["Software Engineering"]
    )
    payload = { "choices" => [{ "message" => { "content" => content } }] }
    payload["usage"] = @usage if @usage
    JSON.generate(payload)
  end
end

def wait_until(timeout: 5, message: "condition was not met")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.01
  end
end

def read_state(path)
  return {} unless File.file?(path)

  JSON.parse(File.read(path))
end

def settled(supervisor)
  wait_until { !supervisor.state[:in_flight] }
end

# Runs the block against a supervisor wired to throwaway flag, lock and policy
# state files, a fixed budget, and the injected clock.
def with_budget_supervisor(clock:, runner:, state: nil, interval: 600,
  budget: AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0))
  directory = Dir.mktmpdir("newsagg-auto-pull-budget-")
  flag_path = File.join(directory, "auto-pull.enabled")
  lock_path = File.join(directory, "auto-pull-worker.lock")
  state_path = File.join(directory, "auto-pull.state.json")
  File.write(state_path, JSON.generate(state)) if state

  supervisor = AutoPullSupervisor.new(
    runner: runner, flag_path: flag_path, lock_path: lock_path,
    interval: interval, clock: clock, state_path: state_path, budget: budget,
    err: StringIO.new
  )
  config = Rails.application.config.x
  previous = [config.auto_pull_flag_path, config.auto_pull_lock_path, config.auto_pull_supervisor]
  config.auto_pull_flag_path = flag_path
  config.auto_pull_lock_path = lock_path
  config.auto_pull_supervisor = supervisor

  yield supervisor, { flag_path: flag_path, lock_path: lock_path, state_path: state_path, dir: directory }
ensure
  supervisor&.stop
  if config
    config.auto_pull_flag_path, config.auto_pull_lock_path, config.auto_pull_supervisor = previous
  end
  FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
end

def fresh_state(clock, overrides = {})
  {
    "day" => AutoPull::Policy.day_for(clock.call),
    "spent_usd" => 0.0, "summaries" => 0, "failures" => 0,
    "open_until" => nil, "last_failure_kind" => nil, "last_error" => nil
  }.merge(overrides)
end

request = Rack::MockRequest.new(Rails.application)
# The auto-pull endpoint is behind the sign-in gate; the cookie makes this
# request the one a signed-in dashboard would send.
host = { "HTTP_HOST" => "127.0.0.1:3000", "HTTP_COOKIE" => sign_in_cookie }

TestReport.run do
  check "an exhausted daily budget makes decide skip with :budget and blocks the runner" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    budget = AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0)
    state = fresh_state(clock, "summaries" => 2)
    decision = AutoPull::Policy.decide(state: state, now: clock.call, budget: budget)
    assert(decision[:action] == :skip, "expected a skip, got #{decision[:action].inspect}")
    assert(decision[:reason] == :budget, "expected :budget, got #{decision[:reason].inspect}")

    runner = ScriptedRunner.new
    with_budget_supervisor(clock: clock, runner: runner, state: state, budget: budget) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { supervisor.state[:reason] == "budget" }
      sleep 0.1
      assert(runner.runs.zero?, "the runner ran #{runner.runs} time(s) with no budget left")
    end
  end

  check "a run that hits the cap mid-list stops at the cap and reports :budget" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    budget = AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0)
    runner = ScriptedRunner.new do |meter|
      done = 0
      stopped = nil
      5.times do
        if meter.exhausted?
          stopped = :budget
          break
        end
        meter.record(summaries: 1, cost_usd: 0.001)
        done += 1
      end
      { summaries: done, cost_usd: done * 0.001, new_stories: done, stopped: stopped, failure: nil }
    end

    with_budget_supervisor(clock: clock, runner: runner, budget: budget) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { read_state(paths[:state_path])["summaries"] == 2 }
      settled(supervisor)
      state = read_state(paths[:state_path])
      assert(state["summaries"] == 2, "expected the run to stop at 2 summaries, got #{state["summaries"]}")
      assert(state["failures"].zero?, "a budget stop must not count as a failure (#{state["failures"]})")
      assert(supervisor.state[:reason] == "budget", "reason was #{supervisor.state[:reason].inspect}")
    end
  end

  check "the spend cap stops a run before the dollar limit is crossed" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    budget = AutoPull::Budget.new(expected_daily_stories: 1_000, max_usd: 0.1)
    runner = ScriptedRunner.new do |meter|
      done = 0
      stopped = nil
      10.times do
        if meter.exhausted?
          stopped = :budget
          break
        end
        meter.record(summaries: 1, cost_usd: 0.06)
        done += 1
      end
      { summaries: done, cost_usd: done * 0.06, new_stories: done, stopped: stopped, failure: nil }
    end

    with_budget_supervisor(clock: clock, runner: runner, budget: budget) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { read_state(paths[:state_path])["summaries"] == 2 }
      settled(supervisor)
      state = read_state(paths[:state_path])
      assert(state["spent_usd"] > 0.1, "spent #{state["spent_usd"]}, expected the cap to trip")
      assert(state["failures"].zero?, "a spend stop must not count as a failure")
      assert(supervisor.state[:reason] == "budget", "reason was #{supervisor.state[:reason].inspect}")
    end
  end

  check "a stored day rollover resets spend and summaries before deciding" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 4, 0, 0))
    today = AutoPull::Policy.day_for(clock.call)
    state = fresh_state(clock, "day" => AutoPull::Policy.day_for(clock.call - 86_400),
      "summaries" => 999, "spent_usd" => 9.0, "failures" => 0)
    budget = AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 0.1)
    decision = AutoPull::Policy.decide(state: state, now: clock.call, budget: budget)
    assert(decision[:action] == :run, "a stale day must not stay capped (#{decision[:reason]})")

    runner = ScriptedRunner.new
    with_budget_supervisor(clock: clock, runner: runner, state: state, budget: budget) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { runner.runs == 1 }
      settled(supervisor)
      stored = read_state(paths[:state_path])
      assert(stored["day"] == today, "the stored day was #{stored["day"].inspect}")
      assert(stored["summaries"].zero?, "summaries were not reset (#{stored["summaries"]})")
      assert(stored["spent_usd"].zero?, "spend was not reset (#{stored["spent_usd"]})")
    end
  end

  check "an HTTP 401 from Neo4j latches :config and later ticks do not run" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    runner = ScriptedRunner.new { raise Archive::Unavailable, "Neo4j returned HTTP 401" }

    with_budget_supervisor(clock: clock, runner: runner) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { runner.runs == 1 }
      wait_until { supervisor.state[:reason] == "config" }

      3.times do
        settled(supervisor)
        clock.advance(600)
        supervisor.trigger
        sleep 0.05
      end
      assert(runner.runs == 1, "a latched :config breaker kept retrying (#{runner.runs} runs)")
      stored = read_state(paths[:state_path])
      assert(stored["last_failure_kind"] == "config", "last_failure_kind was #{stored["last_failure_kind"].inspect}")
      assert(stored["open_until"].nil?, "a config latch must not schedule a timed retry")

      changed_env = AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0,
        config_signature: "different-credentials")
      decision = AutoPull::Policy.decide(state: stored, now: clock.call, budget: changed_env)
      assert(decision[:action] == :run,
        "changing the Neo4j env values must release the latch (#{decision[:reason]})")
    end
  end

  check "transient failures back off 60s, 5m, 15m, 30m and then half-open" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    runner = ScriptedRunner.new { raise Archive::Unavailable, "Neo4j returned HTTP 503" }

    with_budget_supervisor(clock: clock, runner: runner) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")

      [60, 300, 900, 1800].each_with_index do |cooldown, index|
        wait_until { runner.runs == index + 1 }
        settled(supervisor)
        stored = read_state(paths[:state_path])
        open_until = Time.iso8601(stored["open_until"])
        assert((open_until - clock.call - cooldown).abs < 1.5,
          "after #{index + 1} failure(s) the cooldown was #{open_until - clock.call}s, expected #{cooldown}s")
        assert(stored["failures"] == index + 1, "failures were #{stored["failures"]}")

        if index < 3
          supervisor.trigger
          sleep 0.05
          assert(runner.runs == index + 1, "the breaker ran while it was open")
        end
        clock.advance(cooldown + 1)
      end

      supervisor.trigger
      wait_until { runner.runs == 5 }
      settled(supervisor)
      assert(supervisor.state[:reason] == "backoff" || supervisor.state[:reason] == "ok",
        "unexpected reason after the half-open probe: #{supervisor.state[:reason].inspect}")
    end
  end

  check "half-open success closes the breaker and clears failures" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    open_until = clock.call - 1
    state = fresh_state(clock, "failures" => 2, "open_until" => open_until.utc.iso8601,
      "last_failure_kind" => "transient")
    runner = ScriptedRunner.new

    with_budget_supervisor(clock: clock, runner: runner, state: state) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { runner.runs == 1 }
      settled(supervisor)
      stored = read_state(paths[:state_path])
      assert(stored["failures"].zero?, "failures were not cleared (#{stored["failures"]})")
      assert(stored["open_until"].nil?, "the breaker stayed open")
      assert(stored["last_failure_kind"].nil?, "last_failure_kind was not cleared")
      assert(supervisor.state[:reason] == "ok", "reason was #{supervisor.state[:reason].inspect}")
    end
  end

  check "half-open failure re-opens with the next cooldown" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    state = fresh_state(clock, "failures" => 2, "open_until" => (clock.call - 1).utc.iso8601,
      "last_failure_kind" => "transient")
    runner = ScriptedRunner.new { raise Archive::Unavailable, "Connection refused" }

    with_budget_supervisor(clock: clock, runner: runner, state: state) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { runner.runs == 1 }
      settled(supervisor)
      stored = read_state(paths[:state_path])
      assert(stored["failures"] == 3, "failures were #{stored["failures"]}")
      open_until = Time.iso8601(stored["open_until"])
      assert((open_until - clock.call - 900).abs < 1.5,
        "expected the 15m cooldown, got #{open_until - clock.call}s")
      assert(supervisor.state[:reason] == "backoff", "reason was #{supervisor.state[:reason].inspect}")
    end
  end

  check "a batch with zero new stories is success, not a failure" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    state = fresh_state(clock, "failures" => 3, "open_until" => (clock.call - 1).utc.iso8601,
      "last_failure_kind" => "transient")
    runner = ScriptedRunner.new { { summaries: 0, cost_usd: 0.0, new_stories: 0, stopped: nil, failure: nil } }

    with_budget_supervisor(clock: clock, runner: runner, state: state) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { runner.runs == 1 }
      settled(supervisor)
      stored = read_state(paths[:state_path])
      assert(stored["failures"].zero?, "failures were #{stored["failures"]}")
      assert(stored["open_until"].nil?, "the breaker stayed open")
      assert(supervisor.state[:reason] == "ok", "reason was #{supervisor.state[:reason].inspect}")
    end
  end

  check "policy state round-trips across a supervisor restart" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    runner = ScriptedRunner.new do |meter|
      meter.record(summaries: 3, cost_usd: 0.0042)
      { summaries: 3, cost_usd: 0.0042, new_stories: 2, stopped: nil, failure: nil }
    end

    with_budget_supervisor(clock: clock, runner: runner) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { read_state(paths[:state_path])["summaries"] == 3 }
      supervisor.stop

      restarted = AutoPullSupervisor.new(
        runner: ScriptedRunner.new, flag_path: paths[:flag_path], lock_path: paths[:lock_path],
        interval: 600, clock: clock, state_path: paths[:state_path],
        budget: AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0), err: StringIO.new
      )
      begin
        assert(restarted.state[:summaries] == 3,
          "the restarted supervisor lost the summary count (#{restarted.state[:summaries]})")
        assert((restarted.state[:spent_usd] - 0.0042).abs < 1e-9,
          "the restarted supervisor lost the spend (#{restarted.state[:spent_usd]})")
      ensure
        restarted.stop
      end
    end
  end

  check "GET /auto-pull surfaces the pause reason for the dashboard" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    state = fresh_state(clock, "summaries" => 2)
    with_budget_supervisor(clock: clock, runner: ScriptedRunner.new, state: state) do |supervisor, paths|
      FileUtils.touch(paths[:flag_path])
      assert(supervisor.start, "the supervisor refused to start")
      wait_until { supervisor.state[:reason] == "budget" }

      payload = JSON.parse(request.get("/auto-pull", host).body)
      assert(payload.dig("worker", "reason") == "budget",
        "the worker payload reason was #{payload.dig("worker", "reason").inspect}")
    end
  end

  check "the summarizer prices the provider usage block instead of article length" do
    usage = { "prompt_tokens" => 1_000, "completion_tokens" => 500, "prompt_cache_hit_tokens" => 400 }
    env = {
      "NEWSAGG_SUMMARY_PROVIDER" => "deepseek", "DEEPSEEK_API_KEY" => "test-secret-key",
      "DEEPSEEK_BASE_URL" => "https://llm.example/api/", "DEEPSEEK_MODEL" => "deepseek-chat"
    }
    summarizer = DeepseekSummarizer.new(env: env, http: UsageHttp.new(usage: usage))
    result = summarizer.summarize(
      url: "https://news.example/story", title: "Metered summaries", publisher: "news.example",
      text: "A long article body that would produce a very different estimate if it were used."
    )

    expected = (600 * 0.27 + 400 * 0.07 + 500 * 1.10) / 1_000_000.0
    assert((result["cost_usd"] - expected).abs < 1e-9,
      "cost was #{result["cost_usd"].inspect}, expected #{expected}")
    assert(result.dig("usage", "prompt_tokens") == 1_000, "prompt tokens were not captured")
    assert(result.dig("usage", "completion_tokens") == 500, "completion tokens were not captured")
    assert(result.dig("usage", "prompt_cache_hit_tokens") == 400, "cache hit tokens were not captured")

    bare = DeepseekSummarizer.new(env: env, http: UsageHttp.new).summarize(
      url: "https://news.example/story", title: "Metered summaries", publisher: "news.example",
      text: "A long article body that would produce a very different estimate if it were used."
    )
    assert(bare["cost_usd"].zero?, "cost was estimated without a usage block (#{bare["cost_usd"]})")
  end

  check "the ingestion batch stops mid-list at the cap and leaves the rest" do
    clock = ManualClock.new(Time.utc(2026, 11, 11, 15, 0, 0))
    stories = (1..4).map do |index|
      { "title" => "Story #{index}", "url" => "https://news.example/story-#{index}",
        "source" => "Hacker News", "external_id" => index.to_s }
    end
    summarizing = []
    summarizer = Object.new
    summarizer.define_singleton_method(:summarize) do |url:, title:, publisher:, text:|
      summarizing << url
      { "summary" => "A summary long enough to satisfy the importer contract check in this batch.",
        "depth" => "Overview", "topics" => ["Software Engineering"], "cost_usd" => 0.01 }
    end

    extractor = Object.new
    extractor.define_singleton_method(:extract) do |body, uri, content_type:|
      { text: "An article body long enough to be summarized by the batch.", publisher: uri.hostname,
        published_date: nil }
    end
    extractor.define_singleton_method(:sanitize_title) { |value| value.to_s }
    extractor.define_singleton_method(:sanitize_publisher) { |value, fallback| value.to_s.empty? ? fallback : value }

    hn = Object.new
    hn.define_singleton_method(:archive_keys) { |_rows| [[], []] }
    hn.define_singleton_method(:collect_candidates) { |feed:, limit:, archive_rows:| stories.first(limit) }

    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url| { url: url, body: "<html></html>", content_type: "text/html" } }

    budget = AutoPull::Budget.new(expected_daily_stories: 1, max_usd: 100.0)
    meter = AutoPull::Meter.new(state: fresh_state(clock), budget: budget)
    batch = IngestBatch.new(hn: hn, fetcher: fetcher, summarizer: summarizer,
      extractor: extractor, meter: meter)
    result = batch.run(feed: "new", limit: 4, archive_rows: [])

    assert(result[:budget_stopped] == true, "the batch did not report a budget stop")
    assert(summarizing.length == 2, "expected 2 summaries at the cap, got #{summarizing.length}")
    assert(result[:records].length == 2, "expected 2 records, got #{result[:records].length}")
    assert(result[:failures].empty?, "a budget stop must not record failures")
    assert(meter.summaries == 2, "the meter counted #{meter.summaries} summaries")
  end
end
