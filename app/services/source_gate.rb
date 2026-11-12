require "uri"

require_relative "source_registry"

# The pre-fetch allowlist gate.
#
# Every candidate must resolve to an enabled entry in the loaded SourceRegistry
# before anything is fetched for it. There is deliberately no inference and no
# fallback: a candidate that does not name a source is dropped rather than
# attributed to the feed that mentioned it, so a registered feed never grants
# blanket trust to the links inside it. A source that is listed but disabled
# stops contributing entirely.
class SourceGate
  # The outcome for one candidate or one source name.
  Decision = Struct.new(:admitted, :source, :reason, keyword_init: true) do
    def admitted?
      admitted == true
    end

    def dropped?
      !admitted?
    end
  end

  # One dropped candidate or source, kept for logging and run results.
  Drop = Struct.new(:source, :url, :reason, keyword_init: true)

  MISSING_SOURCE = :missing_source
  UNREGISTERED_SOURCE = :unregistered_source
  DISABLED_SOURCE = :disabled_source
  MISSING_URL = :missing_url
  DOMAIN_NOT_ALLOWED = :domain_not_allowed

  attr_reader :registry

  def initialize(registry: SourceRegistry.current)
    @registry = registry
  end

  # Admits a candidate hash carrying "source" (the registry name it claims) and
  # "url". Nothing is fetched here: a dropped decision is final.
  def admit(candidate)
    return decision(false, nil, MISSING_SOURCE) unless candidate.is_a?(Hash)

    resolved = admit_source(attribute(candidate, "source"))
    return resolved if resolved.dropped?

    url = attribute(candidate, "url").to_s.strip
    return decision(false, resolved.source, MISSING_URL) if url.empty?

    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end
    unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil?
      return decision(false, resolved.source, MISSING_URL)
    end

    unless resolved.source.domain_allowed?(uri.host)
      return decision(false, resolved.source, DOMAIN_NOT_ALLOWED)
    end

    resolved
  end

  # Admits a source name from the allowlist, used before a source is polled.
  def admit_source(name)
    text = name.to_s.strip
    return decision(false, nil, MISSING_SOURCE) if text.empty?

    source = registry.find(text)
    return decision(false, nil, UNREGISTERED_SOURCE) unless source
    return decision(false, source, DISABLED_SOURCE) unless source.enabled?

    decision(true, source, nil)
  end

  # The registry spelling of a source name, or nil when it is not admitted.
  def admitted_name(name)
    resolved = admit_source(name)
    resolved.admitted? ? resolved.source.name : nil
  end

  private

  def decision(admitted, source, reason)
    Decision.new(admitted: admitted, source: source, reason: reason)
  end

  def attribute(candidate, key)
    candidate.key?(key) ? candidate[key] : candidate[key.to_sym]
  end

  # Collects every drop so a run can log each candidate it refused and report
  # the reasons in one place instead of silently shrinking the batch.
  class Report
    attr_reader :drops

    def initialize
      @drops = []
    end

    def add(source:, url:, reason:)
      @drops << Drop.new(source: source.nil? ? nil : source.to_s, url: url.nil? ? nil : url.to_s,
        reason: reason)
      self
    end

    def size
      drops.length
    end
    alias length size

    def empty?
      drops.empty?
    end

    def counts
      drops.each_with_object(Hash.new(0)) { |drop, totals| totals[drop.reason] += 1 }
    end

    # One line per refusal, safe to write to stderr: source names and candidate
    # URLs only, never page content or secrets.
    def lines
      drops.map do |drop|
        "source gate: dropped candidate source=#{drop.source.inspect} reason=#{drop.reason} " \
          "url=#{drop.url.inspect}"
      end
    end

    def summary
      return "source gate: no candidates dropped" if empty?

      counted = counts.map { |reason, total| "#{reason}: #{total}" }.join(", ")
      "source gate: #{size} drop(s) (#{counted})"
    end

    def to_h
      { "dropped" => size, "reasons" => counts.transform_keys(&:to_s) }
    end
  end
end
