require "date"
require "uri"

require_relative "archive"
require_relative "source_materializer"

# Validates importer-contract records and writes them to the Neo4j archive.
class ImportRecords
  REQUIRED = %w[url title summary depth publisher source external_id].freeze

  def initialize(archive: Archive.new, registry: nil, materializer: nil)
    @archive = archive
    @registry = registry
    @materializer = materializer
  end

  def call(records)
    raise ArgumentError, "Expected an array of article records" unless records.is_a?(Array)

    records.each_with_index do |record, index|
      validate!(record, index)
    end

    @archive.prepare
    materialize_sources
    @archive.seed_taxonomy
    mappings = records.flat_map { |record| Array(record["fast_mappings"]) }
    unless mappings.all? { |entry| valid_mapping?(entry) }
      raise ArgumentError, "Invalid FAST mapping"
    end
    @archive.map_fast_subjects(mappings) unless mappings.empty?
    records.each_slice(100) { |batch| @archive.import(batch) }
    # Per-source cost is derived from the articles, so it is recomputed (not
    # incremented) once the batch is written. A replay recomputes the same
    # total, which is what keeps repeated imports from double-counting.
    @archive.recompute_source_costs
    records.length
  end

  private

  # The allowlist is materialised on every import, before any article is
  # written, so each contributing source always has exactly one node.
  def materialize_sources
    materializer = @materializer ||
      SourceMaterializer.new(archive: @archive, registry: @registry)
    materializer.call
  end

  def validate!(record, index)
    valid = record.is_a?(Hash) &&
      REQUIRED.all? { |key| record[key].is_a?(String) && !record[key].strip.empty? } &&
      record["topics"].is_a?(Array) &&
      record["topics"].all? { |topic| topic.is_a?(String) && !topic.strip.empty? }
    raise ArgumentError, "Invalid article record at index #{index}" unless valid

    published_date = record["published_date"]
    if published_date && !valid_date?(published_date)
      raise ArgumentError, "Invalid published_date at index #{index}"
    end

    %w[url discovery_url].each do |key|
      next if key == "discovery_url" && record[key].nil?

      uri = URI.parse(record[key].to_s)
      raise ArgumentError, "Invalid #{key} at index #{index}" unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid #{key} at index #{index}"
    end
  end

  def valid_date?(value)
    return false unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    year, month, day = value.split("-").map(&:to_i)
    Date.valid_date?(year, month, day)
  end

  def valid_mapping?(entry)
    entry.is_a?(Hash) && entry["uri"].is_a?(String) &&
      entry["uri"].match?(%r{\Ahttps?://id\.worldcat\.org/fast/[0-9]+\z}) &&
      %w[topic label].all? { |key| entry[key].is_a?(String) && !entry[key].strip.empty? }
  end
end
