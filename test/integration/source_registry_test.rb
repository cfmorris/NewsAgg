require "tmpdir"
require "yaml"

require_relative "../../config/environment"
require_relative "../support/assertions"

# Writes throwaway allowlist files and reports the refusal message, so every
# check exercises the loader the same way boot does.
module SourceConfig
  module_function

  def entry(**overrides)
    {
      "name" => "Example Feed",
      "kind" => "rss",
      "url" => "https://example.com/feed.xml",
      "enabled" => true,
      "max_items" => 5,
      "min_words" => 10,
      "domains" => ["*.example.com"],
      "exclude_domains" => [],
      "owner" => nil
    }.merge(overrides.transform_keys(&:to_s))
  end

  def write(directory, sources, name: "sources.yml")
    path = File.join(directory, name)
    File.write(path, YAML.dump("sources" => sources))
    path
  end

  def write_raw(directory, text, name: "sources.yml")
    path = File.join(directory, name)
    File.write(path, text)
    path
  end

  def failure(path)
    SourceRegistry.load(path: path)
    nil
  rescue SourceRegistry::ConfigError => error
    error.message
  end
end

TestReport.run do
  Dir.mktmpdir("newsagg-sources-") do |directory|
    boot_registry = SourceRegistry.current

    check "the committed allowlist loads at boot and is exposed to the application" do
      assert(boot_registry.is_a?(SourceRegistry), "boot did not load a registry")
      assert(boot_registry.path.end_with?(File.join("config", "sources.yml")),
        "boot loaded #{boot_registry.path.inspect}")
      assert(Rails.application.config.x.source_registry.equal?(boot_registry),
        "the boot registry is not exposed on Rails.application.config.x")
    end

    check "the registry holds exactly the explicitly listed shared sources" do
      assert(boot_registry.names == ["Hacker News", "Lobsters"],
        "expected only the explicitly listed sources, got #{boot_registry.names.inspect}")
      assert(boot_registry.enabled_names == boot_registry.names,
        "enabled sources were #{boot_registry.enabled_names.inspect}")
    end

    check "the Hacker News entry carries a validated kind, url, limits, domain rules and a null owner" do
      source = boot_registry.fetch("Hacker News")
      assert(source.api?, "expected kind api, got #{source.kind.inspect}")
      assert(source.enabled?, "the only listed source is disabled")
      assert(source.url.start_with?("https://"), "unexpected url #{source.url.inspect}")
      assert(source.max_items.is_a?(Integer) && source.max_items.positive?,
        "max_items was #{source.max_items.inspect}")
      assert(source.min_words.is_a?(Integer) && source.min_words >= 0,
        "min_words was #{source.min_words.inspect}")
      assert(source.domains.is_a?(Array) && source.exclude_domains.is_a?(Array),
        "domain rules were not lists")
      assert(source.owner.nil?, "owner must stay nullable for shared sources, got #{source.owner.inspect}")
    end

    check "a custom allowlist contains only the entries it lists, and nothing else" do
      path = SourceConfig.write(directory, [
        SourceConfig.entry(name: "Feed A"),
        SourceConfig.entry(name: "Feed B", url: "https://b.example/rss", enabled: false)
      ])
      registry = SourceRegistry.load(path: path)

      assert(registry.names == ["Feed A", "Feed B"], "registry names were #{registry.names.inspect}")
      assert(registry.enabled_names == ["Feed A"], "enabled sources were #{registry.enabled_names.inspect}")
      assert(!registry.include?("Hacker News"), "an implicit Hacker News source appeared")
      assert(registry.fetch("Feed A").owner.nil?, "owner should default to null")

    check "each source carries a stable slug id, explicit or derived from its name" do
      assert(boot_registry.fetch("Hacker News").id == "hacker-news",
        "the committed source id was #{boot_registry.fetch("Hacker News").id.inspect}")
      assert(boot_registry.fetch("hacker-news").name == "Hacker News",
        "looking a source up by id returned #{boot_registry.fetch("hacker-news").name.inspect}")

      path = SourceConfig.write(directory, [
        SourceConfig.entry(name: "Feed One"),
        SourceConfig.entry(id: "wire-two", name: "Feed Two", url: "https://two.example/rss")
      ])
      registry = SourceRegistry.load(path: path)
      assert(registry.fetch("Feed One").id == "feed-one",
        "a derived id was #{registry.fetch("Feed One").id.inspect}")
      assert(registry.fetch("Feed Two").id == "wire-two",
        "an explicit id was #{registry.fetch("Feed Two").id.inspect}")
      assert(registry.to_h["sources"].map { |entry| entry["id"] } == %w[feed-one wire-two],
        "to_h ids were #{registry.to_h["sources"].map { |entry| entry["id"] }.inspect}")
    end

    check "a malformed or duplicate source id refuses to load" do
      message = SourceConfig.failure(SourceConfig.write(directory, [SourceConfig.entry(id: "Not A Slug")]))
      assert(message&.include?("sources[0]") && message.include?("id must be lowercase"),
        "unclear refusal: #{message.inspect}")

      duplicate = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(id: "same-id"),
        SourceConfig.entry(name: "Other Feed", url: "https://other.example/rss", id: "same-id")
      ]))
      assert(duplicate&.include?("sources[1]") && duplicate.include?("duplicate source id"),
        "unclear refusal: #{duplicate.inspect}")

      derived = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(name: "A B"),
        SourceConfig.entry(name: "A-B", url: "https://dash.example/rss")
      ]))
      assert(derived&.include?("duplicate source id"),
        "two names slugging to one id loaded: #{derived.inspect}")
    end
    end

    check "an empty allowlist loads as an empty registry with no implicit default" do
      registry = SourceRegistry.load(path: SourceConfig.write(directory, []))
      assert(registry.empty?, "expected an empty registry, got #{registry.names.inspect}")
      assert(registry.enabled.empty?, "an empty allowlist produced enabled sources")
      assert(!registry.include?("Hacker News"), "an implicit Hacker News source appeared")
    end

    check "domain rules allow listed hosts, allow wildcard subdomains, and let exclusions win" do
      path = SourceConfig.write(directory, [
        SourceConfig.entry(name: "Scoped Feed", domains: ["*.example.com"],
          exclude_domains: ["blog.example.com"]),
        SourceConfig.entry(name: "Open Feed", url: "https://open.example/rss", domains: [],
          exclude_domains: ["ads.example"])
      ])
      registry = SourceRegistry.load(path: path)
      scoped = registry.fetch("Scoped Feed")
      open = registry.fetch("Open Feed")

      assert(scoped.domain_allowed?("news.example.com"), "a wildcard subdomain was rejected")
      assert(scoped.domain_allowed?("example.com"), "the wildcard base domain was rejected")
      assert(!scoped.domain_allowed?("blog.example.com"), "an excluded host was allowed")
      assert(!scoped.domain_allowed?("example.org"), "an unlisted host was allowed")
      assert(open.domain_allowed?("anything.example"), "an empty allow list became restrictive")
      assert(!open.domain_allowed?("ads.example"), "an excluded host was allowed")
      assert(registry.for_domain("news.example.com").map(&:name) == ["Scoped Feed", "Open Feed"],
        "domain lookup returned #{registry.for_domain("news.example.com").map(&:name).inspect}")
    end

    check "a missing allowlist file refuses to load" do
      message = SourceConfig.failure(File.join(directory, "absent.yml"))
      assert(message, "a missing file loaded silently")
      assert(message.include?("absent.yml") && message.include?("missing"),
        "unclear refusal: #{message.inspect}")
    end

    check "an unknown kind refuses to load and names the entry" do
      path = SourceConfig.write(directory, [
        SourceConfig.entry(name: "Good"),
        SourceConfig.entry(name: "Podcast Feed", kind: "podcast")
      ])
      message = SourceConfig.failure(path)
      assert(message, "an unknown kind loaded")
      assert(message.include?("sources[1]") && message.include?("unknown kind") &&
        message.include?("podcast"), "unclear refusal: #{message.inspect}")
    end

    check "a missing kind refuses to load" do
      entry = SourceConfig.entry
      entry.delete("kind")
      message = SourceConfig.failure(SourceConfig.write(directory, [entry]))
      assert(message&.include?("missing kind"), "unclear refusal: #{message.inspect}")
    end

    check "a missing url refuses to load" do
      entry = SourceConfig.entry
      entry.delete("url")
      message = SourceConfig.failure(SourceConfig.write(directory, [entry]))
      assert(message, "a source without a url loaded")
      assert(message.include?("sources[0]") && message.include?("missing url"),
        "unclear refusal: #{message.inspect}")
    end

    check "a non-http url refuses to load" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(url: "ftp://example.com/feed.xml")
      ]))
      assert(message&.include?("not an absolute http(s) URL"), "unclear refusal: #{message.inspect}")
    end

    check "a duplicate name refuses to load and points at the original" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(name: "Example Feed"),
        SourceConfig.entry(name: "example feed", url: "https://other.example/rss")
      ]))
      assert(message, "a duplicate name loaded")
      assert(message.include?("duplicate source name") && message.include?("sources[0]"),
        "unclear refusal: #{message.inspect}")
    end

    check "a missing name refuses to load" do
      entry = SourceConfig.entry
      entry.delete("name")
      message = SourceConfig.failure(SourceConfig.write(directory, [entry]))
      assert(message&.include?("missing name"), "unclear refusal: #{message.inspect}")
    end

    check "an unknown entry key refuses to load instead of being ignored" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry.merge("enable" => true)
      ]))
      assert(message, "a misspelled key loaded")
      assert(message.include?("unknown key") && message.include?("enable"),
        "unclear refusal: #{message.inspect}")
    end

    check "a non-boolean enabled refuses to load" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(enabled: "yes")
      ]))
      assert(message&.include?("enabled must be true or false"), "unclear refusal: #{message.inspect}")
    end

    check "a non-positive max_items refuses to load" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(max_items: 0)
      ]))
      assert(message&.include?("max_items must be an integer >= 1"), "unclear refusal: #{message.inspect}")
    end

    check "a malformed owner refuses to load while null stays valid" do
      message = SourceConfig.failure(SourceConfig.write(directory, [
        SourceConfig.entry(owner: 42)
      ]))
      assert(message&.include?("owner must be null or a non-empty string"),
        "unclear refusal: #{message.inspect}")

      registry = SourceRegistry.load(path: SourceConfig.write(directory, [
        SourceConfig.entry(name: "Shared", owner: nil),
        SourceConfig.entry(name: "Private", url: "https://private.example/rss", owner: "acct-7")
      ]))
      assert(registry.fetch("Shared").owner.nil?, "a shared source did not keep a null owner")
      assert(registry.fetch("Private").owner == "acct-7", "a per-owner source lost its owner")
    end

    check "a file without a sources list refuses to load" do
      message = SourceConfig.failure(SourceConfig.write_raw(directory, "feed:\n  - name: x\n"))
      assert(message, "a file without sources loaded")
      assert(message.include?("unknown top-level key") && message.include?("feed"),
        "unclear refusal: #{message.inspect}")

      message = SourceConfig.failure(SourceConfig.write_raw(directory, "---\n"))
      assert(message&.include?("expected a mapping with a `sources:` list"),
        "unclear refusal: #{message.inspect}")
    end

    check "invalid YAML refuses to load" do
      message = SourceConfig.failure(SourceConfig.write_raw(directory, "sources:\n  - name: [\n"))
      assert(message, "invalid YAML loaded")
      assert(message.include?("invalid YAML"), "unclear refusal: #{message.inspect}")
    end

    check "load! refuses a bad file without replacing the loaded registry" do
      bad_path = SourceConfig.write(directory, [SourceConfig.entry(kind: "scraper")])
      raised = begin
        SourceRegistry.load!(path: bad_path)
        false
      rescue SourceRegistry::ConfigError
        true
      end
      assert(raised, "load! accepted a malformed allowlist")
      assert(SourceRegistry.current.equal?(boot_registry),
        "a failed load! replaced the boot registry")
    end
  end
end
