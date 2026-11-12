require "json"
require "time"
require "securerandom"
require "tmpdir"
require "uri"

require_relative "../../app/services/archive"
require_relative "../../app/services/import_records"
require_relative "../../app/services/source_materializer"
require_relative "../../app/services/source_registry"

# Proves that the validated allowlist is materialised as exactly one NewsSource
# node per entry, that re-importing is idempotent, that a disabled entry lands
# with enabled=false, and that accumulated counts and costs survive a re-sync.
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

def write_config(directory, body)
  path = File.join(directory, "sources-#{SecureRandom.hex(4)}.yml")
  File.write(path, "sources:\n#{body}")
  path
end

run = SecureRandom.hex(4)
alpha = "Alpha Feed #{run}"
beta = "Beta Feed #{run}"
gamma = "Gamma Wire #{run}"

def registry_from(directory, body)
  SourceRegistry.load(path: write_config(directory, body))
end

def nodes_named(archive, names)
  archive.source_nodes.select { |node| names.include?(node["name"]) }
end

archive = Archive.new

Dir.mktmpdir("newsagg-sources-") do |directory|
  alpha_entry = <<~YAML
    - name: #{alpha}
      kind: rss
      url: https://alpha.example.test/feed.xml
      max_items: 5
      domains: ["*.example.test"]
      owner: team-alpha
  YAML
  beta_entry = <<~YAML
    - name: #{beta}
      kind: api
      url: https://beta.example.test/v1
      enabled: false
  YAML
  gamma_entry = <<~YAML
    - name: #{gamma}
      kind: api
      url: https://gamma.example.test/v0
  YAML

  names = [alpha, beta, gamma]
  registry = registry_from(directory, alpha_entry + beta_entry + gamma_entry)

  # The import path prepares constraints before writing; do the same here so the
  # unique name index backs the merge.
  archive.prepare

  check "the registry materialises one node per entry" do
    materialised = SourceMaterializer.new(registry: registry, archive: archive).call
    assert(materialised == 3, "expected 3 entries materialised, got #{materialised}")
    nodes = nodes_named(archive, names)
    assert(nodes.length == 3, "expected 3 NewsSource nodes, got #{nodes.map { |n| n["name"] }.inspect}")
    assert(nodes.map { |node| node["name"] }.sort == names.sort,
      "node names #{nodes.map { |node| node["name"] }.inspect} did not round-trip #{names.inspect}")
  end

  check "a node carries the config identity and policy fields" do
    node = nodes_named(archive, [alpha]).first
    assert(node, "no node for #{alpha.inspect}")
    assert(node["kind"] == "rss", "kind was #{node["kind"].inspect}")
    assert(node["url"] == "https://alpha.example.test/feed.xml", "url was #{node["url"].inspect}")
    assert(node["enabled"] == true, "enabled was #{node["enabled"].inspect}")
    assert(node["max_items"] == 5, "max_items was #{node["max_items"].inspect}")
    assert(node["domains"] == ["*.example.test"], "domains were #{node["domains"].inspect}")
    assert(node["owner"] == "team-alpha", "owner was #{node["owner"].inspect}")
  end

  check "a node carries quality_score, article_count and cost_usd from creation" do
    node = nodes_named(archive, [gamma]).first
    assert(node, "no node for #{gamma.inspect}")
    assert(node["quality_score"] == 0.0, "quality_score was #{node["quality_score"].inspect}")
    assert(node["article_count"] == 0, "article_count was #{node["article_count"].inspect}")
    assert(node["cost_usd"] == 0.0, "cost_usd was #{node["cost_usd"].inspect}")
  end

  check "override flags report entries that depart from the defaults" do
    overridden = nodes_named(archive, [alpha]).first
    plain = nodes_named(archive, [gamma]).first
    assert(overridden["override"] == true, "alpha override was #{overridden["override"].inspect}")
    assert(overridden["override_keys"].sort == %w[domains max_items owner],
      "alpha override_keys were #{overridden["override_keys"].inspect}")
    assert(plain["override"] == false, "gamma override was #{plain["override"].inspect}")
    assert(Array(plain["override_keys"]).empty?,
      "gamma override_keys were #{plain["override_keys"].inspect}")
    assert(plain["owner"].nil?, "a null owner must not be written, got #{plain["owner"].inspect}")
  end

  check "a disabled entry is stored with enabled=false" do
    node = nodes_named(archive, [beta]).first
    assert(node, "no node for #{beta.inspect}")
    assert(node["enabled"] == false, "enabled was #{node["enabled"].inspect}")
    assert(node["override_keys"].include?("enabled"),
      "disabling should be reported as an override, keys were #{node["override_keys"].inspect}")
  end

  check "importing twice stays idempotent" do
    2.times { SourceMaterializer.new(registry: registry, archive: archive).call }
    nodes = nodes_named(archive, names)
    assert(nodes.length == 3, "expected 3 nodes after re-imports, got #{nodes.length}")
    counts = nodes.group_by { |node| node["name"] }.transform_values(&:length)
    counts.each do |name, count|
      assert(count == 1, "#{name.inspect} has #{count} nodes")
    end
  end

  check "the name constraint backing the merge exists" do
    found = archive.query(<<~CYPHER)
      SHOW CONSTRAINTS
      YIELD name, labelsOrTypes
      WHERE name = 'news_source_name'
      RETURN collect(name) AS names
    CYPHER
    assert(found.first["names"] == ["news_source_name"],
      "expected the news_source_name constraint, got #{found.first["names"].inspect}")
  end

  check "a re-import preserves existing article_count, cost_usd and quality_score" do
    archive.query(<<~CYPHER, { name: alpha, count: 7, cost: 0.42, score: 0.75 })
      MATCH (source:NewsSource {name: $name})
      SET source.article_count = $count, source.cost_usd = $cost, source.quality_score = $score
    CYPHER

    disabled_alpha = <<~YAML
      - name: #{alpha}
        kind: rss
        url: https://alpha.example.test/feed.xml
        max_items: 5
        domains: ["*.example.test"]
        owner: team-alpha
        enabled: false
    YAML
    reloaded = registry_from(directory, disabled_alpha + beta_entry + gamma_entry)
    SourceMaterializer.new(registry: reloaded, archive: archive).call

    node = nodes_named(archive, [alpha]).first
    assert(node["article_count"] == 7, "article_count was reset to #{node["article_count"].inspect}")
    assert(node["cost_usd"] == 0.42, "cost_usd was reset to #{node["cost_usd"].inspect}")
    assert(node["quality_score"] == 0.75, "quality_score was reset to #{node["quality_score"].inspect}")
    assert(node["enabled"] == false, "enabled did not follow config, was #{node["enabled"].inspect}")
  end

  check "an import materialises the registry and keeps accumulated values" do
    record = {
      "url" => "https://gamma.example.test/story-#{run}",
      "title" => "A story from the gamma wire",
      "summary" => "A summary long enough to be imported by the contract.",
      "depth" => "Overview",
      "publisher" => "Gamma Wire",
      "topics" => ["Software Engineering"],
      "source" => gamma,
      "external_id" => "9001",
      "discovery_url" => "https://discussion.example.test/item?id=9001"
    }

    2.times do
      imported = ImportRecords.new(archive: archive, registry: registry).call([record])
      assert(imported == 1, "expected one imported record, got #{imported}")
    end

    nodes = nodes_named(archive, names)
    assert(nodes.length == 3, "expected 3 nodes after imports, got #{nodes.length}")
    assert(nodes.count { |node| node["name"] == gamma } == 1, "gamma was duplicated by the import")
    alpha_node = nodes.find { |node| node["name"] == alpha }
    assert(alpha_node["article_count"] == 7, "alpha article_count was reset by the import")
    assert(alpha_node["cost_usd"] == 0.42, "alpha cost_usd was reset by the import")
  end
end

if $failures.empty?
  puts "#{$checks} checks passed"
  exit 0
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
