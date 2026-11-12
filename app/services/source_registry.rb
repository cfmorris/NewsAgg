require "yaml"
require "uri"

# Loads config/sources.yml, the single explicit allowlist of ingest sources.
#
# Loading validates every entry and raises SourceRegistry::ConfigError with the
# file path, the offending entry index, and the reason. There is deliberately no
# default source and no discovery fallback here: an empty file yields an empty
# registry rather than any built-in feed, and a missing or malformed file refuses
# to load at all, so a bad config stops boot instead of silently ingesting from
# something nobody listed.
class SourceRegistry
  class Error < StandardError; end

  # Raised for a missing file, invalid YAML, or an entry that fails validation.
  class ConfigError < Error; end

  # Raised when a caller asks for a name that is not in the allowlist.
  class UnknownSource < KeyError; end

  KINDS = %w[rss api].freeze
  DEFAULT_MAX_ITEMS = 25
  DEFAULT_MIN_WORDS = 0
  TOP_LEVEL_KEYS = %w[sources].freeze
  ENTRY_KEYS = %w[
    id name kind url enabled max_items min_words domains exclude_domains owner override
  ].freeze
  ID_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
  DEFAULT_PATH = File.expand_path("../../config/sources.yml", __dir__)

  # One validated allowlist entry.
  class Source
    attr_reader :id, :name, :kind, :url, :max_items, :min_words, :domains, :exclude_domains, :owner

    def initialize(id:, name:, kind:, url:, enabled:, max_items:, min_words:,
      domains: [], exclude_domains: [], owner: nil, override: false)
      @id = id
      @name = name
      @kind = kind
      @url = url
      @enabled = enabled
      @max_items = max_items
      @min_words = min_words
      @domains = Array(domains).freeze
      @exclude_domains = Array(exclude_domains).freeze
      @owner = owner
      @override = override == true
      freeze
    end

    def enabled?
      @enabled
    end

    # True when the entry says `override: true`: the source is exempt from the
    # automatic pause that a low quality score would otherwise trigger. It is
    # not the same thing as the node's `override`/`override_keys` fields, which
    # report that a setting departs from its default.
    def override?
      @override
    end

    def rss?
      kind == "rss"
    end

    def api?
      kind == "api"
    end

    # True when a candidate host from this source is allowed by the entry's
    # domain rules. Exclusions always win; an empty allow list imposes no host
    # restriction by itself.
    def domain_allowed?(host)
      value = Source.normalize_host(host)
      return false unless value
      return false if exclude_domains.any? { |pattern| Source.domain_match?(pattern, value) }
      return true if domains.empty?

      domains.any? { |pattern| Source.domain_match?(pattern, value) }
    end

    def to_h
      {
        "id" => id,
        "name" => name, "kind" => kind, "url" => url, "enabled" => enabled?,
        "max_items" => max_items, "min_words" => min_words,
        "domains" => domains.dup, "exclude_domains" => exclude_domains.dup,
        "owner" => owner, "override" => override?
      }
    end

    def inspect
      "#<SourceRegistry::Source #{id.inspect} name=#{name.inspect} kind=#{kind.inspect} enabled=#{enabled?}>"
    end

    # "Hacker News" -> "hacker-news". Returns nil when nothing identifier-shaped
    # survives, which is the loader's cue to demand an explicit id.
    def self.slug(text)
      value = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      value.empty? ? nil : value
    end

    def self.normalize_host(host)
      text = host.to_s.strip.downcase.sub(/\.\z/, "")
      return nil if text.empty?
      return nil if text.match?(%r{[\s/:@?#\[\]]})

      text
    end

    # "*.example.com" covers example.com and every subdomain of it; any other
    # pattern matches exactly one host.
    def self.domain_match?(pattern, host)
      if pattern.start_with?("*.")
        base = pattern.delete_prefix("*.")
        host == base || host.end_with?(".#{base}")
      else
        host == pattern
      end
    end
  end

  attr_reader :path, :entries, :enabled_entries

  def initialize(path:, entries:)
    @path = path
    @entries = entries.freeze
    @enabled_entries = entries.select(&:enabled?).freeze
    freeze
  end

  # Loads and validates the allowlist. Raises ConfigError, never falls back.
  def self.load(path: DEFAULT_PATH)
    Loader.new(path: path).call
  end

  # Loads the allowlist and remembers it as the process registry.
  def self.load!(path: default_path)
    @current = load(path: path)
  end

  def self.current
    @current || raise(Error, "The source registry has not been loaded; run SourceRegistry.load! at boot")
  end

  def self.default_path
    ENV.fetch("NEWSAGG_SOURCES_PATH", DEFAULT_PATH)
  end

  # Only entries that may contribute candidates.
  def enabled
    enabled_entries
  end

  def names
    entries.map(&:name)
  end

  def enabled_names
    enabled_entries.map(&:name)
  end

  def empty?
    entries.empty?
  end

  def find(name)
    wanted = name.to_s.strip
    entries.find { |entry| entry.name == wanted } ||
      entries.find { |entry| entry.name.downcase == wanted.downcase } ||
      entries.find { |entry| entry.id == wanted }
  end

  def fetch(name)
    find(name) || raise(UnknownSource,
      "#{display_path}: no source named #{name.inspect} (known sources: #{names.join(", ")})")
  end

  def include?(name)
    !find(name).nil?
  end

  # Enabled sources whose domain rules accept the host, in allowlist order.
  def for_domain(host)
    enabled_entries.select { |entry| entry.domain_allowed?(host) }
  end

  def display_path
    path.to_s
  end

  def to_h
    { "path" => display_path, "sources" => entries.map(&:to_h) }
  end

  def inspect
    "#<SourceRegistry #{display_path} sources=#{names.inspect}>"
  end

  # Parses and validates one YAML document. Kept separate from the registry so
  # validation reads as a checklist of everything that can refuse to load.
  class Loader
    def initialize(path:)
      @path = path.to_s
    end

    def call
      document = parse(read)
      entries = entries_from(document)
      SourceRegistry.new(path: @path, entries: entries)
    end

    private

    def read
      raise ConfigError, "#{@path}: source allowlist file is missing" unless File.file?(@path)

      File.read(@path, encoding: "UTF-8")
    end

    def parse(text)
      YAML.safe_load(text, permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError => error
      raise ConfigError, "#{@path}: invalid YAML (#{error.message})"
    end

    def entries_from(document)
      raise ConfigError, "#{@path}: expected a mapping with a `sources:` list" unless document.is_a?(Hash)
      unknown = document.keys.map(&:to_s) - TOP_LEVEL_KEYS
      unless unknown.empty?
        raise ConfigError, "#{@path}: unknown top-level key(s) #{unknown.sort.join(", ")}"
      end
      raise ConfigError, "#{@path}: missing `sources:` list" unless document.key?("sources")

      list = document["sources"]
      raise ConfigError, "#{@path}: `sources:` must be a list" unless list.is_a?(Array)

      seen = {}
      ids = {}
      list.each_with_index.map do |entry, index|
        source_from(entry, index, seen, ids)
      end
    end

    def source_from(entry, index, seen, ids)
      fail_at(index, "expected a mapping of source keys") unless entry.is_a?(Hash)
      unknown = entry.keys.map(&:to_s) - ENTRY_KEYS
      unless unknown.empty?
        fail_at(index, "unknown key(s) #{unknown.sort.join(", ")} " \
          "(allowed: #{ENTRY_KEYS.join(", ")})")
      end

      name = validated_name(entry, index)
      fail_at(index, "duplicate source name #{name.inspect} (also defined at sources[#{seen[name.downcase]}]); " \
        "names must be unique") if seen.key?(name.downcase)
      seen[name.downcase] = index

      Source.new(
        id: validated_id(entry, index, name, ids),
        name: name,
        kind: validated_kind(entry, index),
        url: validated_url(entry, index),
        enabled: validated_enabled(entry, index),
        max_items: validated_count(entry, index, "max_items", DEFAULT_MAX_ITEMS, minimum: 1),
        min_words: validated_count(entry, index, "min_words", DEFAULT_MIN_WORDS, minimum: 0),
        domains: validated_domains(entry, index, "domains"),
        exclude_domains: validated_domains(entry, index, "exclude_domains"),
        owner: validated_owner(entry, index),
        override: validated_boolean(entry, index, "override", false)
      )
    end

    # The node identity: an explicit `id` when given, otherwise the slugified
    # name. Either way it must be slug-shaped and unique across the allowlist,
    # because two sources sharing an id would share (and overwrite) one node.
    def validated_id(entry, index, name, ids)
      explicit = entry["id"]
      if explicit.nil?
        derived = Source.slug(name)
        unless derived
          fail_at(index, "cannot derive an id from name #{name.inspect}; " \
            "set an explicit id (lowercase letters, digits and hyphens)")
        end

        return register_id(derived, index, ids)
      end

      unless explicit.is_a?(String) && explicit.match?(ID_PATTERN)
        fail_at(index, "id must be lowercase letters, digits and single hyphens " \
          "(got #{describe(explicit)})")
      end

      register_id(explicit, index, ids)
    end

    def register_id(value, index, ids)
      if ids.key?(value)
        fail_at(index, "duplicate source id #{value.inspect} (also defined at sources[#{ids[value]}]); " \
          "ids must be unique")
      end

      ids[value] = index
      value
    end

    def validated_name(entry, index)
      value = entry["name"]
      fail_at(index, "missing name") if value.nil?
      unless value.is_a?(String) && !value.strip.empty?
        fail_at(index, "name must be a non-empty string (got #{describe(value)})")
      end

      value.strip
    end

    def validated_kind(entry, index)
      value = entry["kind"]
      fail_at(index, "missing kind (expected #{KINDS.map(&:inspect).join(" or ")})") if value.nil?
      unless KINDS.include?(value)
        fail_at(index, "unknown kind #{describe(value)} (expected #{KINDS.map(&:inspect).join(" or ")})")
      end

      value
    end

    def validated_url(entry, index)
      value = entry["url"]
      fail_at(index, "missing url") if value.nil? || (value.is_a?(String) && value.strip.empty?)
      fail_at(index, "url must be a string (got #{describe(value)})") unless value.is_a?(String)

      text = value.strip
      uri = begin
        URI.parse(text)
      rescue URI::InvalidURIError
        nil
      end
      unless uri && %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
        fail_at(index, "url #{text.inspect} is not an absolute http(s) URL")
      end

      text
    end

    def validated_enabled(entry, index)
      validated_boolean(entry, index, "enabled", true)
    end

    # A true/false switch with a documented default. `enabled` and `override`
    # share this validator so both refuse anything that is not a boolean.
    def validated_boolean(entry, index, key, default)
      return default unless entry.key?(key)

      value = entry[key]
      return value if [true, false].include?(value)

      fail_at(index, "#{key} must be true or false (got #{describe(value)})")
    end

    def validated_count(entry, index, key, default, minimum:)
      return default unless entry.key?(key)

      value = entry[key]
      unless value.is_a?(Integer) && value >= minimum
        fail_at(index, "#{key} must be an integer >= #{minimum} (got #{describe(value)})")
      end

      value
    end

    def validated_domains(entry, index, key)
      return [] unless entry.key?(key)

      list = entry[key]
      return [] if list.nil?
      fail_at(index, "#{key} must be a list of host names (got #{describe(list)})") unless list.is_a?(Array)

      list.map { |pattern| validated_domain(pattern, index, key) }.uniq
    end

    def validated_domain(pattern, index, key)
      unless pattern.is_a?(String)
        fail_at(index, "#{key} entries must be host names (got #{describe(pattern)})")
      end

      normalized = Source.normalize_host(pattern)
      label = %r{\A(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z}
      unless normalized && normalized.match?(label)
        fail_at(index, "#{key} entry #{pattern.inspect} is not a host name " \
          "(use \"example.com\" or \"*.example.com\")")
      end

      normalized
    end

    def validated_owner(entry, index)
      return nil unless entry.key?("owner")

      value = entry["owner"]
      return nil if value.nil?
      unless value.is_a?(String) && !value.strip.empty?
        fail_at(index, "owner must be null or a non-empty string (got #{describe(value)})")
      end

      value.strip
    end

    def describe(value)
      value.is_a?(String) ? value.inspect : "#{value.inspect} (#{value.class})"
    end

    def fail_at(index, message)
      raise ConfigError, "#{@path}: sources[#{index}]: #{message}"
    end
  end
end
