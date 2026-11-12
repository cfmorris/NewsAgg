require "json"
require "time"
require "securerandom"
require "uri"
require "active_support/time"

require_relative "../../app/services/archive"

def refuse(message)
  warn "Refusing to run the disposable-Neo4j test: #{message}"
  exit 1
end

url = ENV["NEO4J_HTTP_URL"].to_s
refuse("set NEO4J_HTTP_URL to the disposable test instance") if url.empty?
uri = begin
  URI.parse(url)
rescue URI::InvalidURIError
  nil
end
refuse("NEO4J_HTTP_URL is not a valid URL") unless uri&.host
refuse("NEO4J_HTTP_URL must be loopback") unless ["127.0.0.1", "localhost", "::1"].include?(uri.host)
refuse("the default Neo4j port 7474 is never used for tests") if uri.port == 7474
refuse("set NEO4J_TEST_DISPOSABLE=1 to confirm the database can be discarded") unless ENV["NEO4J_TEST_DISPOSABLE"] == "1"
refuse("set NEO4J_PASSWORD for the disposable instance") if ENV["NEO4J_PASSWORD"].to_s.empty?

$checks = 0
$failures = []

def check(name)
  $checks += 1
  yield
  puts "ok - #{name}"
rescue StandardError => error
  $failures << [name, error]
  puts "not ok - #{name}"
  puts "    #{error.class}: #{error.message}"
end

def assert(condition, message)
  raise message unless condition
end

run = SecureRandom.hex(6)
base = "https://example.test/newsagg-repeat-#{run}"
article_one = "#{base}/article-one"
article_two = "#{base}/article-two"
published_date = "2020-01-02"

first_batch = [
  {
    "url" => article_one,
    "title" => "Original title",
    "summary" => "Original summary that a replay must keep.",
    "depth" => "Deep dive",
    "publisher" => "Fixture Press",
    "topics" => ["Software Engineering"],
    "source" => "Hacker News",
    "external_id" => "7001",
    "discovery_url" => "https://news.ycombinator.com/item?id=7001",
    "published_date" => published_date,
    "quality_score" => 87,
    "quality_status" => "ok",
    "summary_cost_usd" => 0.000123,
    "summary_input_tokens" => 1200,
    "summary_output_tokens" => 300,
    "summary_cache_read_tokens" => 400
  },
  {
    "url" => article_two,
    "title" => "Second article",
    "summary" => "Second summary.",
    "depth" => "Overview",
    "publisher" => "Fixture Press",
    "topics" => ["Software Engineering"],
    "source" => "Hacker News",
    "external_id" => "7002",
    "discovery_url" => "https://news.ycombinator.com/item?id=7002"
  }
].freeze

repost = {
  "url" => article_one,
  "title" => "Replacement title must not replace the article",
  "summary" => "Replacement summary must not replace the article.",
  "depth" => "Overview",
  "publisher" => "Fixture Press",
  "topics" => ["Software Engineering"],
  "source" => "Hacker News",
  "external_id" => "7003",
  "discovery_url" => "https://news.ycombinator.com/item?id=7003",
  "summary_cost_usd" => 0.99,
  "summary_input_tokens" => 9999,
  "summary_output_tokens" => 9999,
  "summary_cache_read_tokens" => 9999,
  "quality_score" => 12,
  "quality_status" => "ok"
}.freeze

def snapshot(archive, base)
  archive.articles.select { |article| article["url"].to_s.start_with?(base) }
end

archive = Archive.new
archive.prepare

archive.import(first_batch)
first_view = snapshot(archive, base)

archive.import(first_batch)
replay_view = snapshot(archive, base)

check "a replayed import keeps one article per canonical URL" do
  assert(replay_view.length == 2, "expected 2 articles, got #{replay_view.length}")
  assert(replay_view.map { |article| article["url"] }.sort == [article_one, article_two].sort,
    "unexpected article URLs: #{replay_view.map { |article| article["url"] }.inspect}")
end

check "a replayed import does not duplicate discovery links" do
  replay_view.each do |article|
    assert(article["discoveries"].length == 1,
      "#{article["url"]} has #{article["discoveries"].length} discoveries")
    assert(article["sources"].length == 1,
      "#{article["url"]} has #{article["sources"].length} sources")
  end
end

check "a replayed import keeps the original archive timestamp" do
  first_view.each do |article|
    replay = replay_view.find { |candidate| candidate["url"] == article["url"] }
    assert(replay, "article disappeared on replay: #{article["url"]}")
    assert(replay["archive_timestamp"] == article["archive_timestamp"],
      "archive timestamp changed from #{article["archive_timestamp"]} to #{replay["archive_timestamp"]}")
  end
end

archive.import([repost])
final_view = snapshot(archive, base)
first = final_view.find { |article| article["url"] == article_one }
second = final_view.find { |article| article["url"] == article_two }

check "a repost adds a discussion link without adding an article" do
  assert(final_view.length == 2, "expected 2 articles after repost, got #{final_view.length}")
  discovery_urls = first["discoveries"].map { |discovery| discovery["url"] }.sort
  assert(discovery_urls == [
    "https://news.ycombinator.com/item?id=7001",
    "https://news.ycombinator.com/item?id=7003"
  ], "unexpected discoveries: #{discovery_urls.inspect}")
  assert(first["sources"].length == 2, "expected two source entries, got #{first["sources"].inspect}")
end

check "a repost preserves the original summary and title" do
  assert(first["summary"] == "Original summary that a replay must keep.",
    "summary changed to #{first["summary"].inspect}")
  assert(first["title"] == "Original title", "title changed to #{first["title"].inspect}")
end

check "a repost never replaces the stored quality score" do
  assert(first["quality_score"] == 87,
    "a repost rescored the article to #{first["quality_score"].inspect}")
  assert(first["quality_status"] == "ok",
    "a repost changed the quality status to #{first["quality_status"].inspect}")
end

check "published and archive dates are reported as distinct fields" do
  assert(first["published_date"] == published_date,
    "published_date was #{first["published_date"].inspect}")
  assert(first["archive_date"].match?(/\A\d{4}-\d{2}-\d{2}\z/),
    "archive_date was #{first["archive_date"].inspect}")
  assert(first["archive_date"] == Time.now.in_time_zone("America/New_York").to_date.iso8601,
    "archive_date #{first["archive_date"]} is not today in New York")
  assert(first["archive_date"] != first["published_date"],
    "published and archive dates should differ")
  assert(Time.iso8601(first["archive_timestamp"]).iso8601 == first["archive_timestamp"],
    "archive_timestamp was #{first["archive_timestamp"].inspect}")
  assert(second["published_date"].nil?, "second article should have no published date")
end

check "an import records the quality score and how it was derived" do
  assert(first["quality_score"] == 87, "quality_score was #{first["quality_score"].inspect}")
  assert(first["quality_status"] == "ok", "quality_status was #{first["quality_status"].inspect}")
end

check "an import records the summary cost, tokens and timestamp" do
  assert((first["summary_cost_usd"] - 0.000123).abs < 1e-12,
    "summary_cost_usd was #{first["summary_cost_usd"].inspect}")
  assert(first["summary_input_tokens"] == 1200, "summary_input_tokens was #{first["summary_input_tokens"].inspect}")
  assert(first["summary_output_tokens"] == 300, "summary_output_tokens was #{first["summary_output_tokens"].inspect}")
  assert(first["summary_cache_read_tokens"] == 400, "summary_cache_read_tokens was #{first["summary_cache_read_tokens"].inspect}")
  assert(!first["summarized_at"].to_s.empty?, "summarized_at was #{first["summarized_at"].inspect}")
  assert(Time.iso8601(first["summarized_at"]), "summarized_at is not an ISO 8601 timestamp")
end

check "a replayed import never changes the stored summary cost" do
  replay = replay_view.find { |article| article["url"] == article_one }
  assert(replay, "the priced article disappeared on replay")
  assert(replay["summary_cost_usd"] == first["summary_cost_usd"],
    "replayed cost changed to #{replay["summary_cost_usd"].inspect}")
  assert(replay["summary_input_tokens"] == 1200,
    "replayed input tokens changed to #{replay["summary_input_tokens"].inspect}")
  assert(replay["summary_output_tokens"] == 300,
    "replayed output tokens changed to #{replay["summary_output_tokens"].inspect}")
  assert(replay["summary_cache_read_tokens"] == 400,
    "replayed cache-read tokens changed to #{replay["summary_cache_read_tokens"].inspect}")
  assert(replay["summarized_at"] == first["summarized_at"],
    "replayed summarized_at changed from #{first["summarized_at"]} to #{replay["summarized_at"]}")
end

check "an article imported without cost fields reads as null, not zero" do
  assert(second["summary_cost_usd"].nil?,
    "legacy summary_cost_usd should be null, got #{second["summary_cost_usd"].inspect}")
  assert(second["summary_input_tokens"].nil?, "legacy summary_input_tokens was #{second["summary_input_tokens"].inspect}")
  assert(second["summary_output_tokens"].nil?, "legacy summary_output_tokens was #{second["summary_output_tokens"].inspect}")
  assert(second["summary_cache_read_tokens"].nil?,
    "legacy summary_cache_read_tokens was #{second["summary_cache_read_tokens"].inspect}")
end

check "an article imported without a score reads as null, not zero" do
  assert(second["quality_score"].nil?, "legacy quality_score should be null, got #{second["quality_score"].inspect}")
  assert(second["quality_status"].nil?, "legacy quality_status should be null, got #{second["quality_status"].inspect}")
end

if $failures.empty?
  puts "#{$checks} checks passed against #{ENV.fetch("NEO4J_HTTP_URL")}"
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
