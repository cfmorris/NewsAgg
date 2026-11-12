require "json"
require "time"
require "securerandom"
require "tmpdir"
require "uri"

require_relative "../../app/services/archive"
require_relative "../../app/services/import_records"
require_relative "../../app/services/source_materializer"
require_relative "../../app/services/source_registry"

# Proves that NewsSource.cost_usd is derived from the articles attributed to
# each source: it equals the sum of their summary_cost_usd values, null and zero
# costs contribute nothing, a replay or a repeated aggregation does not
# double-count, and a source disabled in config keeps the historical cost of the
# articles it already contributed.
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

run = SecureRandom.hex(4)
alpha_id = "alpha-#{run}"
beta_id = "beta-#{run}"
gamma_id = "gamma-#{run}"
delta_id = "delta-#{run}"
alpha = "Alpha Cost Feed #{run}"
beta = "Beta Cost Feed #{run}"
gamma = "Gamma Cost Wire #{run}"
delta = "Delta Cost Feed #{run}"
base = "https://cost.example.test/#{run}"

def record(base, slug, source:, external_id:, cost: nil)
  row = {
    "url" => "#{base}/#{slug}",
    "title" => "A story about #{slug}",
    "summary" => "A summary long enough to satisfy the importer contract.",
    "depth" => "Overview",
    "publisher" => "Cost Fixture Press",
    "topics" => ["Software Engineering"],
    "source" => source,
    "external_id" => external_id,
    "discovery_url" => "https://discussion.example.test/item?id=#{external_id}"
  }
  row["summary_cost_usd"] = cost unless cost.nil?
  row
end

def source_entry(id:, name:, url:, enabled: true)
  <<~YAML
    - id: #{id}
      name: #{name}
      kind: rss
      url: #{url}
      enabled: #{enabled}
  YAML
end

# Costs chosen so a double count is obvious and floating-point drift stays
# inside the tolerance: 0.0001 + 0.25 + 0.0 + 0.0003 + 0.0002 = 0.2506
alpha_expected = 0.2506
beta_expected = 0.5002

records = [
  record(base, "alpha-one", source: alpha, external_id: "1", cost: 0.0001),
  record(base, "alpha-two", source: alpha, external_id: "2", cost: 0.25),
  # A legacy article with no recorded cost at all: the key is absent, so the
  # article is stored with a null summary_cost_usd.
  record(base, "alpha-legacy", source: alpha, external_id: "3"),
  record(base, "alpha-free", source: alpha, external_id: "4", cost: 0.0),
  # The same article discovered twice by the same source must be counted once.
  record(base, "alpha-twice", source: alpha, external_id: "5", cost: 0.0003),
  record(base, "alpha-twice", source: alpha, external_id: "6", cost: 0.0003),
  record(base, "beta-one", source: beta, external_id: "7", cost: 0.5),
  # One article attributed to two sources is attributed to both.
  record(base, "shared", source: alpha, external_id: "8", cost: 0.0002),
  record(base, "shared", source: beta, external_id: "9", cost: 0.0002),
  record(base, "delta-one", source: delta, external_id: "10", cost: 0.125)
]

archive = Archive.new

Dir.mktmpdir("newsagg-costs-") do |directory|
  enabled_delta = source_entry(id: delta_id, name: delta, url: "https://delta.example.test/feed.xml")
  all_enabled = registry_from(directory, [
    source_entry(id: alpha_id, name: alpha, url: "https://alpha.example.test/feed.xml"),
    source_entry(id: beta_id, name: beta, url: "https://beta.example.test/feed.xml"),
    source_entry(id: gamma_id, name: gamma, url: "https://gamma.example.test/feed.xml"),
    enabled_delta
  ].join)

  ImportRecords.new(archive: archive, registry: all_enabled).call(records)
  archive.recompute_source_costs

  check "cost_usd sums the summary_cost_usd of every article attributed to the source" do
    node = node_for(archive, alpha_id)
    assert(node, "alpha source node is missing")
    assert_close(node["cost_usd"], alpha_expected,
      "alpha cost_usd did not match the article costs")
  end

  check "each source gets only its own articles, and an article attributed to two sources counts for both" do
    assert_close(node_for(archive, beta_id)["cost_usd"], beta_expected,
      "beta cost_usd did not match the article costs")
  end

  check "a source with no articles is persisted at 0.0" do
    assert(node_for(archive, gamma_id)["cost_usd"] == 0.0,
      "gamma cost_usd was #{node_for(archive, gamma_id)["cost_usd"].inspect}")
  end

  check "null and zero summary costs leave the total intact" do
    rows = archive.query(<<~CYPHER, { base: base })
      MATCH (article:NewsArticle)
      WHERE article.url IN [$base + "/alpha-legacy", $base + "/alpha-free"]
      RETURN article.url AS url, article.summary_cost_usd AS cost
    CYPHER
    costs = rows.to_h { |row| [row["url"], row["cost"]] }
    assert(costs.length == 2, "expected both articles, got #{costs.keys.inspect}")
    assert(costs.fetch("#{base}/alpha-legacy").nil?,
      "the legacy article should carry a null cost, got #{costs["#{base}/alpha-legacy"].inspect}")
    assert(costs.fetch("#{base}/alpha-free") == 0.0,
      "the free article should carry a 0.0 cost, got #{costs["#{base}/alpha-free"].inspect}")
    assert_close(node_for(archive, alpha_id)["cost_usd"], alpha_expected,
      "a null or zero article cost corrupted the source total")
  end

  check "replaying the same import does not double-count" do
    ImportRecords.new(archive: archive, registry: all_enabled).call(records)
    assert_close(node_for(archive, alpha_id)["cost_usd"], alpha_expected,
      "alpha cost_usd changed on replay")
    assert_close(node_for(archive, beta_id)["cost_usd"], beta_expected,
      "beta cost_usd changed on replay")
  end

  check "repeated aggregation is idempotent" do
    first = archive.recompute_source_costs
    second = archive.recompute_source_costs
    assert(first == second, "the aggregate reported #{first} then #{second} sources")
    assert_close(node_for(archive, alpha_id)["cost_usd"], alpha_expected,
      "a second aggregation changed the total")
  end

  check "cost_usd survives a fresh archive handle, so it is persisted on the node" do
    fresh = Archive.new
    node = node_for(fresh, alpha_id)
    assert_close(node["cost_usd"], alpha_expected,
      "a fresh handle read back #{node["cost_usd"].inspect}")
    raw = fresh.query(<<~CYPHER, { id: alpha_id }).first.fetch("cost")
      MATCH (source:NewsSource {id: $id}) RETURN source.cost_usd AS cost
    CYPHER
    assert_close(raw, alpha_expected, "the raw node property read back #{raw.inspect}")
  end

  check "a source disabled in config keeps the historical cost of its articles" do
    disabled_delta = source_entry(id: delta_id, name: delta, url: "https://delta.example.test/feed.xml", enabled: false)
    reloaded = registry_from(directory, [
      source_entry(id: alpha_id, name: alpha, url: "https://alpha.example.test/feed.xml"),
      source_entry(id: beta_id, name: beta, url: "https://beta.example.test/feed.xml"),
      source_entry(id: gamma_id, name: gamma, url: "https://gamma.example.test/feed.xml"),
      disabled_delta
    ].join)

    ImportRecords.new(archive: archive, registry: reloaded).call(records)
    node = node_for(archive, delta_id)
    assert(node["enabled"] == false, "delta was not disabled, enabled=#{node["enabled"].inspect}")
    assert_close(node["cost_usd"], 0.125,
      "a disabled source lost its historical cost")
  end
end

if $failures.empty?
  puts "#{$checks} checks passed"
  exit 0
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
