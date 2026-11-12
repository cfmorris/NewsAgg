require "json"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

# A disposable, in-memory stand-in for the Neo4j archive. It implements the
# archive contract the ingestion pipeline needs, so the test never touches a
# live database.
class DisposableArchive
  def initialize(rows)
    @rows = rows.map(&:dup)
  end

  def articles
    @rows
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  # The real archive upserts NewsSource nodes here; this stand-in records them
  # so the pipeline can be exercised without a live Neo4j.
  def sync_sources(sources)
    (@synced_sources ||= []).concat(sources)
    sources.length
  end

  def synced_sources
    @synced_sources || []
  end

  # The real archive recomputes each NewsSource.cost_usd from the imported
  # articles; this stand-in has no source nodes, so it records the call instead.
  def recompute_source_costs
    @cost_recomputations = (@cost_recomputations || 0) + 1
  end

  # Source scoring reads each source's scored articles from the archive; with no
  # source nodes there is nothing to score, so the import path sees an empty
  # input set and pauses nothing.
  def source_quality_inputs
    []
  end

  def cost_recomputations
    @cost_recomputations || 0
  end

  def import(records)
    records.each do |record|
      existing = @rows.find { |row| row["url"] == record["url"] }
      if existing
        discovery = { "source" => record["source"], "url" => record["discovery_url"] }
        existing["discoveries"] = (Array(existing["discoveries"]) + [discovery]).uniq
        existing["sources"] = existing["discoveries"].map { |entry| entry["source"] }.uniq
      else
        timestamp = Time.now.utc
        @rows << record.merge(
          "archive_timestamp" => timestamp.iso8601,
          "archive_date" => timestamp.in_time_zone("America/New_York").to_date.iso8601,
          "sources" => [record["source"]],
          "discoveries" => [{ "source" => record["source"], "url" => record["discovery_url"] }],
          "topic_mappings" => []
        )
      end
    end
  end
end

class FixtureFetcher
  def initialize(html, allow_broken: false)
    @html = html
    @allow_broken = allow_broken
  end

  def fetch(url)
    if url.include?("broken.example") && !@allow_broken
      raise SafeFetcher::FetchError, "Article returned HTTP 503"
    end

    { url: url, body: @html, content_type: "text/html" }
  end
end

class FakeHttp
  API = "https://hacker-news.firebaseio.com/v0".freeze

  DEFAULT_USAGE = {
    "prompt_tokens" => 1000,
    "prompt_cache_hit_tokens" => 400,
    "completion_tokens" => 200
  }.freeze

  attr_reader :model_calls

  def initialize(items, usage: DEFAULT_USAGE)
    @items = items
    @usage = usage
    @model_calls = 0
  end

  def get_json(url)
    return [2001, 2002, 2003] if url == "#{API}/newstories.json"

    match = %r{/item/(\d+)\.json\z}.match(url)
    raise HttpClient::Error, "Unexpected GET #{url}" unless match && @items[match[1]]

    @items[match[1]]
  end

  # The committed allowlist now carries an RSS source, so the runner polls it
  # through this stub too. An item-less feed keeps the Hacker News paths the only
  # thing under test here.
  def get_text(url, accept: nil, timeout: nil)
    unless url == "https://softwareanalyst.substack.com/feed"
      raise HttpClient::Error, "Unexpected feed GET #{url}"
    end

    %(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Empty</title></channel></rss>)
  end

  def post_json(url, headers:, body:, timeout:)
    @model_calls += 1
    raise "Unexpected summary URL: #{url}" unless url == "https://llm.example/api/chat/completions"
    raise "Missing bearer token" unless headers["authorization"] == "Bearer test-secret-key"

    payload = JSON.parse(body)
    raise "System prompt leaked article instructions" if payload["messages"][0]["content"].include?("Prompt Injection")

    content = JSON.generate(
      summary: "The fixture article describes a public fetch and summarization batch. " \
        "It extracts publisher metadata before asking the configured model for a summary. " \
        "Failed stories are kept in a retry file for the next run.",
      depth: "Technical analysis",
      topics: ["Software Engineering", "Prompt Injection"],
      quality_score: 92
    )
    response = { "choices" => [{ "message" => { "content" => content } }] }
    response["usage"] = @usage if @usage
    JSON.generate(response)
  end
end

fixtures = File.expand_path("../fixtures/ingest", __dir__)
archive_rows = JSON.parse(File.read(File.join(fixtures, "archive.json")))
items = JSON.parse(File.read(File.join(fixtures, "items.json")))
article_html = File.read(File.join(fixtures, "article.html"))

provider_env = {
  "NEWSAGG_SUMMARY_PROVIDER" => "deepseek",
  "DEEPSEEK_API_KEY" => "test-secret-key",
  "DEEPSEEK_BASE_URL" => "https://llm.example/api/",
  "DEEPSEEK_MODEL" => "deepseek-chat",
  "NEO4J_PASSWORD" => "neo4j-secret"
}

TestReport.run do
  Dir.mktmpdir("newsagg-ingest-") do |directory|
    retry_path = File.join(directory, "retry.json")
    # The Hacker News path is exercised against a registry that lists only
    # Hacker News, so this suite does not depend on which sources the committed
    # allowlist ships with.
    allowlist_path = File.join(directory, "sources.yml")
    File.write(allowlist_path, <<~YAML)
      sources:
        - id: hacker-news
          name: Hacker News
          kind: api
          url: https://hacker-news.firebaseio.com/v0
          max_items: 10
          min_words: 40
    YAML
    registry = SourceRegistry.load(path: allowlist_path)
    http = FakeHttp.new(items)
    archive = DisposableArchive.new(archive_rows)

    runner_for = lambda do |target_archive, target_http, fetcher|
      IngestionRunner.new(
        archive: target_archive, retry_path: retry_path, http: target_http, fetcher: fetcher,
        summarizer: DeepseekSummarizer.new(env: provider_env, http: target_http),
        now: -> { Time.utc(2026, 11, 11, 12, 0, 0) },
        out: StringIO.new, err: @last_err = StringIO.new, env: provider_env, registry: registry
      )
    end

    first_code = runner_for.call(archive, http, FixtureFetcher.new(article_html))
      .run(feed: "new", limit: 5)

    check "a batch imports the summarizable story and skips the archived one" do
      assert(first_code == 1, "expected exit code 1 for a kept retry, got #{first_code}")
      imported = archive.articles.reject { |row| row["archive_timestamp"].nil? }
      assert(imported.length == 1, "expected one imported article, got #{imported.length}")
      record = imported.first
      assert(record["url"] == "https://news.example/story", "unexpected canonical URL #{record["url"].inspect}")
      assert(record["external_id"] == "2002", "unexpected external id #{record["external_id"].inspect}")
      assert(record["publisher"] == "Evil & Co Publishers", "unexpected publisher #{record["publisher"].inspect}")
      assert(record["topics"] == ["Software Engineering"], "topics were #{record["topics"].inspect}")
      assert(record["published_date"] == "2026-11-09", "published date was #{record["published_date"].inspect}")
      assert(http.model_calls == 1, "archived and failed fetches must not call the model")
    end

    check "an imported record carries the exact summary cost and token usage" do
      record = archive.articles.find { |row| row["url"] == "https://news.example/story" }
      assert(record, "the summarizable story was not imported")
      assert(record["summary_cost_usd"] == 0.00041,
        "expected $0.00041 for the fixture usage, got #{record["summary_cost_usd"].inspect}")
      assert(record["summary_input_tokens"] == 1000,
        "input tokens were #{record["summary_input_tokens"].inspect}")
      assert(record["summary_output_tokens"] == 200,
        "output tokens were #{record["summary_output_tokens"].inspect}")
      assert(record["summary_cache_read_tokens"] == 400,
        "cache-read tokens were #{record["summary_cache_read_tokens"].inspect}")
      assert(archive.cost_recomputations.positive?,
        "the import did not recompute the per-source cost")
    end

    check "an imported record carries the provider's quality score" do
      record = archive.articles.find { |row| row["url"] == "https://news.example/story" }
      assert(record, "the summarizable story was not imported")
      assert(record["quality_score"] == 92, "quality_score was #{record["quality_score"].inspect}")
      assert(record["quality_status"] == "ok", "quality_status was #{record["quality_status"].inspect}")
    end

    check "a failed story is written to the retry file without secrets" do
      retry_entries = JSON.parse(File.read(retry_path))
      assert(retry_entries.length == 1,
        "expected one retry entry, got #{retry_entries.map { |entry| [entry.dig("story", "external_id"), entry["reason"]] }.inspect}")
      assert(retry_entries.first["story"]["external_id"] == "2003", "wrong retry story")
      assert(retry_entries.first["attempts"] == 1, "wrong attempt count")
      assert(retry_entries.first["reason"].include?("HTTP 503"), "retry reason missing the failure")
      assert(!@last_err.string.include?("test-secret-key"), "the API key leaked to stderr")
      assert(!@last_err.string.include?("neo4j-secret"), "the Neo4j password leaked to stderr")
    end

    second_code = runner_for.call(archive, http,
      FixtureFetcher.new(article_html, allow_broken: true)).run(feed: "new", limit: 5)

    check "the next batch retries the failed story and clears the retry file" do
      assert(second_code.zero?, "expected exit code 0, got #{second_code}")
      assert(JSON.parse(File.read(retry_path)) == [], "retry file should be empty")
      imported = archive.articles.reject { |row| row["archive_timestamp"].nil? }
      assert(imported.length == 2, "expected two imported articles, got #{imported.length}")
      assert(http.model_calls == 2, "expected exactly one extra model call")
    end

    third_code = runner_for.call(archive, http, FixtureFetcher.new(article_html, allow_broken: true))
      .run(feed: "new", limit: 5)

    check "a batch over an already-archived feed performs no model call" do
      assert(third_code.zero?, "expected exit code 0, got #{third_code}")
      assert(http.model_calls == 2,
        "an archived story was summarized again (#{http.model_calls} model calls, expected 2)")
    end

    check "the imported records drive the Rails dashboard filter" do
      filter = DashboardFilter.new(archive.articles, ActionController::Parameters.new(q: "fails once"))
      assert(filter.visible.length == 1, "expected one matching article, got #{filter.visible.length}")
      assert(filter.count_text.start_with?("1 article"), "wrong count text #{filter.count_text.inspect}")
      assert(filter.visible.first["topics"] == ["Software Engineering"], "topics did not survive import")
    end

    # A provider response with no usage block must not abort the import; it
    # simply costs nothing as far as this call can tell.
    unpriced_archive = DisposableArchive.new(archive_rows)
    unpriced_http = FakeHttp.new(items, usage: nil)
    unpriced_code = runner_for.call(unpriced_archive, unpriced_http, FixtureFetcher.new(article_html))
      .run(feed: "new", limit: 5)

    check "a summary without a usage block imports with zero cost and zero tokens" do
      assert(unpriced_code == 1, "expected exit code 1 for the kept retry, got #{unpriced_code}")
      record = unpriced_archive.articles.find { |row| row["url"] == "https://news.example/story" }
      assert(record, "the story was not imported without a usage block")
      assert(record["summary_cost_usd"] == 0.0,
        "expected 0.0 cost, got #{record["summary_cost_usd"].inspect}")
      assert(record["summary_input_tokens"] == 0,
        "input tokens were #{record["summary_input_tokens"].inspect}")
      assert(record["summary_output_tokens"] == 0,
        "output tokens were #{record["summary_output_tokens"].inspect}")
      assert(record["summary_cache_read_tokens"] == 0,
        "cache-read tokens were #{record["summary_cache_read_tokens"].inspect}")
    end

    # A retry entry written by a failed import already carries its summary, so
    # replaying it must import the record without paying for it again.
    completed_record = {
      "url" => "https://retry.example/already-summarized",
      "title" => "A completed summary waiting in the retry file",
      "summary" => "This article was summarized before its import failed. " \
        "The retry file kept the finished record so the next batch could import it. " \
        "No second model call should ever be needed for it.",
      "depth" => "Overview",
      "publisher" => "Retry Press",
      "topics" => ["Software Engineering"],
      "source" => "Hacker News",
      "external_id" => "8899",
      "discovery_url" => "https://news.ycombinator.com/item?id=8899",
      "summary_cost_usd" => 0.00025,
      "summary_input_tokens" => 700,
      "summary_output_tokens" => 150,
      "summary_cache_read_tokens" => 200
    }
    completed_retry_path = File.join(directory, "retry-with-record.json")
    File.write(completed_retry_path, JSON.generate([{
      "story" => {
        "url" => completed_record["url"], "title" => completed_record["title"],
        "source" => "Hacker News", "external_id" => "8899",
        "discovery_url" => completed_record["discovery_url"]
      },
      "record" => completed_record,
      "attempts" => 1
    }]))
    replay_runner = IngestionRunner.new(
      archive: archive, retry_path: completed_retry_path, http: http,
      fetcher: FixtureFetcher.new(article_html), summarizer: DeepseekSummarizer.new(env: provider_env, http: http),
      now: -> { Time.utc(2026, 11, 11, 12, 0, 0) }, out: StringIO.new, err: StringIO.new,
      env: provider_env, registry: registry
    )
    replay_code = replay_runner.run(feed: "new", limit: 5)

    check "a retry entry carrying a record imports it without calling the model" do
      assert(replay_code.zero?, "expected exit code 0, got #{replay_code}")
      assert(http.model_calls == 2,
        "the completed retry entry was summarized again (#{http.model_calls} model calls, expected 2)")
      record = archive.articles.find { |row| row["url"] == completed_record["url"] }
      assert(record, "the completed retry record was not imported")
      assert(record["summary_cost_usd"] == 0.00025,
        "the retry record's cost was #{record["summary_cost_usd"].inspect}")
      assert(record["summary_input_tokens"] == 700,
        "the retry record's input tokens were #{record["summary_input_tokens"].inspect}")
      assert(record["quality_score"] == QualityScore::DEFAULT,
        "a retry record written before scoring existed did not take the default: #{record["quality_score"].inspect}")
      assert(record["quality_status"] == "default",
        "the defaulted score's status was #{record["quality_status"].inspect}")
    end

    # HackerNewsClient had no check of its own. This drives its archive-key path
    # with a stubbed client: the only story in the feed is already archived under
    # this source, so its discussion id must keep it out of the candidates. The
    # archived row carries a different article URL, so only the discovery id can
    # exclude item 42.
    hn_archive_rows = [{
      "url" => "https://news.example/archived-under-another-url",
      "discoveries" => [{
        "source" => "Hacker News",
        "url" => "https://news.ycombinator.com/item?id=42",
        "external_id" => "42"
      }]
    }]
    hn_stub = Object.new
    hn_stub.define_singleton_method(:get_json) do |url|
      return [42] if url == "https://hacker-news.firebaseio.com/v0/newstories.json"

      {
        "id" => 42, "type" => "story", "title" => "A story that is already archived",
        "url" => "https://news.example/archived-story", "time" => 1_760_000_000, "score" => 12
      }
    end
    hn_client = HackerNewsClient.new(name: "Hacker News", http: hn_stub)

    check "a Hacker News story archived under this source is not a candidate again" do
      candidates = hn_client.collect_candidates(feed: "new", limit: 5, archive_rows: hn_archive_rows)

      assert(candidates.none? { |entry| entry["external_id"] == "42" },
        "the archived discussion was returned as a candidate: #{candidates.inspect}")
    end

    # An importer that raises turns every record the batch produced into a
    # retry entry, with the importer's error as the reason. The broken fixture
    # story is archived here so the import failure is the only entry written,
    # and the password in that error must not survive into the file or stderr.
    import_rows = archive_rows + [{ "title" => "Fixture story that fails once", "url" => "https://broken.example/fail" }]
    import_retry_path = File.join(directory, "retry-import-failure.json")
    import_err = StringIO.new
    import_runner = IngestionRunner.new(
      archive: DisposableArchive.new(import_rows), retry_path: import_retry_path, http: http,
      fetcher: FixtureFetcher.new(article_html), summarizer: DeepseekSummarizer.new(env: provider_env, http: http),
      importer: ->(_records) { raise "Neo4j returned HTTP 401 for neo4j-secret" },
      now: -> { Time.utc(2026, 11, 11, 12, 0, 0) }, out: StringIO.new, err: import_err,
      env: provider_env, registry: registry
    )
    import_code = import_runner.run(feed: "new", limit: 5)

    check "a failed import is written to the retry file with its story and a redacted reason" do
      assert(import_code == 1, "expected exit code 1 for the kept retry, got #{import_code}")
      entries = JSON.parse(File.read(import_retry_path))
      assert(entries.length == 1,
        "expected one retry entry, got #{entries.map { |entry| [entry.dig("story", "external_id"), entry["reason"]] }.inspect}")
      entry = entries.first
      assert(entry["story"]["url"] == "https://news.example/story",
        "unexpected retry story url #{entry["story"]["url"].inspect}")
      assert(entry["story"]["title"] == "Fixture story with a hostile publisher",
        "unexpected retry story title #{entry["story"]["title"].inspect}")
      assert(entry["story"]["source"] == "Hacker News",
        "unexpected retry story source #{entry["story"]["source"].inspect}")
      assert(entry["story"]["external_id"] == "2002",
        "unexpected retry story external id #{entry["story"]["external_id"].inspect}")
      assert(entry["story"]["discovery_url"] == "https://news.ycombinator.com/item?id=2002",
        "unexpected retry story discovery url #{entry["story"]["discovery_url"].inspect}")
      assert(entry["story"].keys.sort == %w[discovery_url external_id source title url],
        "the retry story carried #{entry["story"].keys.sort.inspect}")
      assert(entry["reason"].start_with?("import failed: "),
        "retry reason was #{entry["reason"].inspect}")
      assert(entry["reason"].include?("HTTP 401"), "retry reason missing the failure")
      assert(!JSON.generate(entry).include?("neo4j-secret"), "the Neo4j password leaked into the retry entry")
      assert(!import_err.string.include?("neo4j-secret"), "the Neo4j password leaked to stderr")
    end
  end
end
