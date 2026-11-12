require "securerandom"
require "uri"

require_relative "../../app/services/archive"
require_relative "../../app/services/import_records"
require_relative "../../app/services/source_materializer"
require_relative "../../app/services/source_registry"

# Acceptance test for the Neo4j half of the source registry:
#
#   * every entry in the fixture allowlist round-trips to exactly one
#     NewsSource node with the configured fields
#   * a disabled entry is materialised as disabled and contributes no articles
#   * each source's cost_usd equals the sum of the summary_cost_usd values of
#     the articles attributed to it
#   * a repeated import neither duplicates nodes nor double-counts cost
#
# It runs against a disposable Neo4j instance only; the guards below refuse to
# touch anything else. The config comes from the committed fixture
# test/fixtures/sources/acceptance.yml.
def refuse(message)
  warn "Refusing to run the disposable-Neo4j acceptance test: #{message}"
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

FIXTURE_DIR = File.expand_path("../fixtures/sources", __dir__)

$checks = 0
$failures = []
$tolerance = 1e-9

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

def node_for(archive, id)
  archive.source_nodes.find { |node| node["id"] == id }
end

# Independently derived from config, so the test does not trust the
# materialiser's own notion of which settings depart from the defaults.
def expected_override_keys(entry)
  keys = []
  keys << "enabled" unless entry.enabled?
  keys << "max_items" unless entry.max_items == SourceRegistry::DEFAULT_MAX_ITEMS
  keys << "min_words" unless entry.min_words == SourceRegistry::DEFAULT_MIN_WORDS
  keys << "domains" unless entry.domains.empty?
  keys << "exclude_domains" unless entry.exclude_domains.empty?
  keys << "owner" unless entry.owner.nil?
  keys
end

def record(base, slug, source:, external_id:, cost: nil)
  row = {
    "url" => "#{base}/#{slug}",
    "title" => "A story about #{slug}",
    "summary" => "A summary long enough to satisfy the importer contract.",
    "depth" => "Overview",
    "publisher" => "Acceptance Fixture Press",
    "topics" => ["Software Engineering"],
    "source" => source,
    "external_id" => external_id,
    "discovery_url" => "https://discussion.acceptance.test/item?id=#{external_id}"
  }
  row["summary_cost_usd"] = cost unless cost.nil?
  row
end

registry = SourceRegistry.load(path: File.join(FIXTURE_DIR, "acceptance.yml"))
archive = Archive.new
ids = registry.entries.map(&:id)
names = registry.entries.map(&:name)
run = SecureRandom.hex(4)
base = "https://alpha.acceptance.test/acceptance-#{run}"

# Deterministic reruns: clear anything a previous acceptance run left under
# these fixture identities, so the cost check sees only this run's articles.
archive.query("MATCH (source:NewsSource) WHERE source.id IN $ids DETACH DELETE source", { ids: ids })
archive.query("MATCH (discovery:NewsDiscovery) WHERE discovery.source IN $names DETACH DELETE discovery", { names: names })

# Costs chosen so a double count is obvious and drift stays inside tolerance.
alpha_one = 0.02
alpha_two = 0.0005
beta_one = 0.01
alpha_expected = alpha_one + alpha_two
beta_expected = beta_one

records = [
  record(base, "alpha-one", source: "Acceptance Alpha", external_id: "acc-#{run}-1", cost: alpha_one),
  record(base, "alpha-two", source: "Acceptance Alpha", external_id: "acc-#{run}-2", cost: alpha_two),
  # A legacy article with no recorded cost at all must contribute nothing.
  record(base, "alpha-legacy", source: "Acceptance Alpha", external_id: "acc-#{run}-3"),
  record("#{base}/beta", "beta-one", source: "Acceptance Beta", external_id: "acc-#{run}-4", cost: beta_one)
]

ImportRecords.new(archive: archive, registry: registry).call(records)

check "every fixture entry round-trips to exactly one NewsSource node" do
  rows = archive.query(<<~CYPHER, { ids: ids })
    MATCH (source:NewsSource) WHERE source.id IN $ids
    RETURN source.id AS id, count(*) AS copies
  CYPHER
  copies = rows.to_h { |row| [row["id"], row["copies"]] }
  assert(copies.length == 3, "expected three fixture nodes, got #{copies.inspect}")
  assert(copies.values.all?(1), "a source node was duplicated: #{copies.inspect}")
end

check "the node fields match the registry entry for every source" do
  registry.entries.each do |entry|
    node = node_for(archive, entry.id)
    assert(node, "no NewsSource node for #{entry.id}")
    assert(node["name"] == entry.name, "#{entry.id} name was #{node["name"].inspect}")
    assert(node["kind"] == entry.kind, "#{entry.id} kind was #{node["kind"].inspect}")
    assert(node["url"] == entry.url, "#{entry.id} url was #{node["url"].inspect}")
    assert(node["enabled"] == entry.enabled?, "#{entry.id} enabled was #{node["enabled"].inspect}")
    assert(node["max_items"] == entry.max_items, "#{entry.id} max_items was #{node["max_items"].inspect}")
    assert(node["min_words"] == entry.min_words, "#{entry.id} min_words was #{node["min_words"].inspect}")
    assert(Array(node["domains"]) == entry.domains, "#{entry.id} domains were #{node["domains"].inspect}")
    assert(node["owner"].nil?, "#{entry.id} owner was #{node["owner"].inspect}")
    assert(node["override"] == !expected_override_keys(entry).empty?,
      "#{entry.id} override was #{node["override"].inspect}")
    assert(Array(node["override_keys"]) == expected_override_keys(entry),
      "#{entry.id} override_keys were #{node["override_keys"].inspect}")
  end
end

check "the disabled fixture entry is materialised as disabled and contributed no articles" do
  node = node_for(archive, "acceptance-dormant")
  assert(node, "the disabled entry was not materialised")
  assert(node["enabled"] == false, "the disabled entry reads enabled=#{node["enabled"].inspect}")

  rows = archive.query(<<~CYPHER, { name: "Acceptance Dormant" })
    MATCH (article:NewsArticle)-[:DISCOVERED_VIA]->(discovery:NewsDiscovery)
    WHERE discovery.source = $name
    RETURN count(DISTINCT article) AS articles
  CYPHER
  assert(rows.first.fetch("articles").zero?,
    "the disabled source contributed #{rows.first["articles"]} article(s)")
end

check "cost_usd equals the sum of the source's article summary_cost_usd values" do
  rows = archive.query(<<~CYPHER, { ids: ids })
    MATCH (source:NewsSource) WHERE source.id IN $ids
    OPTIONAL MATCH (article:NewsArticle)-[:DISCOVERED_VIA]->(discovery:NewsDiscovery)
    WHERE discovery.source = source.name
    WITH source, article, min(coalesce(article.summary_cost_usd, 0.0)) AS article_cost
    RETURN source.id AS id, source.cost_usd AS stored, sum(article_cost) AS summed,
           count(article) AS articles
  CYPHER
  totals = rows.to_h { |row| [row["id"], row] }

  assert_close(totals.fetch("acceptance-alpha").fetch("summed"), alpha_expected,
    "the alpha articles do not sum to the expected cost")
  assert_close(totals.fetch("acceptance-alpha").fetch("stored"), alpha_expected,
    "alpha cost_usd did not match the article sum")
  assert_close(totals.fetch("acceptance-beta").fetch("stored"), beta_expected,
    "beta cost_usd did not match the article sum")
  assert_close(totals.fetch("acceptance-dormant").fetch("stored"), 0.0,
    "a source with no articles should read 0.0")

  totals.each do |id, row|
    assert_close(row.fetch("stored"), row.fetch("summed"),
      "#{id} stored cost does not equal the recomputed sum")
  end
end

check "a repeated import neither duplicates nodes nor double-counts cost" do
  ImportRecords.new(archive: archive, registry: registry).call(records)

  rows = archive.query(<<~CYPHER, { ids: ids })
    MATCH (source:NewsSource) WHERE source.id IN $ids
    RETURN count(*) AS nodes
  CYPHER
  assert(rows.first.fetch("nodes") == 3, "a replay left #{rows.first["nodes"]} fixture nodes")
  assert_close(node_for(archive, "acceptance-alpha")["cost_usd"], alpha_expected,
    "a replay changed the alpha cost")
  assert_close(node_for(archive, "acceptance-beta")["cost_usd"], beta_expected,
    "a replay changed the beta cost")
end

if $failures.empty?
  puts "#{$checks} checks passed"
  exit 0
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
