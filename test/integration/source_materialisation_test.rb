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
# node per entry, identified by the entry id, that re-importing is idempotent,
# that a disabled entry lands with enabled=false, and that accumulated counts
# and costs survive a re-sync.
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

def registry_from(directory, body)
  SourceRegistry.load(path: write_config(directory, body))
end

def nodes_for(archive, ids)
  archive.source_nodes.select { |node| ids.include?(node["id"]) }
end

run = SecureRandom.hex(4)
alpha_id = "alpha-#{run}"
beta_id = "beta-feed-#{run}"
gamma_id = "gamma-#{run}"
alpha = "Alpha Feed #{run}"
beta = "Beta Feed #{run}"
gamma = "Gamma Wire #{run}"

archive = Archive.new

Dir.mktmpdir("newsagg-sources-") do |directory|
  alpha_entry = <<~YAML
    - id: #{alpha_id}
      name: #{alpha}
      kind: rss
      url: https://alpha.example.test/feed.xml
      max_items: 5
      domains: ["*.example.test"]
      owner: team-alpha
  YAML
  # No explicit id: the loader derives the slug from the name.
  beta_entry = <<~YAML
    - name: #{beta}
      kind: api
      url: https://beta.example.test/v1
      enabled: false
  YAML
  gamma_entry = <<~YAML
    - id: #{gamma_id}
      name: #{gamma}
      kind: api
      url: https://gamma.example.test/v0
  YAML

  ids = [alpha_id, beta_id, gamma_id]
  registry = registry_from(directory, alpha_entry + beta_entry + gamma_entry)

  # The import path prepares constraints before writing; do the same here so the
  # unique id index backs the merge.
  archive.prepare

  check "the registry materialises one node per entry, keyed by the stable id" do
    materialised = SourceMaterializer.new(registry: registry, archive: archive).call
    assert(materialised == 3, "expected 3 entries materialised, got #{materialised}")
    nodes = nodes_for(archive, ids)
    assert(nodes.length == 3, "expected 3 NewsSource nodes, got #{nodes.map { |n| n["id"] }.inspect}")
    assert(nodes.map { |node| node["id"] }.sort == ids.sort,
      "node ids #{nodes.map { |node| node["id"] }.inspect} did not round-trip #{ids.inspect}")
    assert(nodes.map { |node| node["name"] }.sort == [alpha, beta, gamma].sort,
      "node names were #{nodes.map { |node| node["name"] }.inspect}")
  end

  check "an entry without an explicit id falls back to the slugified name" do
    node = nodes_for(archive, [beta_id]).first
    assert(node, "no node for derived id #{beta_id.inspect}")
    assert(node["id"] == beta_id, "derived id was #{node["id"].inspect}")
    assert(node["name"] == beta, "display name was #{node["name"].inspect}")
  end

  check "a node carries the config identity and policy fields" do
    node = nodes_for(archive, [alpha_id]).first
    assert(node, "no node for #{alpha_id.inspect}")
    assert(node["kind"] == "rss", "kind was #{node["kind"].inspect}")
    assert(node["url"] == "https://alpha.example.test/feed.xml", "url was #{node["url"].inspect}")
    assert(node["enabled"] == true, "enabled was #{node["enabled"].inspect}")
    assert(node["max_items"] == 5, "max_items was #{node["max_items"].inspect}")
    assert(node["domains"] == ["*.example.test"], "domains were #{node["domains"].inspect}")
    assert(node["owner"] == "team-alpha", "owner was #{node["owner"].inspect}")
  end

  check "a node carries quality_score, article_count and cost_usd from creation" do
    node = nodes_for(archive, [gamma_id]).first
    assert(node, "no node for #{gamma_id.inspect}")
    assert(node["quality_score"] == 0.0, "quality_score was #{node["quality_score"].inspect}")
    assert(node["article_count"] == 0, "article_count was #{node["article_count"].inspect}")
    assert(node["cost_usd"] == 0.0, "cost_usd was #{node["cost_usd"].inspect}")
  end

  check "override flags report entries that depart from the defaults" do
    overridden = nodes_for(archive, [alpha_id]).first
    plain = nodes_for(archive, [gamma_id]).first
    assert(overridden["override"] == true, "alpha override was #{overridden["override"].inspect}")
    assert(overridden["override_keys"].sort == %w[domains max_items owner],
      "alpha override_keys were #{overridden["override_keys"].inspect}")
    assert(plain["override"] == false, "gamma override was #{plain["override"].inspect}")
    assert(Array(plain["override_keys"]).empty?,
      "gamma override_keys were #{plain["override_keys"].inspect}")
    assert(plain["owner"].nil?, "a null owner must not be written, got #{plain["owner"].inspect}")
  end

  check "a disabled entry is stored with enabled=false" do
    node = nodes_for(archive, [beta_id]).first
    assert(node, "no node for #{beta_id.inspect}")
    assert(node["enabled"] == false, "enabled was #{node["enabled"].inspect}")
    assert(node["override_keys"].include?("enabled"),
      "disabling should be reported as an override, keys were #{node["override_keys"].inspect}")
  end

  check "importing twice stays idempotent" do
    2.times { SourceMaterializer.new(registry: registry, archive: archive).call }
    nodes = nodes_for(archive, ids)
    assert(nodes.length == 3, "expected 3 nodes after re-imports, got #{nodes.length}")
    counts = nodes.group_by { |node| node["id"] }.transform_values(&:length)
    counts.each do |id, count|
      assert(count == 1, "#{id.inspect} has #{count} nodes")
    end
  end

  check "the id constraint backing the merge exists" do
    found = archive.query(<<~CYPHER)
      SHOW CONSTRAINTS
      YIELD name, labelsOrTypes
      WHERE name = 'news_source_id'
      RETURN collect(name) AS names
    CYPHER
    assert(found.first["names"] == ["news_source_id"],
      "expected the news_source_id constraint, got #{found.first["names"].inspect}")
  end

  check "renaming the display name keeps the same node" do
    renamed = <<~YAML
      - id: #{gamma_id}
        name: #{gamma} (renamed)
        kind: api
        url: https://gamma.example.test/v0
    YAML
    SourceMaterializer.new(registry: registry_from(directory, renamed), archive: archive).call

    node = nodes_for(archive, [gamma_id]).first
    assert(node, "the node disappeared when the name changed")
    assert(node["name"] == "#{gamma} (renamed)", "display name was #{node["name"].inspect}")
    assert(nodes_for(archive, ids).count { |entry| entry["id"] == gamma_id } == 1,
      "the rename produced a second node")
  end

  check "a bare re-sync by the materialiser leaves accumulated values alone" do
    archive.query(<<~CYPHER, { id: alpha_id, count: 7, cost: 0.42, score: 0.75 })
      MATCH (source:NewsSource {id: $id})
      SET source.article_count = $count, source.cost_usd = $cost, source.quality_score = $score
    CYPHER

    disabled_alpha = <<~YAML
      - id: #{alpha_id}
        name: #{alpha}
        kind: rss
        url: https://alpha.example.test/feed.xml
        max_items: 5
        domains: ["*.example.test"]
        owner: team-alpha
        enabled: false
    YAML
    reloaded = registry_from(directory, disabled_alpha + beta_entry + gamma_entry)
    SourceMaterializer.new(registry: reloaded, archive: archive).call

    node = nodes_for(archive, [alpha_id]).first
    assert(node["article_count"] == 7, "article_count was reset to #{node["article_count"].inspect}")
    assert(node["cost_usd"] == 0.42, "cost_usd was reset to #{node["cost_usd"].inspect}")
    assert(node["quality_score"] == 0.75, "quality_score was reset to #{node["quality_score"].inspect}")
    assert(node["enabled"] == false, "enabled did not follow config, was #{node["enabled"].inspect}")
  end

  check "an import materialises the registry and recomputes derived cost" do
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

    nodes = nodes_for(archive, ids)
    assert(nodes.length == 3, "expected 3 nodes after imports, got #{nodes.length}")
    assert(nodes.count { |node| node["id"] == gamma_id } == 1, "gamma was duplicated by the import")
    alpha_node = nodes.find { |node| node["id"] == alpha_id }
    assert(alpha_node["article_count"] == 7, "alpha article_count was reset by the import")
    # cost_usd is derived from the articles now: alpha contributed none, so the
    # import recomputes it to 0.0 instead of keeping the seeded 0.42.
    assert(alpha_node["cost_usd"] == 0.0,
      "alpha derived cost_usd was #{alpha_node["cost_usd"].inspect}, expected 0.0")
    gamma_node = nodes.find { |node| node["id"] == gamma_id }
    assert(gamma_node["cost_usd"] == 0.0,
      "gamma cost_usd was #{gamma_node["cost_usd"].inspect}, expected 0.0 for a costless record")
  end
end

if $failures.empty?
  puts "#{$checks} checks passed"
  exit 0
else
  warn "#{$failures.length} of #{$checks} checks failed"
  exit 1
end
