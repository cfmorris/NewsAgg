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

  attr_reader :model_calls

  def initialize(items)
    @items = items
    @model_calls = 0
  end

  def get_json(url)
    return [2001, 2002, 2003] if url == "#{API}/newstories.json"

    match = %r{/item/(\d+)\.json\z}.match(url)
    raise HttpClient::Error, "Unexpected GET #{url}" unless match && @items[match[1]]

    @items[match[1]]
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
      topics: ["Software Engineering", "Prompt Injection"]
    )
    JSON.generate("choices" => [{ "message" => { "content" => content } }])
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
    http = FakeHttp.new(items)
    archive = DisposableArchive.new(archive_rows)

    runner_for = lambda do |target_archive, target_http, fetcher|
      IngestionRunner.new(
        archive: target_archive, retry_path: retry_path, http: target_http, fetcher: fetcher,
        summarizer: DeepseekSummarizer.new(env: provider_env, http: target_http),
        now: -> { Time.utc(2026, 11, 11, 12, 0, 0) },
        out: StringIO.new, err: @last_err = StringIO.new, env: provider_env
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

    check "a failed story is written to the retry file without secrets" do
      retry_entries = JSON.parse(File.read(retry_path))
      assert(retry_entries.length == 1, "expected one retry entry")
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

    check "the imported records drive the Rails dashboard filter" do
      filter = DashboardFilter.new(archive.articles, ActionController::Parameters.new(q: "fails once"))
      assert(filter.visible.length == 1, "expected one matching article, got #{filter.visible.length}")
      assert(filter.count_text.start_with?("1 article"), "wrong count text #{filter.count_text.inspect}")
      assert(filter.visible.first["topics"] == ["Software Engineering"], "topics did not survive import")
    end
  end
end
