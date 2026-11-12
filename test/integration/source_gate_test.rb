require "json"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

# A fetch spy: records every URL it is asked for and serves a valid article.
# Any dropped candidate must leave this untouched.
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

# An archive that fails loudly if ingestion tries to read or write it; the
# runner-level checks only care that no fetch happens.
class SilentArchive
  def articles
    []
  end

  def import(records)
    records.length
  end
end

ALLOWLIST = <<~YAML
  sources:
    - name: Registered Feed
      kind: rss
      url: https://feed.example/rss
      max_items: 10
    - name: Quiet Feed
      kind: rss
      url: https://quiet.example/rss
      enabled: false
    - name: Narrow Feed
      kind: rss
      url: https://narrow.example/rss
      domains: ["allowed.example"]
YAML

def story(source:, url:, title: "A candidate story", external_id: "1")
  candidate = { "title" => title, "url" => url, "external_id" => external_id }
  candidate["source"] = source if source
  candidate
end

TestReport.run do
  Dir.mktmpdir("newsagg-gate-") do |directory|
    allowlist_path = File.join(directory, "sources.yml")
    File.write(allowlist_path, ALLOWLIST)
    registry = SourceRegistry.load(path: allowlist_path)
    gate = SourceGate.new(registry: registry)
    retry_path = File.join(directory, "retry.json")
    empty_path = File.join(directory, "empty.yml")
    File.write(empty_path, "sources: []\n")
    empty_registry = SourceRegistry.load(path: empty_path)
    # The remaining source shape with no adapter: an API entry that is not the
    # Hacker News API. RSS entries get an adapter now, so the "reported, never
    # replaced by a built-in" checks below use this registry.
    unadapted_path = File.join(directory, "unadapted.yml")
    File.write(unadapted_path, <<~YAML)
      sources:
        - name: Unadapted API
          kind: api
          url: https://unadapted.example/api
    YAML
    unadapted_registry = SourceRegistry.load(path: unadapted_path)

    batch_for = lambda do |adapters, fetcher, retries: [], against: registry|
      IngestBatch.new(
        adapters: adapters, gate: SourceGate.new(registry: against), fetcher: fetcher,
        summarizer: StubSummarizer.new, extractor: StubExtractor.new,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) }
      ).run(feed: "new", limit: 10, archive_rows: [], retry_entries: retries)
    end

    check "a candidate from an enabled registered source passes the gate" do
      decision = gate.admit(story(source: "Registered Feed", url: "https://allowed.example/post"))
      assert(decision.admitted?, "an enabled registered source was dropped (#{decision.reason})")
      assert(decision.source.name == "Registered Feed", "the decision named #{decision.source&.name.inspect}")
    end

    check "a registered source name is resolved case-insensitively and kept as spelled in the allowlist" do
      decision = gate.admit(story(source: "registered feed", url: "https://allowed.example/post"))
      assert(decision.admitted?, "a differently cased registered source was dropped")
      assert(decision.source.name == "Registered Feed", "the canonical name was not used")
    end

    check "an unregistered candidate is dropped before any fetch" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([story(source: "Unregistered Blog", url: "https://blog.example/post")])
      result = batch_for.call({ "Registered Feed" => adapter }, fetcher)

      assert(fetcher.calls.empty?, "the fetcher was called for a dropped candidate: #{fetcher.calls.inspect}")
      assert(result[:records].empty?, "a dropped candidate produced a record")
      assert(result[:failures].empty?, "a dropped candidate was kept for retry instead of discarded")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "an in-feed link whose source is unregistered is dropped while the feed's own links pass" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([
        story(source: "Registered Feed", url: "https://allowed.example/from-feed", external_id: "1"),
        story(source: "Some Blog", url: "https://embedded.example/link", external_id: "2")
      ])
      result = batch_for.call({ "Registered Feed" => adapter }, fetcher)

      assert(fetcher.calls == ["https://allowed.example/from-feed"],
        "the fetcher was called for #{fetcher.calls.inspect}")
      assert(result[:records].length == 1, "expected one record, got #{result[:records].length}")
      assert(result[:records].first["source"] == "Registered Feed",
        "the record was attributed to #{result[:records].first["source"].inspect}")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "the embedded link was not recorded as unregistered (#{result[:source_gate].counts.inspect})")
    end

    check "a disabled source contributes zero candidates and is never polled" do
      fetcher = SpyFetcher.new
      disabled = StubAdapter.new([story(source: "Quiet Feed", url: "https://quiet.example/post")])
      result = batch_for.call({ "Quiet Feed" => disabled }, fetcher)

      assert(disabled.calls.zero?, "the disabled source's adapter was polled #{disabled.calls} time(s)")
      assert(fetcher.calls.empty?, "the fetcher was called for a disabled source")
      assert(result[:records].empty?, "a disabled source produced a record")
      assert(result[:source_gate].counts[SourceGate::DISABLED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a retry entry from a disabled source is dropped without a fetch or a new retry" do
      fetcher = SpyFetcher.new
      result = batch_for.call({}, fetcher, retries: [{
        "story" => story(source: "Quiet Feed", url: "https://quiet.example/retry"),
        "attempts" => 2
      }])

      assert(fetcher.calls.empty?, "the fetcher ran for a dropped retry entry")
      assert(result[:records].empty?, "a dropped retry entry produced a record")
      assert(result[:failures].empty?, "a dropped retry entry was queued to retry again")
      assert(result[:source_gate].counts[SourceGate::DISABLED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "an adapter that is not in the allowlist is never polled" do
      fetcher = SpyFetcher.new
      ghost = StubAdapter.new([story(source: "Ghost Feed", url: "https://ghost.example/post")])
      result = batch_for.call({ "Ghost Feed" => ghost }, fetcher)

      assert(ghost.calls.zero?, "an unregistered adapter was polled")
      assert(fetcher.calls.empty?, "the fetcher ran for an unregistered adapter")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a candidate that names no source is never attributed to the feed that found it" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([story(source: nil, url: "https://nowhere.example/post")])
      result = batch_for.call({ "Registered Feed" => adapter }, fetcher)

      assert(fetcher.calls.empty?, "the fetcher ran for a candidate with no source")
      assert(result[:records].empty?, "an unattributed candidate produced a record")
      assert(result[:source_gate].counts[SourceGate::MISSING_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "a candidate outside its source's domain rules is dropped before any fetch" do
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([story(source: "Narrow Feed", url: "https://other.example/post")])
      result = batch_for.call({ "Narrow Feed" => adapter }, fetcher)

      assert(fetcher.calls.empty?, "the fetcher ran for a domain the source excludes")
      assert(result[:records].empty?, "a disallowed domain produced a record")
      assert(result[:source_gate].counts[SourceGate::DOMAIN_NOT_ALLOWED] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "the gate drops a URL that is not absolute http(s)" do
      decision = gate.admit(story(source: "Registered Feed", url: "ftp://allowed.example/post"))
      assert(decision.dropped?, "a non-http URL was admitted")
      assert(decision.reason == SourceGate::MISSING_URL, "reason was #{decision.reason.inspect}")
    end

    check "an empty allowlist admits nothing and runs no fetch" do
      fetcher = SpyFetcher.new
      result = batch_for.call(
        { "Registered Feed" => StubAdapter.new([story(source: "Registered Feed", url: "https://allowed.example/post")]) },
        fetcher, against: empty_registry
      )

      assert(fetcher.calls.empty?, "an empty allowlist still fetched")
      assert(result[:records].empty?, "an empty allowlist produced a record")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "the ingestion batch has no default adapter or source" do
      raised = begin
        IngestBatch.new(gate: gate, summarizer: StubSummarizer.new)
        nil
      rescue ArgumentError => error
        error
      end
      assert(raised, "IngestBatch accepted construction without adapters")

      raised = begin
        IngestBatch.new(hn: StubAdapter.new([]), gate: gate, summarizer: StubSummarizer.new)
        nil
      rescue ArgumentError => error
        error
      end
      assert(raised, "IngestBatch still accepts an implicit Hacker News adapter")
    end

    check "an empty allowlist runs a real ingestion pass without fetching or a provider" do
      err = StringIO.new
      fetcher = SpyFetcher.new
      runner = IngestionRunner.new(
        archive: SilentArchive.new, retry_path: retry_path, fetcher: fetcher,
        out: StringIO.new, err: err, env: {}, registry: empty_registry
      )
      code = runner.run(feed: "new", limit: 5)

      assert(code.zero?, "expected exit code 0, got #{code}")
      assert(fetcher.calls.empty?, "an empty allowlist fetched #{fetcher.calls.inspect}")
      assert(runner.last_result[:new_stories].zero?, "an empty allowlist produced a record")
      assert(err.string.include?("source gate: no candidates dropped"),
        "the run did not report an empty gate report: #{err.string.inspect}")
    end

    check "the runner reports an enabled source that has no adapter and fetches nothing" do
      err = StringIO.new
      fetcher = SpyFetcher.new
      runner = IngestionRunner.new(
        archive: SilentArchive.new, retry_path: retry_path, fetcher: fetcher,
        summarizer: StubSummarizer.new, out: StringIO.new, err: err, env: {},
        registry: unadapted_registry
      )
      code = runner.run(feed: "new", limit: 5)

      assert(code.zero?, "expected exit code 0, got #{code}")
      assert(fetcher.calls.empty?, "the fetcher ran without an adapter")
      assert(err.string.include?("has no adapter"),
        "the runner did not report the missing adapter: #{err.string.inspect}")
      assert(runner.last_result[:dropped].zero?, "a missing adapter was counted as a candidate drop")
      assert(runner.last_result[:new_stories].zero?, "a record was produced without an adapter")
    end

    check "the runner logs each refusal with its source and reason" do
      err = StringIO.new
      fetcher = SpyFetcher.new
      adapter = StubAdapter.new([story(source: "Unregistered Blog", url: "https://blog.example/post")])
      runner = IngestionRunner.new(
        archive: SilentArchive.new, retry_path: retry_path, fetcher: fetcher,
        summarizer: StubSummarizer.new, out: StringIO.new, err: err, env: {},
        registry: registry, adapters: { "Registered Feed" => adapter }
      )
      runner.run(feed: "new", limit: 5)

      assert(err.string.include?("source gate: dropped candidate"),
        "no per-candidate refusal was logged: #{err.string.inspect}")
      assert(err.string.include?("reason=unregistered_source"),
        "the refusal reason was not logged: #{err.string.inspect}")
      assert(err.string.include?("source gate: 1 drop(s)"),
        "no drop summary was logged: #{err.string.inspect}")
      assert(fetcher.calls.empty?, "the fetcher ran for the refused candidate")
      assert(runner.last_result[:dropped] == 1,
        "the run result counted #{runner.last_result[:dropped]} drops")
    end

    check "the runner builds adapters for enabled entries only" do
      err = StringIO.new
      runner = IngestionRunner.new(
        archive: SilentArchive.new, retry_path: retry_path, fetcher: SpyFetcher.new,
        out: StringIO.new, err: err, env: {}, registry: registry
      )
      adapters = runner.adapters_for(registry)

      assert(adapters.keys.sort == ["Narrow Feed", "Registered Feed"],
        "adapters were built for #{adapters.keys.sort.inspect}")
      assert(adapters.values.all? { |adapter| adapter.is_a?(RssClient) },
        "an rss entry did not build an RSS adapter")
      assert(!err.string.include?("Quiet Feed"),
        "a disabled source was reported as enabled: #{err.string.inspect}")
    end
  end
end
