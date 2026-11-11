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
    "published_date" => published_date
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
  "discovery_url" => "https://news.ycombinator.com/item?id=7003"
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

if $failures.empty?
  puts "#{$checks} checks passed against #{ENV.fetch("NEO4J_HTTP_URL")}"
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
