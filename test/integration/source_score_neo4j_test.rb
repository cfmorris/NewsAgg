ENV["RAILS_ENV"] = "test"

require "json"
require "securerandom"
require "time"
require "tmpdir"
require "uri"

require_relative "../../config/environment"
require_relative "../../app/services/archive"
require_relative "../../app/services/import_records"
require_relative "../../app/services/source_gate"
require_relative "../../app/services/source_materializer"
require_relative "../../app/services/source_registry"
require_relative "../../app/services/source_score"
require_relative "../../app/services/source_scoring"
require_relative "../support/signed_in"

# Proves the source score against a real graph: the decayed average is computed
# from the source's own articles, the fifth low article pauses it (and the
# fourth does not), a registry override keeps a source on, resuming restores
# fetching without losing an article, and cost keeps accumulating independently
# of the score. The admin console is driven through the real HTTP routes, so the
# score and the recorded pause reason are checked as rendered.
#
# Runs against a disposable Neo4j instance only; the guards below refuse to
# touch anything else.
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
$tolerance = 1e-6

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

def assert_close(actual, expected, message)
  raise "#{message}: expected #{expected}, got #{actual.inspect}" unless actual.is_a?(Numeric)
  raise "#{message}: expected #{expected}, got #{actual.inspect}" if (actual - expected).abs > $tolerance
end

def write_config(directory, body)
  path = File.join(directory, "sources-#{SecureRandom.hex(4)}.yml")
  File.write(path, "sources:\n#{body}")
  path
end

def registry_from(directory, body)
  SourceRegistry.load(path: write_config(directory, body))
end

def node_for(archive, id)
  archive.source_nodes.find { |node| node["id"] == id }
end

# The expected decayed average, written out independently of SourceScore.
def expected_average(scores)
  weights = scores.each_index.map { |age| 0.95**age }
  (scores.each_with_index.sum { |score, index| score * weights[index] } / weights.sum).round(2)
end

def record(base, slug, source:, external_id:, score:, cost: 0.0, published: nil)
  row = {
    "url" => "#{base}/#{slug}",
    "title" => "A story about #{slug}",
    "summary" => "A summary long enough to satisfy the importer contract.",
    "depth" => "Overview",
    "publisher" => "Score Fixture Press",
    "topics" => ["Software Engineering"],
    "source" => source,
    "external_id" => external_id,
    "discovery_url" => "https://discussion.example.test/item?id=#{external_id}",
    "quality_score" => score,
    "summary_cost_usd" => cost
  }
  row["published_date"] = published if published
  row
end

# Imports land in the same instant, which would make "newest first" a coin toss.
# This spaces them a minute apart so article N is the newest, matching the order
# the scores are listed in.
def space_out(archive, base, slugs)
  archive.query(<<~CYPHER, { base: base, slugs: slugs })
    UNWIND range(0, size($slugs) - 1) AS index
    MATCH (article:NewsArticle {url: $base + "/" + $slugs[index]})
    SET article.added_at = datetime() - duration({minutes: size($slugs) - index})
  CYPHER
end

def articles_for(archive, name)
  archive.query(<<~CYPHER, { name: name }).first.fetch("articles")
    MATCH (article:NewsArticle)-[:DISCOVERED_VIA]->(discovery:NewsDiscovery)
    WHERE discovery.source = $name
    RETURN count(DISTINCT article) AS articles
  CYPHER
end

# The rendered table row for one source, so an assertion is about that source and
# not about whatever else the shared disposable database happens to hold.
def row_html(body, id)
  body[/<tr id="source-#{Regexp.escape(id)}".*?<\/tr>/m].to_s
end

run = SecureRandom.hex(4)
low_id = "low-#{run}"
pinned_id = "pinned-#{run}"
spare_id = "spare-#{run}"
tie_id = "tie-#{run}"
low = "Low Score Feed #{run}"
pinned = "Pinned Feed #{run}"
spare = "Spare Feed #{run}"
tie = "Tie Break Feed #{run}"
base = "https://score.example.test/#{run}"

archive = Archive.new

Dir.mktmpdir("newsagg-scores-") do |directory|
  registry = registry_from(directory, <<~YAML)
    - id: #{low_id}
      name: #{low}
      kind: rss
      url: https://low.example.test/feed.xml
    - id: #{pinned_id}
      name: #{pinned}
      kind: rss
      url: https://pinned.example.test/feed.xml
      override: true
    - id: #{spare_id}
      name: #{spare}
      kind: rss
      url: https://spare.example.test/feed.xml
    - id: #{tie_id}
      name: #{tie}
      kind: rss
      url: https://tie.example.test/feed.xml
  YAML

  importer = ImportRecords.new(archive: archive, registry: registry)

  # Four articles: not enough to judge the source, so no pause however they score.
  first_four = [10, 20, 30, 40].each_with_index.map do |score, index|
    record(base, "item-#{index + 1}", source: low, external_id: "low-#{index + 1}",
      score: score, cost: 0.001)
  end
  importer.call(first_four)
  space_out(archive, base, ["item-1", "item-2", "item-3", "item-4"])
  SourceScoring.new(archive: archive).call

  check "the score is the decayed average of the source's articles, newest first" do
    node = node_for(archive, low_id)
    expected = expected_average([40, 30, 20, 10])
    assert_close(node["quality_score"], expected,
      "quality_score was #{node["quality_score"].inspect}, expected the decayed average #{expected}")
    assert(node["article_count"] == 4, "article_count was #{node["article_count"].inspect}")
    assert(node["score_updated_at"], "the score was not stamped with a time")
  end

  check "four low articles do not pause the source" do
    node = node_for(archive, low_id)
    assert(node["enabled"] == true, "the source was disabled on four articles")
    assert(node["paused_at"].nil?, "the source was paused on four articles")
    assert(node["pause_reason"].nil?, "a pause reason was recorded without a pause")
  end

  # A whole batch shares one added_at, so only the published date says which
  # piece in it is the later one. The URLs sort the other way, so an average that
  # weighted the wrong article would come out at 51.03 instead of 48.97.
  importer.call([
    record(base, "tie-a", source: tie, external_id: "tie-1", score: 90, published: "2026-11-01"),
    record(base, "tie-b", source: tie, external_id: "tie-2", score: 10, published: "2026-11-10")
  ])
  SourceScoring.new(archive: archive).call

  check "the published date orders the articles a single import brought in" do
    node = node_for(archive, tie_id)
    expected = expected_average([10, 90])
    assert_close(node["quality_score"], expected,
      "quality_score was #{node["quality_score"].inspect}, expected #{expected} " \
      "(the later publication carrying the 1.0 weight)")
    assert(node["article_count"] == 2, "article_count was #{node["article_count"].inspect}")
  end

  # The fifth article drops the decayed average to 31.02: below 40, with the
  # five articles the floor asks for.
  importer.call([record(base, "item-5", source: low, external_id: "low-5", score: 50, cost: 0.001)])
  space_out(archive, base, ["item-1", "item-2", "item-3", "item-4", "item-5"])
  SourceScoring.new(archive: archive).call

  check "the fifth low article pauses the source with a recorded reason" do
    node = node_for(archive, low_id)
    expected = expected_average([50, 40, 30, 20, 10])
    assert_close(node["quality_score"], expected,
      "quality_score was #{node["quality_score"].inspect}, expected #{expected}")
    assert(node["article_count"] == 5, "article_count was #{node["article_count"].inspect}")
    assert(node["enabled"] == false, "the source was not disabled: enabled=#{node["enabled"].inspect}")
    assert(node["paused_at"], "no paused_at was recorded")
    assert(node["paused_by"] == "auto", "paused_by was #{node["paused_by"].inspect}")
    assert(node["pause_reason"] == "auto-paused: quality score 31.0 over 5 articles is below 40",
      "the pause reason was #{node["pause_reason"].inspect}")
  end

  check "pausing deletes nothing: the articles are all still attributed to the source" do
    assert(articles_for(archive, low) == 5, "the source now has #{articles_for(archive, low)} articles")
  end

  check "a config re-sync does not undo the pause" do
    SourceMaterializer.new(registry: registry, archive: archive).call
    node = node_for(archive, low_id)
    assert(node["enabled"] == false, "the re-sync re-enabled a paused source")
    assert(node["configured_enabled"] == true, "configured_enabled was #{node["configured_enabled"].inspect}")
    assert(node["paused_at"], "the re-sync cleared the pause")
  end

  check "the pre-fetch gate refuses a paused source" do
    gate = SourceGate.new(registry: registry, paused: archive.paused_source_ids)
    decision = gate.admit_source(low)
    assert(decision.dropped?, "the gate admitted a paused source")
    assert(decision.reason == SourceGate::PAUSED_SOURCE, "the reason was #{decision.reason.inspect}")
    assert(gate.admit_source(pinned).admitted?, "the gate refused an unpaused source")
  end

  check "a registry override keeps a low-scoring source on" do
    5.times do |index|
      importer.call([record(base, "pinned-#{index + 1}", source: pinned,
        external_id: "pinned-#{index + 1}", score: 10, cost: 0.002)])
    end
    node = node_for(archive, pinned_id)
    assert_close(node["quality_score"], 10.0, "the overridden source scored #{node["quality_score"].inspect}")
    assert(node["article_count"] == 5, "article_count was #{node["article_count"].inspect}")
    assert(node["enabled"] == true, "an override did not keep the source enabled")
    assert(node["paused_at"].nil?, "an overridden source was paused")
  end

  check "a source with no scored articles has no score and is not paused" do
    node = node_for(archive, spare_id)
    assert(node["quality_score"].nil?, "an empty source scored #{node["quality_score"].inspect}")
    assert(node["article_count"] == 0, "an empty source counted #{node["article_count"].inspect}")
    assert(node["enabled"] == true, "an empty source was disabled")
  end

  check "cost keeps accumulating independently of the score" do
    node = node_for(archive, low_id)
    assert_close(node["cost_usd"], 0.005,
      "the paused source's cost was #{node["cost_usd"].inspect}, expected 0.005")

    # A queued retry can still commit an article for a paused source; the cost
    # follows the articles, and the pause is untouched by it.
    importer.call([record(base, "item-6", source: low, external_id: "low-6", score: 50, cost: 0.5)])
    node = node_for(archive, low_id)
    assert_close(node["cost_usd"], 0.505,
      "the cost after a new article was #{node["cost_usd"].inspect}, expected 0.505")
    assert(node["enabled"] == false, "a new article re-enabled the paused source")
    assert(node["pause_reason"], "a new article cleared the pause reason")
  end

  # The console is read through the real route with a real session, so this is
  # what an operator actually sees. The sign-in and every later request share one
  # Rack::Test session on purpose: the flash that reports a resumed or unknown
  # source lives in the session cookie, so a pinned pre-sign-in cookie would
  # never see it.
  operator = User.create!(email: "source-operator-#{run}@example.com",
    password: TEST_ACCOUNT_PASSWORD)
  console = Rack::Test::Session.new(Rails.application)
  console.get("/users/sign_in")
  console.post("/users/sign_in", user: { email: operator.email, password: TEST_ACCOUNT_PASSWORD })
  unless console.last_response.status == 302 &&
      console.last_response["Location"].to_s.end_with?("/dashboard")
    raise "the console sign-in answered #{console.last_response.status} " \
      "#{console.last_response["Location"].inspect}"
  end

  check "the admin console and the source list render the score and the pause reason" do
    node = node_for(archive, low_id)

    console.get("/admin")
    assert(console.last_response.status == 200, "/admin answered #{console.last_response.status}")
    body = console.last_response.body
    assert(body.include?(low), "the console does not list #{low.inspect}")
    assert(body.include?("paused"), "the console does not mark the source as paused")
    assert(body.include?(format("%.1f", node["quality_score"])),
      "the console does not show the score #{format("%.1f", node["quality_score"])}")
    assert(body.include?('href="/admin/sources"'), "the console does not link to the source list")

    console.get("/admin/sources")
    assert(console.last_response.status == 200,
      "/admin/sources answered #{console.last_response.status}")
    body = console.last_response.body
    assert(body.include?(node["pause_reason"]),
      "the source list does not show the pause reason #{node["pause_reason"].inspect}")
    assert(body.include?(format("%.1f", node["quality_score"])),
      "the source list does not show the score")
    assert(body.include?("#{node["article_count"]}"), "the source list does not show the article count")
    assert(body.include?('id="source-' + low_id + '"'), "the paused source has no row")
    paused_row = row_html(body, low_id)
    assert(paused_row.include?("auto-paused"),
      "the paused source's row shows no pause reason: #{paused_row.inspect}")
    assert(paused_row.include?("Resume"), "the paused source offers no way to resume it")
  end

  check "resuming from the admin console restores fetching and keeps every article" do
    console.patch("/admin/sources/#{low_id}/resume", {})
    assert(console.last_response.status == 302,
      "resuming answered #{console.last_response.status}")
    console.follow_redirect!
    assert(console.last_response.status == 200,
      "the resume redirect landed on #{console.last_response.status}")
    assert(console.last_response.body.include?("#{low_id} is fetching again."),
      "the operator was not told the source resumed: " \
      "#{console.last_response.body[0, 400].inspect}")

    node = node_for(archive, low_id)
    assert(node["enabled"] == true, "the source is still disabled after resuming")
    assert(node["paused_at"].nil?, "the pause was not cleared")
    assert(node["pause_reason"].nil?, "the pause reason was not cleared")
    assert(node["article_count"] == 6, "resuming changed the article count to #{node["article_count"].inspect}")
    assert(articles_for(archive, low) == 6, "resuming deleted articles")

    gate = SourceGate.new(registry: registry, paused: archive.paused_source_ids)
    assert(!archive.paused_source_ids.include?(low_id),
      "the resumed source is still in the paused set: #{archive.paused_source_ids.inspect}")
    assert(gate.admit_source(low).admitted?, "the gate still refuses the resumed source")

    console.get("/admin/sources")
    resumed_row = row_html(console.last_response.body, low_id)
    assert(!resumed_row.empty?, "the resumed source has no row")
    assert(!resumed_row.include?("Resume"), "the source list still offers Resume for a running source")
    assert(!resumed_row.include?("auto-paused"), "the source list still shows a pause reason")
  end

  check "resuming an unknown source is refused instead of pretending" do
    console.patch("/admin/sources/no-such-source/resume", {})
    assert(console.last_response.status == 302,
      "an unknown source answered #{console.last_response.status}")
    console.follow_redirect!
    assert(console.last_response.body.include?("No source with id"),
      "the refusal was not reported to the operator")
  end
end

if $failures.empty?
  puts "#{$checks} checks passed"
  exit 0
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
