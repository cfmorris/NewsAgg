require "json"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

# Serves recorded feed documents instead of the network. `calls` proves which
# feed URLs were polled and what Accept header they were asked for.
class FixtureFeedHttp
  attr_reader :calls

  def initialize(bodies)
    @bodies = bodies
    @calls = []
  end

  def get_text(url, accept: nil, timeout: nil)
    @calls << { "url" => url, "accept" => accept }
    body = @bodies.fetch(url) { raise HttpClient::Error, "#{url} returned HTTP 503" }
    raise body if body.is_a?(Exception)

    body
  end
end

class RssSpyFetcher
  attr_reader :calls

  def initialize
    @calls = []
  end

  def fetch(url)
    @calls << url
    {
      url: url,
      body: "<html><body><article><p>#{'A fetched article body. ' * 4}</p></article></body></html>",
      content_type: "text/html"
    }
  end
end

class RssStubExtractor
  def extract(_body, _uri, content_type:)
    { text: "A fixture article body long enough to be summarized by the batch under test.",
      publisher: "Fixture Press", published_date: "2026-11-05" }
  end

  def sanitize_title(value)
    value.to_s
  end

  def sanitize_publisher(value, fallback)
    value.to_s.empty? ? fallback : value
  end
end

class RssStubSummarizer
  def summarize(url:, title:, publisher:, text:)
    { "summary" => "A fixture summary long enough to satisfy the importer contract check.",
      "depth" => "Overview", "topics" => ["Software Engineering"], "cost_usd" => 0.001 }
  end
end

# The source materialiser is not what this suite covers; the registry it would
# read has its own acceptance suite.
class NullMaterializer
  def call; end
end

# The slice of Archive the ingestion pipeline reads and writes, kept in memory.
# Discoveries carry the external id exactly as the Neo4j projection now does, so
# the second-poll checks exercise the real archive contract.
class RssMemoryArchive
  attr_reader :rows

  def initialize
    @rows = []
  end

  def articles
    @rows.map(&:dup)
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  # The importer recomputes derived per-source cost after writing; the in-memory
  # archive has no source nodes, so it only records the call.
  def recompute_source_costs
    @cost_recomputations = @cost_recomputations.to_i + 1
  end

  # Source scoring (auto-pause) reads this from the real archive; there are no
  # source nodes here, so there is nothing to score and nothing gets paused.
  def source_quality_inputs
    []
  end

  def cost_recomputations
    @cost_recomputations.to_i
  end

  def import(records)
    records.each do |record|
      discovery = {
        "source" => record["source"], "url" => record["discovery_url"],
        "external_id" => record["external_id"]
      }
      existing = @rows.find { |row| row["url"] == record["url"] }
      if existing
        existing["discoveries"] = (Array(existing["discoveries"]) + [discovery]).uniq
        existing["sources"] = existing["discoveries"].map { |entry| entry["source"] }.uniq
      else
        @rows << record.merge(
          "sources" => [record["source"]],
          "discoveries" => [discovery],
          "topic_mappings" => []
        )
      end
    end
    records.length
  end
end

fixtures = File.expand_path("../fixtures/ingest", __dir__)
FEED_XML = File.read(File.join(fixtures, "feed.xml"))
FEED_URL = "https://feed.example/feed".freeze
BROKEN_URL = "https://feed.example/broken".freeze
SINGLE_URL = "https://feed.example/single".freeze
FIRST_GUID = "https://feed.example/p/first-post".freeze

SINGLE_ITEM_FEED = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0">
    <channel>
      <title>Single Item Feed</title>
      <link>https://feed.example</link>
      <item>
        <title>Only Post</title>
        <link>https://feed.example/p/only</link>
        <guid isPermaLink="true">fixture-guid-only</guid>
        <pubDate>Thu, 05 Nov 2026 18:40:03 GMT</pubDate>
      </item>
    </channel>
  </rss>
XML

ALLOWLIST = <<~YAML
  sources:
    - name: Fixture Feed
      kind: rss
      url: #{FEED_URL}
      max_items: 25
    - name: Broken Feed
      kind: rss
      url: #{BROKEN_URL}
    - name: Off-Domain Feed
      kind: rss
      url: #{FEED_URL}
      domains: ["other.example"]
YAML

CANDIDATE_KEYS = %w[discovery_url external_id score source submitted_at title url].sort.freeze

TestReport.run do
  Dir.mktmpdir("newsagg-rss-") do |directory|
    allowlist_path = File.join(directory, "sources.yml")
    File.write(allowlist_path, ALLOWLIST)
    registry = SourceRegistry.load(path: allowlist_path)
    gate = SourceGate.new(registry: registry)

    bodies = { FEED_URL => FEED_XML, BROKEN_URL => "<rss><channel><item>", SINGLE_URL => SINGLE_ITEM_FEED }
    client_for = lambda do |name: "Fixture Feed", url: FEED_URL|
      RssClient.new(name: name, feed_url: url, http: FixtureFeedHttp.new(bodies))
    end
    batch_for = lambda do |adapters, fetcher: RssSpyFetcher.new|
      IngestBatch.new(
        adapters: adapters, gate: gate, fetcher: fetcher,
        summarizer: RssStubSummarizer.new, extractor: RssStubExtractor.new,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) }
      )
    end

    check "a recorded feed parses into candidates with the shared candidate shape" do
      first = client_for.call.collect_candidates(limit: 25).first

      assert(first.is_a?(Hash), "the feed produced no candidate")
      assert(first.keys.sort == CANDIDATE_KEYS, "candidate keys were #{first.keys.sort.inspect}")
      assert(first["title"] == "Why & How Teams Ship Research",
        "title was #{first["title"].inspect}")
      assert(first["url"] == "https://feed.example/p/first-post", "url was #{first["url"].inspect}")
      assert(first["source"] == "Fixture Feed", "source was #{first["source"].inspect}")
      assert(first["external_id"] == FIRST_GUID, "external id was #{first["external_id"].inspect}")
      assert(first["discovery_url"] == FEED_URL, "discovery url was #{first["discovery_url"].inspect}")
      assert(first["submitted_at"] == "2026-11-05T18:40:03Z",
        "submitted_at was #{first["submitted_at"].inspect}")
      assert(first["score"].nil?, "an RSS item invented a score: #{first["score"].inspect}")
    end

    check "the feed is polled at the allowlist URL with an RSS accept header" do
      http = FixtureFeedHttp.new(bodies)
      RssClient.new(name: "Fixture Feed", feed_url: FEED_URL, http: http).collect_candidates(limit: 5)

      assert(http.calls.length == 1, "expected one feed request, got #{http.calls.length}")
      assert(http.calls.first["url"] == FEED_URL, "polled #{http.calls.first["url"].inspect}")
      assert(http.calls.first["accept"].to_s.include?("rss+xml"),
        "accept header was #{http.calls.first["accept"].inspect}")
    end

    check "an item with no guid gets a stable external id from its link" do
      candidate = client_for.call.collect_candidates(limit: 25)
        .find { |entry| entry["url"].end_with?("/p/no-guid-post") }
      assert(candidate, "the guid-less item was dropped from the feed")
      assert(candidate["external_id"] == "https://feed.example/p/no-guid-post",
        "external id was #{candidate["external_id"].inspect}")

      again = client_for.call.collect_candidates(limit: 25)
        .find { |entry| entry["url"] == candidate["url"] }
      assert(again && again["external_id"] == candidate["external_id"],
        "the derived external id changed between polls: #{again && again["external_id"].inspect}")
    end

    check "a root-relative link is resolved against the feed URL" do
      candidate = client_for.call.collect_candidates(limit: 25)
        .find { |entry| entry["external_id"] == "fixture-guid-relative" }
      assert(candidate, "the relative-link item was dropped from the feed")
      assert(candidate["url"] == "https://feed.example/p/relative-post",
        "resolved url was #{candidate["url"].inspect}")
    end

    check "a guid repeated inside one feed yields one candidate" do
      candidates = client_for.call.collect_candidates(limit: 25)
      replayed = candidates.select { |entry| entry["external_id"] == FIRST_GUID }
      assert(replayed.length == 1, "#{replayed.length} candidates carried the repeated guid")
      assert(replayed.first["url"] == "https://feed.example/p/first-post",
        "the repeated guid kept #{replayed.first["url"].inspect}")
    end

    check "a feed with more than 25 items honours the limit without repeating external ids" do
      candidates = client_for.call.collect_candidates(limit: 25)
      assert(candidates.length == 25, "expected 25 candidates, got #{candidates.length}")
      assert(candidates.map { |entry| entry["external_id"] }.uniq.length == 25,
        "the candidates repeated external ids")

      shorter = client_for.call.collect_candidates(limit: 3)
      assert(shorter.length == 3, "a limit of 3 produced #{shorter.length} candidates")
    end

    check "an item with no title is skipped instead of producing an unusable candidate" do
      candidates = client_for.call.collect_candidates(limit: 25)
      assert(candidates.none? { |entry| entry["url"].end_with?("/p/untitled-post") },
        "an untitled item reached the candidate list")
    end

    check "two polls of one feed import one article, not two" do
      archive = RssMemoryArchive.new
      fetcher = RssSpyFetcher.new
      client = RssClient.new(name: "Fixture Feed", feed_url: SINGLE_URL,
        http: FixtureFeedHttp.new(bodies))
      importer = ImportRecords.new(archive: archive, materializer: NullMaterializer.new)

      first = batch_for.call({ "Fixture Feed" => client }, fetcher: fetcher)
        .run(feed: "new", limit: 5, archive_rows: archive.articles)
      assert(first[:records].length == 1, "the first poll produced #{first[:records].length} records")
      assert(importer.call(first[:records]) == 1, "the first poll did not import")
      assert(archive.rows.length == 1, "the first poll wrote #{archive.rows.length} articles")
      assert(archive.rows.first["external_id"] == "fixture-guid-only",
        "imported external id was #{archive.rows.first["external_id"].inspect}")
      assert(archive.rows.first["discovery_url"] == SINGLE_URL,
        "imported discovery url was #{archive.rows.first["discovery_url"].inspect}")
      fetches_after_first = fetcher.calls.length

      second = batch_for.call({ "Fixture Feed" => client }, fetcher: fetcher)
        .run(feed: "new", limit: 5, archive_rows: archive.articles)
      assert(second[:records].empty?, "the second poll produced #{second[:records].length} records")
      assert(fetcher.calls.length == fetches_after_first,
        "the second poll re-fetched an archived article")
      assert(archive.rows.length == 1, "the archive ended with #{archive.rows.length} articles")
      assert(archive.rows.first["discoveries"].length == 1,
        "the archive ended with #{archive.rows.first["discoveries"].length} discoveries")

      # Same guid, different article URL: only the archived external id can stop
      # this one, so the guid path is proven on its own.
      renamed = [{
        "url" => "https://feed.example/p/only-post-renamed",
        "discoveries" => [{
          "source" => "Fixture Feed", "url" => SINGLE_URL, "external_id" => "fixture-guid-only"
        }]
      }]
      renamed_fetcher = RssSpyFetcher.new
      third = batch_for.call({ "Fixture Feed" => client }, fetcher: renamed_fetcher)
        .run(feed: "new", limit: 5, archive_rows: renamed)
      assert(third[:records].empty?, "a renamed article with an archived guid was re-imported")
      assert(renamed_fetcher.calls.empty?, "a renamed article with an archived guid was re-fetched")
    end

    check "a malformed feed raises a feed error that names the URL" do
      error = begin
        RssClient.new(name: "Broken Feed", feed_url: BROKEN_URL,
          http: FixtureFeedHttp.new(bodies)).collect_candidates(limit: 5)
        nil
      rescue StandardError => caught
        caught
      end

      assert(error.is_a?(RssClient::FeedError), "raised #{error.class}: #{error && error.message}")
      assert(error.message.include?(BROKEN_URL), "the error did not name the feed: #{error.message}")
    end

    check "a malformed feed fails as an adapter failure without aborting the run" do
      http = FixtureFeedHttp.new(bodies)
      adapters = {
        "Fixture Feed" => RssClient.new(name: "Fixture Feed", feed_url: FEED_URL, http: http),
        "Broken Feed" => RssClient.new(name: "Broken Feed", feed_url: BROKEN_URL, http: http)
      }

      result = batch_for.call(adapters).run(feed: "new", limit: 1, archive_rows: [])

      assert(result[:records].length == 1,
        "the healthy source produced #{result[:records].length} records")
      counts = result[:source_gate].counts
      assert(counts[:adapter_failed] == 1, "adapter failures were #{counts.inspect}")
      line = result[:source_gate].lines.find { |entry| entry.include?("adapter_failed") }
      assert(line && line.include?("Broken Feed"), "the failure line was #{line.inspect}")
      assert(line.include?("not well-formed XML"), "the failure line lost the reason: #{line.inspect}")
    end

    check "the runner builds an RSS adapter from an rss allowlist entry and the gate still applies" do
      runner = IngestionRunner.new(
        archive: RssMemoryArchive.new, retry_path: File.join(directory, "retry.json"),
        http: FixtureFeedHttp.new(bodies), fetcher: RssSpyFetcher.new,
        summarizer: RssStubSummarizer.new, out: StringIO.new, err: StringIO.new, env: {}
      )
      adapters = runner.adapters_for(registry)

      assert(adapters.keys.sort == ["Broken Feed", "Fixture Feed", "Off-Domain Feed"],
        "adapters were #{adapters.keys.sort.inspect}")
      assert(adapters.values.all? { |adapter| adapter.is_a?(RssClient) },
        "a rss entry did not produce an RSS adapter")
      assert(adapters["Fixture Feed"].feed_url == FEED_URL,
        "adapter feed url was #{adapters["Fixture Feed"].feed_url.inspect}")

      result = batch_for.call({ "Off-Domain Feed" => adapters["Off-Domain Feed"] })
        .run(feed: "new", limit: 25, archive_rows: [])
      assert(result[:records].empty?, "an off-domain feed imported #{result[:records].length} records")
      assert(result[:source_gate].counts[:domain_not_allowed] == 25,
        "domain drops were #{result[:source_gate].counts.inspect}")
    end

    check "the committed allowlist registers The Software Analyst as an RSS source" do
      source = SourceRegistry.current.fetch("The Software Analyst")
      assert(source.rss?, "kind was #{source.kind.inspect}")
      assert(source.enabled?, "the Substack source is disabled")
      assert(source.url == "https://softwareanalyst.substack.com/feed",
        "url was #{source.url.inspect}")
      assert(source.domains == ["softwareanalyst.substack.com"],
        "domains were #{source.domains.inspect}")

      runner = IngestionRunner.new(
        archive: RssMemoryArchive.new, retry_path: File.join(directory, "retry.json"),
        http: FixtureFeedHttp.new(bodies), out: StringIO.new, err: StringIO.new, env: {}
      )
      adapter = runner.adapters_for(SourceRegistry.current)[source.name]
      assert(adapter.is_a?(RssClient), "the Substack entry built #{adapter.class}")
      assert(adapter.feed_url == source.url, "the adapter polls #{adapter.feed_url.inspect}")
    end
  end
end
