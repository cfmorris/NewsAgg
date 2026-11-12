require "json"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../../app/services/import_records"
require_relative "../../app/services/ingestion_runner"
require_relative "../../app/services/lobsters_client"
require_relative "../support/assertions"

# A fetch spy: records every URL it is asked for and serves a summarizable
# article. Nothing may be fetched for a self-post.
class LobstersSpyFetcher
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

# The API spy: one poll returns the fixture and counts calls, so a source the
# gate refuses can be proven never to have been polled.
class LobstersFakeHttp
  attr_reader :calls

  def initialize(payload)
    @payload = payload
    @calls = []
  end

  def get_json(url)
    @calls << url
    @payload
  end
end

class LobstersStubSummarizer
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def summarize(url:, title:, publisher:, text:)
    @calls += 1
    { "summary" => "A summary long enough to satisfy the importer contract check in this batch.",
      "depth" => "Overview", "topics" => ["Software Engineering"], "cost_usd" => 0.01 }
  end
end

# A disposable stand-in for the Neo4j archive: it implements the archive
# contract the importer needs, so the suite never touches a live database.
class LobstersDisposableArchive
  def initialize(rows = [])
    @rows = rows.map(&:dup)
    @synced_sources = []
  end

  attr_reader :synced_sources

  def articles
    @rows
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  def sync_sources(sources)
    @synced_sources.concat(sources)
    sources.length
  end

  # The real archive derives per-source cost after an import; this stand-in has
  # no cost rows to aggregate.
  def recompute_source_costs
    0
  end

  def import(records)
    records.each do |record|
      existing = @rows.find { |row| row["url"] == record["url"] }
      if existing
        discovery = { "source" => record["source"], "url" => record["discovery_url"] }
        existing["discoveries"] = (Array(existing["discoveries"]) + [discovery]).uniq
      else
        @rows << record.merge(
          "sources" => [record["source"]],
          "discoveries" => [{ "source" => record["source"], "url" => record["discovery_url"] }]
        )
      end
    end
    records.length
  end
end

ALLOWLIST = <<~YAML
  sources:
    - id: lobsters
      name: Lobsters
      kind: api
      url: https://lobste.rs/hottest.json
      max_items: 10
    - id: quiet-lobsters
      name: Quiet Lobsters
      kind: api
      url: https://lobste.rs/hottest.json
      enabled: false
YAML

HACKER_ONLY = <<~YAML
  sources:
    - id: hacker-news
      name: Hacker News
      kind: api
      url: https://hacker-news.firebaseio.com/v0
YAML

items = JSON.parse(File.read(File.expand_path("../fixtures/ingest/lobsters.json", __dir__)))

TestReport.run do
  Dir.mktmpdir("newsagg-lobsters-") do |directory|
    allowlist_path = File.join(directory, "sources.yml")
    File.write(allowlist_path, ALLOWLIST)
    hacker_only_path = File.join(directory, "hacker-only.yml")
    File.write(hacker_only_path, HACKER_ONLY)
    registry = SourceRegistry.load(path: allowlist_path)
    hacker_only_registry = SourceRegistry.load(path: hacker_only_path)
    retry_path = File.join(directory, "retry.json")

    http = LobstersFakeHttp.new(items)
    client = LobstersClient.new(name: "Lobsters", http: http)

    check "a Lobsters poll returns candidates in the Hacker News candidate shape" do
      candidates = client.collect_candidates(feed: "new", limit: 10, archive_rows: [])

      assert(candidates.length == 4, "expected 4 candidates from 5 items, got #{candidates.length}")
      assert(http.calls == ["https://lobste.rs/hottest.json"],
        "the poll was #{http.calls.inspect}")
      candidate = candidates.find { |entry| entry["external_id"] == "lnau2d" }
      assert(candidate, "the external story is missing")
      %w[title url source external_id discovery_url submitted_at score fetch].each do |key|
        assert(candidate.key?(key), "the candidate has no #{key.inspect} key")
      end
      assert(candidate["source"] == "Lobsters", "the candidate named #{candidate["source"].inspect}")
      assert(candidate["url"] == "https://lyra.example/blog/2026/11/fixture-story/",
        "the candidate URL was #{candidate["url"].inspect}")
      assert(candidate["discovery_url"] == "https://lobste.rs/s/lnau2d",
        "the discovery URL was #{candidate["discovery_url"].inspect}")
      assert(candidate["submitted_at"] == "2026-11-11T21:53:24Z",
        "submitted_at was #{candidate["submitted_at"].inspect}")
      assert(candidate["score"] == 112, "score was #{candidate["score"].inspect}")
      assert(candidate["fetch"] == true, "an external story was marked unfetchable")
    end

    check "a self-post points at its discussion URL and is marked unfetchable" do
      candidate = client.collect_candidates(feed: "new", limit: 10, archive_rows: [])
        .find { |entry| entry["external_id"] == "m43bas" }

      assert(candidate, "the self-post was dropped instead of becoming a candidate")
      assert(candidate["url"] == "https://lobste.rs/s/m43bas",
        "the self-post URL was #{candidate["url"].inspect}")
      assert(candidate["discovery_url"] == "https://lobste.rs/s/m43bas",
        "the self-post discovery URL was #{candidate["discovery_url"].inspect}")
      assert(candidate["fetch"] == false, "the self-post was marked fetchable")
    end

    check "a repost of an article already in the poll is not a second candidate" do
      candidates = client.collect_candidates(feed: "new", limit: 10, archive_rows: [])
      assert(candidates.none? { |entry| entry["external_id"] == "dupe22" },
        "the repost became a second candidate for the same article")
    end

    check "an unparseable timestamp leaves submitted_at unknown instead of dropping the item" do
      candidate = client.collect_candidates(feed: "new", limit: 10, archive_rows: [])
        .find { |entry| entry["external_id"] == "flag33" }

      assert(candidate, "the item with an unparseable timestamp was dropped")
      assert(candidate["submitted_at"].nil?,
        "submitted_at was #{candidate["submitted_at"].inspect}")
    end

    archive = LobstersDisposableArchive.new
    summarizer = LobstersStubSummarizer.new
    fetcher = LobstersSpyFetcher.new
    err = StringIO.new
    runner = IngestionRunner.new(
      archive: archive, retry_path: retry_path, summarizer: summarizer, fetcher: fetcher,
      out: StringIO.new, err: err, env: {}, registry: registry,
      adapters: { "Lobsters" => client },
      importer: ImportRecords.new(archive: archive, registry: registry)
    )
    first_code = runner.run(feed: "new", limit: 10)

    check "a Lobsters batch imports its external articles and never fetches the self-post" do
      assert(first_code.zero?, "expected exit code 0, got #{first_code}: #{err.string}")
      assert(!fetcher.calls.any? { |url| url.start_with?("https://lobste.rs/s/") },
        "the batch fetched a discussion page: #{fetcher.calls.inspect}")
      assert(fetcher.calls.sort == [
        "https://lyra.example/blog/2026/11/fixture-story/",
        "https://second.example/posts/lobsters-fixture?utm_source=lobsters",
        "https://third.example/article"
      ].sort, "the batch fetched #{fetcher.calls.inspect}")
      imported = archive.articles.select { |row| row["source"] == "Lobsters" }
      assert(imported.length == 3, "expected 3 imported articles, got #{imported.length}")
      assert(imported.none? { |row| row["external_id"] == "m43bas" },
        "the self-post produced an article record")
      assert(imported.all? { |row| row["discovery_url"].start_with?("https://lobste.rs/s/") },
        "an imported article carries no discussion URL")
    end

    check "the run reports the discussion-only skip instead of a failure" do
      assert(runner.last_result[:skipped_no_article] == 1,
        "last_result counted #{runner.last_result[:skipped_no_article]} discussion-only skips")
      assert(runner.last_result[:new_stories] == 3,
        "last_result counted #{runner.last_result[:new_stories]} new stories")
      assert(err.string.include?("1 discussion-only skipped"),
        "the run summary did not report the skip: #{err.string.inspect}")
      assert(JSON.parse(File.read(retry_path)) == [],
        "the self-post was kept for retry instead of skipped")
      assert(summarizer.calls == 3, "expected 3 summaries, got #{summarizer.calls}")
    end

    second_http = LobstersFakeHttp.new(items)
    second_fetcher = LobstersSpyFetcher.new
    second_runner = IngestionRunner.new(
      archive: archive, retry_path: retry_path, summarizer: LobstersStubSummarizer.new,
      fetcher: second_fetcher, out: StringIO.new, err: StringIO.new, env: {}, registry: registry,
      adapters: { "Lobsters" => LobstersClient.new(name: "Lobsters", http: second_http) },
      importer: ImportRecords.new(archive: archive, registry: registry)
    )
    second_code = second_runner.run(feed: "new", limit: 10)

    check "a second poll over the same archive imports nothing and fetches nothing" do
      assert(second_code.zero?, "expected exit code 0, got #{second_code}")
      assert(second_fetcher.calls.empty?,
        "the second poll fetched #{second_fetcher.calls.inspect}")
      assert(second_runner.last_result[:new_stories].zero?,
        "the second poll imported #{second_runner.last_result[:new_stories]} stories")
      assert(archive.articles.length == 3,
        "the archive grew to #{archive.articles.length} rows on the second poll")
      assert(second_runner.last_result[:skipped_no_article] == 1,
        "the second poll did not skip the discussion-only item")
    end

    check "a disabled Lobsters entry contributes nothing and is never polled" do
      quiet_http = LobstersFakeHttp.new(items)
      quiet_fetcher = LobstersSpyFetcher.new
      quiet_summarizer = LobstersStubSummarizer.new
      result = IngestBatch.new(
        adapters: { "Quiet Lobsters" => LobstersClient.new(name: "Quiet Lobsters", http: quiet_http) },
        gate: SourceGate.new(registry: registry), fetcher: quiet_fetcher,
        summarizer: quiet_summarizer, extractor: ArticleExtractor.new
      ).run(feed: "new", limit: 10)

      assert(quiet_http.calls.empty?, "the disabled source was polled")
      assert(quiet_fetcher.calls.empty?, "the disabled source fetched #{quiet_fetcher.calls.inspect}")
      assert(result[:records].empty?, "the disabled source produced a record")
      assert(result[:source_gate].counts[SourceGate::DISABLED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "an unregistered Lobsters adapter contributes nothing and is never polled" do
      ghost_http = LobstersFakeHttp.new(items)
      ghost_fetcher = LobstersSpyFetcher.new
      result = IngestBatch.new(
        adapters: { "Lobsters" => LobstersClient.new(name: "Lobsters", http: ghost_http) },
        gate: SourceGate.new(registry: hacker_only_registry), fetcher: ghost_fetcher,
        summarizer: LobstersStubSummarizer.new, extractor: ArticleExtractor.new
      ).run(feed: "new", limit: 10)

      assert(ghost_http.calls.empty?, "an unregistered source was polled")
      assert(ghost_fetcher.calls.empty?, "an unregistered source fetched #{ghost_fetcher.calls.inspect}")
      assert(result[:records].empty?, "an unregistered source produced a record")
      assert(result[:source_gate].counts[SourceGate::UNREGISTERED_SOURCE] == 1,
        "drop reasons were #{result[:source_gate].counts.inspect}")
    end

    check "the runner builds a LobstersClient only for an enabled Lobsters entry" do
      adapters = IngestionRunner.new(
        archive: LobstersDisposableArchive.new, retry_path: retry_path,
        out: StringIO.new, err: StringIO.new, env: {}, registry: registry
      ).adapters_for(registry)

      assert(adapters["Lobsters"].is_a?(LobstersClient),
        "the Lobsters entry produced #{adapters["Lobsters"].class}")
      assert(adapters["Lobsters"].feed_url == "https://lobste.rs/hottest.json",
        "the adapter polled #{adapters["Lobsters"].feed_url.inspect}")
      assert(!adapters.key?("Quiet Lobsters"), "a disabled entry produced an adapter")
    end
  end
end
