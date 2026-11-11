require "digest"
require "fileutils"
require "json"
require "time"

# Spend budget, breaker state and the single gate that decides whether a pull
# may run. Everything here is pure or file-only so it can be tested without
# Neo4j, Hacker News, or the network.
module AutoPull
  # Daily limits. The hard cap is 2x the expected number of new, non-archived
  # stories summarized per day; dollars are a secondary hard stop. Whichever
  # trips first wins.
  class Budget
    DEFAULT_EXPECTED_DAILY_STORIES = 90
    DEFAULT_DAILY_BUDGET_USD = 0.10
    STORY_MULTIPLIER = 2

    attr_reader :expected_daily_stories, :max_usd, :config_signature
    attr_writer :config_signature

    def initialize(expected_daily_stories: DEFAULT_EXPECTED_DAILY_STORIES,
      max_usd: DEFAULT_DAILY_BUDGET_USD, config_signature: "")
      @expected_daily_stories = [expected_daily_stories.to_i, 1].max
      @max_usd = max_usd.to_f
      @config_signature = config_signature.to_s
    end

    def self.from_env(env = ENV)
      new(
        expected_daily_stories: number(env["NEWSAGG_EXPECTED_DAILY_STORIES"], DEFAULT_EXPECTED_DAILY_STORIES),
        max_usd: number(env["NEWSAGG_DAILY_BUDGET_USD"], DEFAULT_DAILY_BUDGET_USD),
        config_signature: signature(env)
      )
    end

    # Identifies the Neo4j credentials the process booted with, so a latched
    # :config breaker reopens by itself when an env value changes.
    def self.signature(env)
      values = [env["NEO4J_HTTP_URL"], env["NEO4J_PASSWORD"], env["NEO4J_USER"]]
      Digest::SHA256.hexdigest(values.map(&:to_s).join("\0"))[0, 16]
    end

    def self.number(value, fallback)
      return fallback if value.nil? || value.to_s.strip.empty?

      Float(value)
    rescue ArgumentError, TypeError
      fallback
    end

    def max_summaries
      expected_daily_stories * STORY_MULTIPLIER
    end

    def exhausted?(state)
      state["summaries"].to_i >= max_summaries || state["spent_usd"].to_f >= max_usd
    end
  end

  # Reads and writes the persisted policy state atomically.
  class StateStore
    DEFAULTS = {
      "day" => nil, "spent_usd" => 0.0, "summaries" => 0, "failures" => 0,
      "open_until" => nil, "last_failure_kind" => nil, "last_error" => nil,
      "config_signature" => nil
    }.freeze

    def initialize(path)
      @path = path.to_s
    end

    attr_reader :path

    # A missing or damaged file starts a fresh day rather than breaking the
    # puller; the file is a policy cache, not the archive.
    def load
      raw = File.read(@path, encoding: "UTF-8")
      parsed = raw.strip.empty? ? {} : JSON.parse(raw)
      return DEFAULTS.dup unless parsed.is_a?(Hash)

      normalize(parsed)
    rescue Errno::ENOENT, JSON::ParserError, SystemCallError
      DEFAULTS.dup
    end

    def save(state)
      FileUtils.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(normalize(state))}\n", mode: "w", encoding: "UTF-8")
      File.rename(temporary, @path)
    end

    private

    def normalize(state)
      merged = DEFAULTS.merge(state.to_h)
      merged.merge(
        "spent_usd" => merged["spent_usd"].to_f,
        "summaries" => merged["summaries"].to_i,
        "failures" => merged["failures"].to_i,
        "day" => merged["day"]&.to_s,
        "open_until" => merged["open_until"]&.to_s,
        "last_failure_kind" => merged["last_failure_kind"]&.to_s,
        "last_error" => merged["last_error"]&.to_s,
        "config_signature" => merged["config_signature"]&.to_s
      )
    end
  end

  # Turns one run's summarized stories and spend into a total. The meter starts
  # from the state already stored for today, so a run stops cleanly mid-list
  # when the day's allowance is gone.
  class Meter
    def initialize(state:, budget:)
      @state = state
      @budget = budget
      @summaries = 0
      @cost_usd = 0.0
    end

    attr_reader :state, :budget, :summaries, :cost_usd

    def record(summaries: 1, cost_usd: 0.0)
      @summaries += summaries.to_i
      @cost_usd += cost_usd.to_f
    end

    def exhausted?
      @budget.exhausted?(cumulative_state)
    end

    def cumulative_state
      @state.merge(
        "summaries" => @state["summaries"].to_i + @summaries,
        "spent_usd" => @state["spent_usd"].to_f + @cost_usd
      )
    end
  end

  # The one place that decides whether the supervisor may pull.
  module Policy
    COOLDOWNS = [60, 300, 900, 1800].freeze

    module_function

    # => {action: :run|:skip, reason: :ok|:budget|:backoff|:config, retry_at: nil|Time}
    def decide(state:, now:, budget:)
      state = roll_day(state, now)

      if config_latched?(state, budget)
        return { action: :skip, reason: :config, retry_at: nil }
      end

      open_until = parse_time(state["open_until"])
      if open_until && now < open_until
        return { action: :skip, reason: :backoff, retry_at: open_until }
      end

      if budget.exhausted?(state)
        return { action: :skip, reason: :budget, retry_at: nil }
      end

      { action: :run, reason: :ok, retry_at: nil }
    end

    # Counters belong to a local calendar day. The rest of the state (breaker,
    # spend of the new day) carries over.
    def roll_day(state, now)
      day = day_for(now)
      return state if state["day"].to_s == day

      state.merge("day" => day, "spent_usd" => 0.0, "summaries" => 0)
    end

    def day_for(now)
      now.getlocal.strftime("%Y-%m-%d")
    end

    # A :config latch holds until the process restarts (the supervisor clears
    # it on boot) or the Neo4j env values change.
    def config_latched?(state, budget)
      state["last_failure_kind"].to_s == "config" &&
        state["config_signature"].to_s == budget.config_signature.to_s
    end

    def cooldown_for(failures)
      index = [[failures.to_i, 1].max - 1, COOLDOWNS.length - 1].min
      COOLDOWNS[index]
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.strip.empty?

      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end

  # Classifies a failure at the ingestion boundary.
  module Failure
    CONFIG_PATTERNS = [
      /Neo4j returned HTTP 40[13]\b/i,
      /returned HTTP 40[13]\b.*(?:neo4j|auth)/i,
      /unauthorized|forbidden/i,
      /NEO4J_(?:PASSWORD|HTTP_URL|USER)/,
      /key not found/i,
      /invalid (?:input|cypher|query|syntax)/i,
      /syntax error/i
    ].freeze

    module_function

    def classify(error)
      text = "#{error.class}: #{error.message}"
      CONFIG_PATTERNS.any? { |pattern| text.match?(pattern) } ? :config : :transient
    end

    # HTTP 429 (Hacker News) asks for a specific wait; honor it when present.
    def retry_after(error)
      return nil unless error.respond_to?(:retry_after)

      value = error.retry_after
      value.nil? ? nil : [value.to_i, 0].max
    end
  end
end
