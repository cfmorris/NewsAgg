ENV["RAILS_ENV"] = "test"

require "cgi"
require "json"
require "rack/mock"
require "stringio"
require "tmpdir"
require "uri"

require_relative "../../config/environment"
require_relative "../../app/services/deepseek_summarizer"
require_relative "../../app/services/ingest_batch"
require_relative "../../app/services/ingestion_runner"
require_relative "../../app/services/source_gate"
require_relative "../../app/services/source_registry"
require_relative "../support/assertions"
require_relative "../support/fake_archive"
require_relative "../support/signed_in"

include TestReport

PROVIDER_ENV = {
  "NEWSAGG_SUMMARY_PROVIDER" => "deepseek",
  "DEEPSEEK_API_KEY" => "test-secret-key",
  "DEEPSEEK_BASE_URL" => "https://llm.example/api/",
  "DEEPSEEK_MODEL" => "deepseek-chat",
  "NEO4J_PASSWORD" => "neo4j-secret"
}.freeze

ALLOWLIST = <<~YAML
  sources:
    - name: Quality Feed
      kind: rss
      url: https://feed.example/rss
      domains: ["allowed.example"]
YAML

# A provider double that answers with whatever quality_score the test asks for.
# MISSING leaves the key out entirely, which is how a provider that ignored the
# rubric answers.
class QualityHttp
  MISSING = Object.new.freeze

  attr_reader :system_prompt

  def initialize(quality_score)
    @quality_score = quality_score
  end

  def post_json(url, headers:, body:, timeout:)
    raise "unexpected summary URL #{url}" unless url == "https://llm.example/api/chat/completions"
    raise "missing bearer token" unless headers["authorization"] == "Bearer test-secret-key"

    payload = JSON.parse(body)
    @system_prompt = payload["messages"].first["content"]

    content = {
      summary: "The fixture article describes how a scoring rubric reaches the archive. " \
        "It extracts the publisher before asking the configured model for a summary. " \
        "The score rides along with the summary in the same response.",
      depth: "Technical analysis",
      topics: ["Software Engineering"]
    }
    content[:quality_score] = @quality_score unless @quality_score.equal?(MISSING)

    JSON.generate(
      "choices" => [{ "message" => { "content" => JSON.generate(content) } }],
      "usage" => { "prompt_tokens" => 1000, "prompt_cache_hit_tokens" => 400, "completion_tokens" => 200 }
    )
  end
end

class StubAdapter
  def initialize(stories)
    @stories = stories
  end

  def archive_keys(_rows)
    [[], []]
  end

  def collect_candidates(feed:, limit:, archive_rows:)
    @stories.first(limit)
  end
end

class StubFetcher
  def fetch(url)
    { url: url, body: "<html><body><article><p>#{'A fetched article body. ' * 4}</p></article></body></html>",
      content_type: "text/html" }
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

# Stands in for the Neo4j archive and mirrors its write contract: the summarised
# facts - quality score included - are written on create only, so a replay keeps
# what the first import paid for.
class RecordingArchive
  def initialize(rows = [])
    @rows = rows.map(&:dup)
  end

  def articles
    @rows
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  def sync_sources(sources)
    sources.length
  end

  def recompute_source_costs; end

  def import(records)
    records.each do |record|
      next if @rows.any? { |row| row["url"] == record["url"] }

      @rows << record.merge("sources" => [record["source"]], "topic_mappings" => [])
    end
  end
end

STORIES = [
  { "title" => "A scored story", "url" => "https://allowed.example/post",
    "external_id" => "1", "source" => "Quality Feed" }
].freeze

TestReport.run do
  Dir.mktmpdir("newsagg-quality-") do |directory|
    allowlist = File.join(directory, "sources.yml")
    File.write(allowlist, ALLOWLIST)
    registry = SourceRegistry.load(path: allowlist)

    # One ingest pass over a stubbed feed. Returns the row it wrote, the lines
    # the summarizer logged, and the provider double so the prompt is inspectable.
    ingest = lambda do |provider_score, archive: RecordingArchive.new|
      logs = []
      http = QualityHttp.new(provider_score)
      summarizer = DeepseekSummarizer.new(env: PROVIDER_ENV, http: http, log: ->(line) { logs << line })
      batch = IngestBatch.new(
        adapters: { "Quality Feed" => StubAdapter.new(STORIES) },
        gate: SourceGate.new(registry: registry),
        fetcher: StubFetcher.new,
        summarizer: summarizer,
        extractor: StubExtractor.new,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) }
      )
      runner = IngestionRunner.new(
        archive: archive, retry_path: File.join(directory, "retry-#{SecureRandom.hex(3)}.json"),
        http: http, fetcher: StubFetcher.new, summarizer: summarizer, batch: batch,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) },
        out: StringIO.new, err: StringIO.new, env: PROVIDER_ENV, registry: registry
      )
      runner.run(feed: "new", limit: 5)

      { article: archive.articles.find { |row| row["url"] == "https://allowed.example/post" },
        logs: logs, http: http, archive: archive }
    end

    scored = ingest.call(87)

    check "a summarizer score of 87 is stored on the article" do
      article = scored[:article]
      assert(article, "the scored story was not imported")
      assert(article["quality_score"] == 87, "quality_score was #{article["quality_score"].inspect}")
      assert(article["quality_status"] == "ok", "quality_status was #{article["quality_status"].inspect}")
      assert(scored[:logs].empty?, "a valid score was logged as a substitution: #{scored[:logs].inspect}")
    end

    check "the summarizer prompt carries the 1-100 rubric and asks for the score" do
      prompt = scored[:http].system_prompt.to_s
      assert(prompt.include?("quality_score"), "the prompt does not ask for quality_score")
      assert(prompt.include?("1 to 100"), "the prompt does not state the 1-100 scale")
      assert(prompt.include?("90-100") && prompt.include?("1-29"), "the prompt carries no rubric bands")
    end

    check "a score below the scale is clamped to 1 and logged" do
      low = ingest.call(0)
      assert(low[:article]["quality_score"] == 1, "quality_score was #{low[:article]["quality_score"].inspect}")
      assert(low[:article]["quality_status"] == "clamped", "status was #{low[:article]["quality_status"].inspect}")
      assert(low[:logs].any? { |line| line.include?("outside 1-100") && line.include?("clamped to 1") },
        "the clamp was not logged: #{low[:logs].inspect}")
    end

    check "a score above the scale is clamped to 100 and logged" do
      high = ingest.call(101)
      assert(high[:article]["quality_score"] == 100, "quality_score was #{high[:article]["quality_score"].inspect}")
      assert(high[:article]["quality_status"] == "clamped", "status was #{high[:article]["quality_status"].inspect}")
      assert(high[:logs].any? { |line| line.include?("clamped to 100") }, "the clamp was not logged: #{high[:logs].inspect}")
    end

    check "a missing score falls back to the documented default and is logged" do
      absent = ingest.call(QualityHttp::MISSING)
      assert(absent[:article], "a summary without a score aborted the import")
      assert(absent[:article]["quality_score"] == QualityScore::DEFAULT,
        "quality_score was #{absent[:article]["quality_score"].inspect}")
      assert(absent[:article]["quality_status"] == "default", "status was #{absent[:article]["quality_status"].inspect}")
      assert(absent[:logs].any? { |line| line.include?("default of #{QualityScore::DEFAULT}") },
        "the default was not logged: #{absent[:logs].inspect}")
    end

    check "a non-numeric score falls back to the default instead of failing the story" do
      jumbled = ingest.call("excellent")
      assert(jumbled[:article], "an unparseable score aborted the import")
      assert(jumbled[:article]["quality_score"] == QualityScore::DEFAULT,
        "quality_score was #{jumbled[:article]["quality_score"].inspect}")
      assert(jumbled[:article]["quality_status"] == "default", "status was #{jumbled[:article]["quality_status"].inspect}")
    end

    check "a re-scored article keeps the first score and is not charged again" do
      archive = scored[:archive]
      first_cost = scored[:article]["summary_cost_usd"]
      replay = scored[:article].merge(
        "quality_score" => 12, "quality_status" => "ok", "summary_cost_usd" => 0.99
      )
      ImportRecords.new(archive: archive, registry: registry).call([replay])

      rows = archive.articles.select { |row| row["url"] == "https://allowed.example/post" }
      assert(rows.length == 1, "the replay created #{rows.length} rows")
      assert(rows.first["quality_score"] == 87,
        "the replay replaced the score with #{rows.first["quality_score"].inspect}")
      assert(rows.first["summary_cost_usd"] == first_cost,
        "the replay changed the cost to #{rows.first["summary_cost_usd"].inspect}")
    end

    # The dashboard side: rows straight out of the archive, plus one written
    # before quality scoring existed.
    def article_row(overrides)
      {
        "title" => "Untitled", "summary" => "A summary that stands on its own.", "publisher" => "Fixture Press",
        "depth" => "Technical analysis", "topics" => ["Software Engineering"], "sources" => ["Quality Feed"],
        "discoveries" => [], "topic_mappings" => [], "published_date" => "2026-11-10",
        "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00",
        "url" => "https://example.test/untitled"
      }.merge(overrides)
    end

    rows = [
      article_row("title" => "Ordinary coverage", "url" => "https://example.test/ordinary",
        "quality_score" => 61, "quality_status" => "ok", "archive_timestamp" => "2026-11-12T09:00:00-05:00"),
      article_row("title" => "Landmark analysis", "url" => "https://example.test/landmark",
        "quality_score" => 88, "quality_status" => "ok", "archive_timestamp" => "2026-11-11T09:00:00-05:00"),
      article_row("title" => "Second landmark", "url" => "https://example.test/landmark-two",
        "quality_score" => 88, "quality_status" => "ok", "archive_timestamp" => "2026-11-10T09:00:00-05:00"),
      article_row("title" => "Unscored legacy piece", "url" => "https://example.test/legacy")
    ]

    filter_for = ->(params) { DashboardFilter.new(rows, ActionController::Parameters.new(params)) }

    check "sorting by quality ranks scored articles and leaves unscored ones last" do
      sorted = filter_for.call(sort: "quality").visible.map { |row| row["title"] }
      assert(sorted == ["Landmark analysis", "Second landmark", "Ordinary coverage", "Unscored legacy piece"],
        "quality order was #{sorted.inspect}")
    end

    check "the archive order survives when no sort is requested or the sort is unknown" do
      newest = filter_for.call({}).visible.map { |row| row["title"] }
      assert(newest.first == "Ordinary coverage", "the default order started with #{newest.first.inspect}")
      fallback = filter_for.call(sort: "relevance").visible.map { |row| row["title"] }
      assert(fallback == newest, "an unknown sort changed the order to #{fallback.inspect}")
    end

    request = Rack::MockRequest.new(Rails.application)
    auth = { "HTTP_HOST" => "127.0.0.1:3000", "HTTP_COOKIE" => sign_in_cookie }

    def card_for(html, title)
      html.scan(%r{<article>.*?</article>}m).find { |card| card.include?(title) } ||
        raise("no article card rendered for #{title.inspect}")
    end

    check "GET /articles carries the score and its status, and null for unscored rows" do
      Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
      response = request.get("/articles", auth)
      assert(response.ok?, "expected HTTP 200, got #{response.status}")
      payload = JSON.parse(response.body)
      landmark = payload.find { |row| row["url"] == "https://example.test/landmark" }
      legacy = payload.find { |row| row["url"] == "https://example.test/legacy" }
      assert(landmark["quality_score"] == 88, "payload quality_score was #{landmark["quality_score"].inspect}")
      assert(landmark["quality_status"] == "ok", "payload quality_status was #{landmark["quality_status"].inspect}")
      assert(legacy["quality_score"].nil?, "an unscored row carried #{legacy["quality_score"].inspect}")
    end

    check "the article card shows the quality score" do
      Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
      body = request.get("/dashboard", auth).body

      card = card_for(body, "Landmark analysis")
      assert(card.include?("Quality 88"), "the card does not show the score: #{card[0, 400].inspect}")

      legacy = card_for(body, "Unscored legacy piece")
      assert(!legacy.include?("Quality"), "an unscored article rendered a quality label")
    end

    check "the sidebar sorts by quality and keeps the choice" do
      Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
      body = request.get("/dashboard?q=piece", auth).body
      links = body.scan(/<a [^>]*>.*?<\/a>/m)

      quality_link = links.find { |link| link.include?("sort-option") && link.include?("Highest quality") }
      assert(quality_link, "the sidebar has no Highest quality sort link")
      href = CGI.unescapeHTML(quality_link[/href="([^"]+)"/, 1])
      query = URI(href).query.to_s
      assert(query.include?("sort=quality"), "the sort link does not set sort=quality: #{href}")
      assert(query.include?("q=piece"), "the sort link dropped the search filter: #{href}")

      sorted = request.get("/dashboard?sort=quality", auth).body
      sorted_links = sorted.scan(/<a [^>]*>.*?<\/a>/m)
      pressed = sorted_links.select { |link| link.include?("sort-option") && link.include?('aria-pressed="true"') }
      assert(pressed.length == 1 && pressed.first.include?("Highest quality"),
        "the quality sort is not the pressed option: #{pressed.inspect}")
      assert(sorted.index("Landmark analysis") < sorted.index("Ordinary coverage"),
        "the quality-sorted page is still in archive order")
      assert(sorted.include?('name="sort" value="quality"'),
        "a filter change submitted from this page would reset the quality sort")
    end
  end
end
