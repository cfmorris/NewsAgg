require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

# Acceptance test for the explicit source allowlist:
#
#   * an unregistered candidate is dropped before any fetch
#   * a link found inside a registered feed is never self-attributed to it
#   * a disabled source stops contributing and is never polled
#   * a malformed registry refuses to load (unknown kind, missing url,
#     duplicate name)
#   * there is no implicit Hacker News default and no discovery fallback
#
# The allowlist comes from the committed fixtures under test/fixtures/sources,
# and a fetch spy proves that no network path is reached for a dropped
# candidate. The Neo4j half of the acceptance criteria (registry round-trip and
# per-source cost) lives in source_registry_roundtrip_acceptance_test.rb.
FIXTURE_DIR = File.expand_path("../fixtures/sources", __dir__)

# Records every URL it is asked for and serves a valid article. Any dropped
# candidate must leave this untouched.
class SpyFetcher
  attr_reader :calls

  def initialize
    @calls = []
  end

  def fetch(url)
    @calls << url
    { url: url, body: "<html><body><article><p>#{'A fetched article body. ' * 4}</p></article></body></html>",
      content_type: "text/html" }
  end
end

# A source adapter whose candidates are fixed by the test. `calls` proves
# whether the source was polled at all.
class StubAdapter
  attr_reader :calls

  def initialize(stories)
    @stories = stories
    @calls = 0
  end

  def archive_keys(_rows)
    [[], []]
  end

  def collect_candidates(feed:, limit:, archive_rows:)
    @calls += 1
    @stories.first(limit)
  end
end

class StubExtractor
  def extract(_body, uri, content_type:)
    { text: "An article body long enough to be summarized by the batch under test.",
      publisher: uri.hostname, published_date: nil }
  end

  def sanitize_title(value)
    value.to_s
  end

  def sanitize_publisher(value, fallback)
    value.to_s.empty? ? fallback : value
  end
end

class StubSummarizer
  def summarize(url:, title:, publisher:, text:)
    { "summary" => "A summary long enough to satisfy the importer contract check in this batch.",
      "depth" => "Overview", "topics" => ["Software Engineering"], "cost_usd" => 0.01 }
  end
end

# An archive that fails loudly if ingestion tries to write to it; these checks
# only care that no fetch happens and no record is produced.
class SilentArchive
  def articles
    []
  end

  def import(records)
    records.length
  end
end

def fixture(path)
  File.join(FIXTURE_DIR, path)
end

def story(source:, url:, title: "A candidate story", external_id: "1")
  candidate = { "title" => title, "url" => url, "external_id" => external_id }
  candidate["source"] = source unless source.nil?
  candidate
end

def load_failure(path)
  SourceRegistry.load(path: path)
  nil
rescue SourceRegistry::ConfigError => error
  error.message
end

TestReport.run do
  Dir.mktmpdir("newsagg-acceptance-") do |directory|
    allowlist = SourceRegistry.load(path: fixture("acceptance.yml"))
    empty = SourceRegistry.load(path: fixture("empty.yml"))
    retry_path = File.join(directory, "retry.json")

    gate_for = ->(registry) { SourceGate.new(registry: registry) }

    batch_for = lambda do |adapters, fetcher, registry: allowlist, retries: []|
      IngestBatch.new(
        adapters: adapters, gate: gate_for.call(registry), fetcher: fetcher,
        summarizer: StubSummarizer.new, extractor: StubExtractor.new,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) }
      ).run(feed: "new", limit: 10, archive_rows: [], retry_entries: retries)
    end

    runner_for = lambda do |fetcher, registry:, adapters: nil, **options|
      err = StringIO.new
      runner = IngestionRunner.new(
        archive: SilentArchive.new, retry_path: retry_path, fetcher: fetcher,
        out: StringIO.new, err: err, env: {}, registry: registry,
        adapters: adapters, **options
      )
      [runner, err]
    end

    check "the fixture allowlist loads three sources and enables exactly two" do
      assert(allowlist.names == ["Acceptance Alpha", "Acceptance Beta", "Acceptance Dormant"],
        "names were #{allowlist.names.inspect}")
      assert(allowlist.enabled_names == ["Acceptance Alpha", "Acceptance Beta"],
        "enabled names were #{allowlist.enabled_names.inspect}")
      assert(allowlist.find("Acceptance Dormant").enabled? == false,
        "the dormant fixture entry is enabled")
    end

    check "an unregistered candidate is dropped before any fetch" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([
        story(source: "Acceptance Alpha", url: "https://alpha.acceptance.test/accepted", external_id: "1"),
        story(source: "Unregistered Blog", url: "https://blog.acceptance.test/dropped", external_id: "2")
      ])
      result = batch_for.call({ "Acceptance Alpha" => adapter }, fetcher)

      assert(fetcher.calls == ["https://alpha.acceptance.test/accepted"],
        "the fetcher was called for #{fetcher.calls.inspect}")
      assert(result[:records].length == 1, "expected one record, got #{result[:records].length}")
      assert(result[:failures].empty?, "the dropped candidate was kept for retry")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a link inside a registered feed is never self-attributed to that feed" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([
        story(source: nil, url: "https://alpha.acceptance.test/no-source", external_id: "1"),
        story(source: "Some Blog", url: "https://alpha.acceptance.test/some-blog", external_id: "2")
      ])
      result = batch_for.call({ "Acceptance Alpha" => adapter }, fetcher)

      assert(fetcher.calls.empty?, "a self-discovered candidate was fetched: #{fetcher.calls.inspect}")
      assert(result[:records].empty?, "a self-discovered candidate produced a record")
      counts = result[:source_gate].counts
      assert(counts[SourceGate::MISSING_SOURCE] == 1, "missing_source was not recorded: #{counts.inspect}")
      assert(counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "unregistered_source was not recorded: #{counts.inspect}")
    end

    check "a candidate outside its source's domain rules is dropped before any fetch" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([story(source: "Acceptance Alpha", url: "https://elsewhere.acceptance.test/post")])
      result = batch_for.call({ "Acceptance Alpha" => adapter }, fetcher)

      assert(fetcher.calls.empty?, "the fetcher ran for a disallowed domain: #{fetcher.calls.inspect}")
      assert(result[:records].empty?, "a disallowed domain produced a record")
      assert(result[:source_gate].counts[SourceGate::DOMAIN_NOT_ALLOWED] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a disabled source stops contributing and is never polled" do
      fetcher = SpyFetcher.new
      dormant = StubAdapter.new([story(source: "Acceptance Dormant", url: "https://dormant.acceptance.test/post")])
      result = batch_for.call({ "Acceptance Dormant" => dormant }, fetcher)

      assert(dormant.calls.zero?, "the disabled source's adapter was polled #{dormant.calls} time(s)")
      assert(fetcher.calls.empty?, "the fetcher ran for a disabled source: #{fetcher.calls.inspect}")
      assert(result[:records].empty?, "a disabled source produced a record")
      assert(result[:source_gate].counts[SourceGate::DISABLED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a retry entry from a disabled source is dropped without a fetch" do
      fetcher = SpyFetcher.new
      result = batch_for.call({}, fetcher, retries: [{
        "story" => story(source: "Acceptance Dormant", url: "https://dormant.acceptance.test/retry"),
        "attempts" => 2
      }])

      assert(fetcher.calls.empty?, "the fetcher ran for a dropped retry entry")
      assert(result[:records].empty?, "a dropped retry entry produced a record")
      assert(result[:failures].empty?, "a dropped retry entry was queued again")
      assert(result[:source_gate].counts[SourceGate::DISABLED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a malformed registry refuses to load for an unknown kind" do
      message = load_failure(fixture("malformed-unknown-kind.yml"))
      assert(message, "an unknown kind loaded")
      assert(message.include?("malformed-unknown-kind.yml"), "the refusal named no file: #{message.inspect}")
      assert(message.include?("sources[0]") && message.include?("unknown kind") && message.include?("podcast"),
        "unclear refusal: #{message.inspect}")
    end

    check "a malformed registry refuses to load for a missing url" do
      message = load_failure(fixture("malformed-missing-url.yml"))
      assert(message, "a source without a url loaded")
      assert(message.include?("sources[0]") && message.include?("missing url"),
        "unclear refusal: #{message.inspect}")
    end

    check "a malformed registry refuses to load for a duplicate name" do
      message = load_failure(fixture("malformed-duplicate-name.yml"))
      assert(message, "a duplicate name loaded")
      assert(message.include?("sources[1]") && message.include?("duplicate source name") &&
        message.include?("sources[0]"), "unclear refusal: #{message.inspect}")
    end

    check "there is no implicit Hacker News default in the ingestion batch" do
      raised = begin
        IngestBatch.new(gate: gate_for.call(allowlist), summarizer: StubSummarizer.new)
        nil
      rescue ArgumentError => error
        error
      end
      assert(raised, "IngestBatch accepted construction without adapters")

      raised = begin
        IngestBatch.new(hn: StubAdapter.new([]), gate: gate_for.call(allowlist), summarizer: StubSummarizer.new)
        nil
      rescue ArgumentError => error
        error
      end
      assert(raised, "IngestBatch still accepts an implicit Hacker News adapter")
    end

    check "the fixture allowlist builds an RSS adapter and reports the api entry it cannot adapt" do
      fetcher = SpyFetcher.new
      runner, err = runner_for.call(fetcher, registry: allowlist)
      adapters = runner.adapters_for(allowlist)

      assert(adapters.keys == ["Acceptance Alpha"],
        "adapters were built for #{adapters.keys.inspect}")
      assert(adapters.values.all? { |adapter| adapter.is_a?(RssClient) },
        "the rss fixture entry did not build an RSS adapter")
      assert(err.string.include?("has no adapter"),
        "the runner did not report the unadaptable api source: #{err.string.inspect}")
      assert(err.string.include?("Acceptance Beta"),
        "the report did not name the unadaptable source: #{err.string.inspect}")
      assert(fetcher.calls.empty?, "building adapters fetched #{fetcher.calls.inspect}")
    end

    check "an enabled source with no adapter runs nothing and fetches nothing" do
      fetcher = SpyFetcher.new
      api_only_path = File.join(directory, "api-only.yml")
      File.write(api_only_path, <<~YAML)
        sources:
          - name: Acceptance Beta
            kind: api
            url: https://beta.acceptance.test/items
      YAML
      api_only = SourceRegistry.load(path: api_only_path)
      runner, err = runner_for.call(fetcher, registry: api_only)
      code = runner.run(feed: "new", limit: 5)

      assert(code.zero?, "expected exit code 0, got #{code}")
      assert(runner.adapters_for(api_only).empty?,
        "an api entry without an adapter built #{runner.adapters_for(api_only).keys.inspect}")
      assert(fetcher.calls.empty?, "the unadapted allowlist fetched #{fetcher.calls.inspect}")
      assert(runner.last_result[:new_stories].zero?, "the unadapted allowlist produced a record")
      assert(err.string.include?("has no adapter"),
        "the runner did not report the missing adapter: #{err.string.inspect}")
    end

    check "an empty allowlist runs nothing and needs no LLM provider" do
      fetcher = SpyFetcher.new
      runner, err = runner_for.call(fetcher, registry: empty)
      code = runner.run(feed: "new", limit: 5)

      assert(code.zero?, "expected exit code 0, got #{code}")
      assert(empty.empty? && empty.enabled.empty?, "the empty fixture loaded entries")
      assert(runner.adapters_for(empty).empty?, "an empty allowlist built adapters")
      assert(fetcher.calls.empty?, "an empty allowlist fetched #{fetcher.calls.inspect}")
      assert(runner.last_result[:new_stories].zero?, "an empty allowlist produced a record")
      assert(err.string.include?("source gate: no candidates dropped"),
        "the run did not report an empty gate report: #{err.string.inspect}")
    end
  end
end
