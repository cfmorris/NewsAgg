require_relative "archive"
require_relative "source_registry"

# Projects the validated config/sources.yml registry onto Neo4j, so the
# allowlist is queryable next to the articles each source produced.
#
# One NewsSource node per registry entry, identified by its stable id, written
# with an idempotent MERGE: importing twice leaves one node per entry and never
# duplicates. Config owns the identity and policy fields (kind, url, enabled,
# owner, limits, domain rules, override flags); the node owns the accumulated
# facts (article_count, cost_usd, quality_score), which are seeded once on
# create and preserved on every later sync.
class SourceMaterializer
  # "override" reports that an entry departs from the documented defaults, and
  # override_keys names which settings do. A registry entry that sets a value
  # equal to the default is not an override.
  DEFAULT_MAX_ITEMS = SourceRegistry::DEFAULT_MAX_ITEMS
  DEFAULT_MIN_WORDS = SourceRegistry::DEFAULT_MIN_WORDS

  def initialize(registry: nil, archive: Archive.new)
    @registry = registry || SourceRegistry.current
    @archive = archive
  end

  # Returns the number of entries materialised.
  def call
    rows = rows_for(@registry)
    @archive.sync_sources(rows) unless rows.empty?
    rows.length
  end

  # The node payload for every entry in the registry, in allowlist order.
  def rows_for(registry = @registry)
    registry.entries.map { |entry| row_for(entry) }
  end

  def row_for(entry)
    keys = override_keys(entry)
    {
      "id" => entry.id,
      "name" => entry.name,
      "kind" => entry.kind,
      "url" => entry.url,
      "enabled" => entry.enabled?,
      "owner" => entry.owner,
      "max_items" => entry.max_items,
      "min_words" => entry.min_words,
      "domains" => entry.domains.dup,
      "exclude_domains" => entry.exclude_domains.dup,
      "override" => !keys.empty?,
      "override_keys" => keys,
      # The explicit registry `override: true`: exempts the source from the
      # automatic pause. Kept apart from the derived `override` above, which
      # reports that a setting departs from its default.
      "pause_override" => entry.override?,
      # No scoring input exists in config; the node keeps whatever score it
      # already has and starts at 0.0 when first created.
      "quality_score" => nil
    }
  end

  def override_keys(entry)
    keys = []
    keys << "enabled" unless entry.enabled?
    keys << "max_items" unless entry.max_items == DEFAULT_MAX_ITEMS
    keys << "min_words" unless entry.min_words == DEFAULT_MIN_WORDS
    keys << "domains" unless entry.domains.empty?
    keys << "exclude_domains" unless entry.exclude_domains.empty?
    keys << "owner" unless entry.owner.nil?
    keys
  end
end
