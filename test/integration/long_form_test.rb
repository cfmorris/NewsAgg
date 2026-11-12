ENV["RAILS_ENV"] = "test"

require "cgi"
require "json"
require "rack/mock"
require "stringio"
require "tmpdir"
require "uri"

require_relative "../../config/environment"
require_relative "../../app/services/article_chunker"
require_relative "../../app/services/article_extractor"
require_relative "../../app/services/deepseek_summarizer"
require_relative "../../app/services/import_records"
require_relative "../../app/services/ingest_batch"
require_relative "../../app/services/long_form"
require_relative "../../app/services/taxonomy"
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
    - name: Longform Feed
      kind: rss
      url: https://feed.example/rss
      domains: ["allowed.example"]
YAML

# One call's usage, priced at $0.00041 by the summarizer's own rates. Four calls
# therefore cost $0.00164, which is the arithmetic the roll-up checks.
CALL_USAGE = {
  "prompt_tokens" => 1000, "prompt_cache_hit_tokens" => 400, "completion_tokens" => 200
}.freeze
CALL_COST = 0.00041

# Provider double. It answers a condensing call with one part summary and the
# synthesis call with the archive contract, and records every request so the
# suite can count calls and measure the text each one carried.
class LongHttp
  attr_reader :calls

  def initialize(usage: CALL_USAGE)
    @usage = usage
    @calls = []
  end

  def post_json(url, headers:, body:, timeout:)
    raise "unexpected summary URL #{url}" unless url == "https://llm.example/api/chat/completions"
    raise "missing bearer token" unless headers["authorization"] == "Bearer test-secret-key"

    payload = JSON.parse(body)
    system = payload["messages"].first["content"]
    content = JSON.parse(payload["messages"].last["content"])
    @calls << { "system" => system, "content" => content, "max_tokens" => payload["max_tokens"] }

    answer = if system.include?("condense one part")
      {
        summary: "Part #{content["part"]} reports a finding, the evidence behind it and the number it changed. " \
          "It names the system under test and the measurement that moved.",
        # A stray score on a condensing call must not reach the article.
        quality_score: 5
      }
    else
      {
        summary: "The report reads one long argument across its parts and closes with what it measured. " \
          "It states which system changed, by how much, and where the evidence came from. " \
          "The synthesis sees every part before it writes this summary.",
        depth: "Deep dive",
        topics: ["Software Engineering"],
        quality_score: 91
      }
    end

    response = { "choices" => [{ "message" => { "content" => JSON.generate(answer) } }] }
    response["usage"] = @usage if @usage
    JSON.generate(response)
  end

  def model_calls
    @calls.length
  end

  def chunk_calls
    @calls.count { |call| call["system"].include?("condense one part") }
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
  def initialize(html)
    @html = html
  end

  def fetch(url)
    { url: url, body: @html, content_type: "text/html" }
  end
end

# A provider that stops mid-answer because it ran out of output tokens, which is
# what a reasoning model does when its budget is sized for the answer alone.
class TruncatingHttp
  def post_json(url, headers:, body:, timeout:)
    raise "unexpected summary URL #{url}" unless url == "https://llm.example/api/chat/completions"

    JSON.generate(
      "choices" => [{
        "finish_reason" => "length",
        "message" => { "content" => '{"summary":"A part summary that stops in the mid' }
      }],
      "usage" => CALL_USAGE
    )
  end
end

# Returns whatever text the test hands it, so length thresholds can be exercised
# exactly without depending on how much markup the extractor keeps.
class FixedExtractor
  def initialize(text)
    @text = text
  end

  def extract(_body, uri, content_type:)
    { text: @text, publisher: uri.hostname, published_date: nil }
  end

  def sanitize_title(value)
    value.to_s
  end

  def sanitize_publisher(value, fallback)
    value.to_s.empty? ? fallback : value
  end
end

# A summarizer that answers without a provider, for the threshold and tag
# checks where call plumbing is not what is under test.
class StubSummarizer
  def initialize(topics: ["Software Engineering"])
    @topics = topics
  end

  def summarize(url:, title:, publisher:, text:)
    {
      "summary" => "A summary long enough to satisfy the importer contract for a stub article.",
      "depth" => "Overview", "topics" => @topics,
      "quality_score" => 70, "quality_status" => "ok",
      "strategy" => "single", "chunk_count" => 1, "model_calls" => 1,
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5,
                   "prompt_cache_hit_tokens" => 0, "cost_usd" => 0.0 },
      "cost_usd" => 0.0
    }
  end
end

# Mirrors the archive's write contract for the summarized facts: written on
# create only, so a replay keeps what the first import paid for.
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

  # Source scoring reads each source's scored articles from the archive; this
  # stand-in has no source nodes, so the import path scores nothing.
  def source_quality_inputs
    []
  end

  def import(records)
    records.each do |record|
      next if @rows.any? { |row| row["url"] == record["url"] }

      @rows << record.merge("sources" => [record["source"]], "topic_mappings" => [])
    end
  end
end

STORIES = [
  { "title" => "The long report", "url" => "https://allowed.example/report",
    "external_id" => "long-1", "source" => "Longform Feed" }
].freeze

# Twenty-five thousand characters of prose, with or without headings, written as
# the HTML a publisher would ship.
def article_html(sections: 8, paragraphs: 12, sentences: 5, headings: true)
  paragraph = "<p>#{"A sentence that states a measured finding and its evidence. " * sentences}</p>"
  body = (1..sections).map do |index|
    "#{headings ? "<h2>Part #{index}</h2>" : ""}#{paragraph * paragraphs}"
  end.join
  "<html><body><article>#{body}</article></body></html>"
end

TestReport.run do
  Dir.mktmpdir("newsagg-longform-") do |directory|
    allowlist = File.join(directory, "sources.yml")
    File.write(allowlist, ALLOWLIST)
    registry = SourceRegistry.load(path: allowlist)
    extractor = ArticleExtractor.new

    # One ingest pass over a stubbed feed, imported through the real importer.
    ingest = lambda do |html: nil, text: nil, summarizer: nil, http: nil, archive: RecordingArchive.new|
      logs = []
      http ||= LongHttp.new
      summarizer ||= DeepseekSummarizer.new(env: PROVIDER_ENV, http: http, log: ->(line) { logs << line })
      batch = IngestBatch.new(
        adapters: { "Longform Feed" => StubAdapter.new(STORIES) },
        gate: SourceGate.new(registry: registry),
        fetcher: StubFetcher.new(html || article_html),
        summarizer: summarizer,
        extractor: text ? FixedExtractor.new(text) : extractor,
        now: -> { Time.utc(2026, 11, 12, 12, 0, 0) }
      )
      result = batch.run(feed: "new", limit: 1, archive_rows: [])
      ImportRecords.new(archive: archive, registry: registry).call(result[:records]) if result[:records].any?

      {
        row: archive.articles.find { |row| row["url"] == "https://allowed.example/report" },
        result: result, http: http, logs: logs, archive: archive
      }
    end

    long = ingest.call
    long_text = extractor.extract(article_html, URI.parse("https://allowed.example/report"))[:text]

    check "a 25k article is read in parts and synthesized" do
      assert(long_text.length.between?(24_000, 40_000), "the fixture extracted #{long_text.length} characters")
      assert(long[:row], "the long article was not imported: #{long[:result][:failures].inspect}")
      assert(long[:http].chunk_calls == 3, "expected 3 chunk calls, got #{long[:http].chunk_calls}")
      assert(long[:http].model_calls == 4,
        "expected 3 chunk calls plus one synthesis, got #{long[:http].model_calls}")
      assert(long[:result][:model_calls] == 4, "the batch counted #{long[:result][:model_calls]} model calls")
      assert(long[:row]["summary_strategy"] == "headings",
        "the article recorded strategy #{long[:row]["summary_strategy"].inspect}")
      assert(long[:row]["summary_chunk_count"] == 3,
        "the article recorded #{long[:row]["summary_chunk_count"].inspect} chunks")
    end

    check "the article's cost and tokens roll up every call" do
      row = long[:row]
      assert(row["summary_cost_usd"].round(10) == (CALL_COST * 4).round(10),
        "cost was #{row["summary_cost_usd"].inspect}, expected #{(CALL_COST * 4).round(10)}")
      assert(row["summary_input_tokens"] == 4000, "input tokens were #{row["summary_input_tokens"].inspect}")
      assert(row["summary_output_tokens"] == 800, "output tokens were #{row["summary_output_tokens"].inspect}")
      assert(row["summary_cache_read_tokens"] == 1600,
        "cache-read tokens were #{row["summary_cache_read_tokens"].inspect}")
    end

    check "no provider request carries more than one window" do
      carried = long[:http].calls.map { |call| call["content"]["text"].to_s.length }
      assert(carried.length == 4, "expected four requests, got #{carried.inspect}")
      assert(carried.max <= ArticleChunker::WINDOW,
        "a request carried #{carried.max} characters, over the #{ArticleChunker::WINDOW} window")
      assert(carried.last.zero?, "the synthesis request re-sent the article text instead of the parts")
    end

    check "the synthesis receives every part summary and decides the score" do
      synthesis = long[:http].calls.last["content"]
      assert(Array(synthesis["part_summaries"]).length == 3,
        "the synthesis got #{Array(synthesis["part_summaries"]).length} part summaries")
      assert(long[:row]["quality_score"] == 91,
        "the article scored #{long[:row]["quality_score"].inspect}; a chunk's score leaked through")
      assert(long[:row]["summary"].include?("synthesis"),
        "the stored summary is not the synthesis: #{long[:row]["summary"].inspect}")
    end

    check "a document without headings falls back to fixed windows" do
      plain = ingest.call(html: article_html(headings: false))
      assert(plain[:row], "the headingless article was not imported: #{plain[:result][:failures].inspect}")
      assert(plain[:row]["summary_strategy"] == "windows",
        "the article recorded strategy #{plain[:row]["summary_strategy"].inspect}")
      assert(plain[:row]["summary_chunk_count"] == 3,
        "the headingless article used #{plain[:row]["summary_chunk_count"].inspect} chunks")
      assert(plain[:http].chunk_calls == 3, "expected 3 chunk calls, got #{plain[:http].chunk_calls}")
    end

    check "a short article is summarized in one unchanged call" do
      short = ingest.call(html: "<html><body><article><p>" +
        ("A short news item that reports one thing and stops. " * 20) + "</p></article></body></html>")
      assert(short[:row], "the short article was not imported: #{short[:result][:failures].inspect}")
      assert(short[:http].model_calls == 1, "the short article cost #{short[:http].model_calls} calls")
      assert(short[:row]["summary_strategy"] == "single",
        "the short article recorded strategy #{short[:row]["summary_strategy"].inspect}")
      assert(short[:row]["summary_chunk_count"] == 1,
        "the short article recorded #{short[:row]["summary_chunk_count"].inspect} chunks")
      assert(short[:row]["summary_cost_usd"].round(10) == CALL_COST.round(10),
        "the short article cost #{short[:row]["summary_cost_usd"].inspect}")
      assert(short[:http].calls.last["content"]["text"].to_s.length.positive?,
        "the single call carried no text")
      assert(!short[:row]["topics"].include?(LongForm::TAG),
        "a short article was tagged #{LongForm::TAG}")
    end

    check "an 80k report is no longer truncated before the summarizer" do
      html = article_html(sections: 20, paragraphs: 12, sentences: 5)
      text = extractor.extract(html, URI.parse("https://allowed.example/report"))[:text]
      plan = ArticleChunker.new.call(text)

      assert(text.length > ArticleExtractor::MAX_TEXT * 5,
        "an 80k report extracted only #{text.length} characters")
      assert(plan.chunk_count.between?(6, ArticleChunker::MAX_CHUNKS),
        "the report produced #{plan.chunk_count} chunks")
      assert(plan.chunks.all? { |chunk| chunk.length <= ArticleChunker::WINDOW },
        "a chunk exceeded the window: #{plan.chunks.map(&:length).inspect}")
    end

    check "the chunk count is capped" do
      plan = ArticleChunker.new.call("word " * 60_000)
      assert(plan.chunk_count == ArticleChunker::MAX_CHUNKS,
        "a 300k document produced #{plan.chunk_count} chunks")
      assert(plan.chunks.all? { |chunk| chunk.length <= ArticleChunker::WINDOW },
        "a chunk exceeded the window: #{plan.chunks.map(&:length).inspect}")
    end

    check "a truncated provider answer keeps the story for retry instead of importing half a summary" do
      cut = ingest.call(http: TruncatingHttp.new)
      assert(cut[:row].nil?, "a truncated answer still produced an article")
      reason = cut[:result][:failures].first.to_h["reason"].to_s
      assert(reason.include?("ran out of output tokens"),
        "the failure reason was #{reason.inspect}")
    end

    check "the Long form tag appears exactly when the length threshold is crossed" do
      below = ingest.call(text: "x" * (LongForm::THRESHOLD - 1), summarizer: StubSummarizer.new)
      at = ingest.call(text: "x" * LongForm::THRESHOLD, summarizer: StubSummarizer.new)

      assert(!below[:row]["topics"].include?(LongForm::TAG),
        "#{LongForm::THRESHOLD - 1} characters were tagged long form")
      assert(at[:row]["topics"].include?(LongForm::TAG),
        "#{LongForm::THRESHOLD} characters were not tagged long form: #{at[:row]["topics"].inspect}")
      assert(at[:row]["topics"].last == LongForm::TAG, "the tag displaced a subject topic")
    end

    check "the model cannot add the Long form tag itself" do
      chosen = ingest.call(text: "A short article the model tried to tag, long enough to be summarized.", summarizer: StubSummarizer.new(topics: ["Software Engineering", LongForm::TAG]))
      assert(!chosen[:row]["topics"].include?(LongForm::TAG),
        "a model-chosen tag reached the article: #{chosen[:row]["topics"].inspect}")
      assert(LongForm.topics([LongForm::TAG], 25_000) == [LongForm::TAG],
        "the tag was duplicated when the model also returned it")
    end

    check "the taxonomy seeds the tag as a topic but never offers it to the model" do
      tags = Taxonomy.load
      assert(tags.include?("Software Engineering"), "the subject topics went missing")
      assert(!tags.include?(LongForm::TAG),
        "the model is offered #{LongForm::TAG} as a topic")
      assert(Taxonomy::DEFAULT_PATH && File.read(Taxonomy::DEFAULT_PATH).include?("tag:\"#{LongForm::TAG}\""),
        "the taxonomy does not seed the long-form tag")
    end

    check "a replayed record without a strategy is recorded as a single call" do
      archive = RecordingArchive.new
      record = {
        "url" => "https://allowed.example/replayed", "title" => "A replayed record",
        "summary" => "A summary written before chunking existed, replayed from an old retry file.",
        "depth" => "Overview", "publisher" => "Longform Press",
        "topics" => ["Software Engineering"], "source" => "Longform Feed",
        "external_id" => "replay-1", "summary_cost_usd" => 0.0002
      }
      ImportRecords.new(archive: archive, registry: registry).call([record])
      row = archive.articles.first
      assert(row["summary_strategy"] == "single", "the replay recorded #{row["summary_strategy"].inspect}")
      assert(row["summary_chunk_count"] == 1, "the replay recorded #{row["summary_chunk_count"].inspect} chunks")
    end

    # The dashboard side: rows straight out of the archive, one long and one not.
    def article_row(overrides)
      {
        "title" => "Untitled", "summary" => "A summary that stands on its own.", "publisher" => "Fixture Press",
        "depth" => "Technical analysis", "topics" => ["Software Engineering"], "sources" => ["Longform Feed"],
        "discoveries" => [], "topic_mappings" => [], "published_date" => "2026-11-10",
        "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00",
        "quality_score" => 70, "quality_status" => "ok", "summary_strategy" => "single",
        "summary_chunk_count" => 1, "url" => "https://example.test/untitled"
      }.merge(overrides)
    end

    mapping = { "topic" => LongForm::TAG, "heading" => "Format", "id" => "urn:technical-reading-room:format" }
    rows = [
      article_row("title" => "A long report", "url" => "https://example.test/long",
        "topics" => ["Software Engineering", LongForm::TAG],
        "topic_mappings" => [{ "topic" => "Software Engineering", "heading" => "Software and its engineering" }, mapping],
        "summary_strategy" => "headings", "summary_chunk_count" => 3),
      article_row("title" => "A short note", "url" => "https://example.test/short",
        "topic_mappings" => [{ "topic" => "Software Engineering", "heading" => "Software and its engineering" }])
    ]

    filter_for = ->(params) { DashboardFilter.new(rows, ActionController::Parameters.new(params)) }

    check "the Long form tag is a filterable topic of its own" do
      filter = filter_for.call(topic: LongForm::TAG)
      assert(filter.visible.map { |row| row["title"] } == ["A long report"],
        "the tag filter returned #{filter.visible.map { |row| row["title"] }.inspect}")

      group = filter_for.call({}).topic_tree.find { |entry| entry[:heading] == "Format" }
      assert(group, "the tag has no Format group in the sidebar")
      assert(group[:topics].map { |topic| topic[:name] } == [LongForm::TAG],
        "the Format group holds #{group[:topics].inspect}")
      assert(group[:count] == 1, "the Format group counted #{group[:count]}")
    end

    request = Rack::MockRequest.new(Rails.application)
    auth = { "HTTP_HOST" => "127.0.0.1:3000", "HTTP_COOKIE" => sign_in_cookie }

    check "GET /articles and the dashboard carry the summary marker and the tag" do
      Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
      payload = JSON.parse(request.get("/articles", auth).body)
      long_row = payload.find { |row| row["url"] == "https://example.test/long" }
      assert(long_row["summary_strategy"] == "headings",
        "the payload strategy was #{long_row["summary_strategy"].inspect}")
      assert(long_row["summary_chunk_count"] == 3,
        "the payload chunk count was #{long_row["summary_chunk_count"].inspect}")

      body = request.get("/dashboard", auth).body
      card = body.scan(%r{<article>.*?</article>}m).find { |html| html.include?("A long report") }
      assert(card, "no card rendered for the long report")
      assert(card.include?(">#{LongForm::TAG}<"), "the card does not show the tag: #{card[0, 500].inspect}")
      assert(body.include?("Format"), "the sidebar has no Format heading")
    end
  end
end
