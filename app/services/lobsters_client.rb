require "json"
require "time"
require "uri"

require_relative "discovery_keys"
require_relative "http_client"
require_relative "url_key"

# Reads the Lobsters API feed and returns unseen story candidates.
#
# One poll returns the whole front page, so unlike Hacker News there is no
# per-item request and `feed` is advisory only: the allowlist entry's URL is the
# endpoint. The registry name is injected, exactly as for HackerNewsClient, so
# the adapter labels its candidates with the entry that named it and never
# invents a source of its own.
#
# Lobsters self-posts carry no external `url`. They are still candidates: the
# discussion link (`short_id_url`) becomes both the discovery URL and the
# candidate URL, and the candidate is marked `fetch: false` so the ingestion
# batch imports nothing for it instead of fetching a discussion page as if it
# were an article.
class LobstersClient
  FEED_URL = "https://lobste.rs/hottest.json".freeze
  SHORT_ID_PATH = %r{\A/s/([A-Za-z0-9]+)}.freeze

  attr_reader :name, :feed_url

  def initialize(name:, http: HttpClient.new, feed_url: FEED_URL)
    @name = name.to_s
    @http = http
    @feed_url = feed_url.to_s
  end

  def collect_candidates(feed:, limit:, archive_rows:)
    return [] unless limit.is_a?(Integer) && limit.positive?

    items = @http.get_json(feed_url)
    raise ArgumentError, "Expected a Lobsters story array." unless items.is_a?(Array)

    known_urls, known_discussions = archive_keys(archive_rows)
    candidates = []

    items.each do |item|
      break if candidates.length >= limit
      next unless item.is_a?(Hash)

      title = item["title"].to_s.strip
      short_id_url = item["short_id_url"].to_s.strip
      short_id = item["short_id"].to_s.strip
      short_id = short_id_from(short_id_url) if short_id.empty?
      next if title.empty? || short_id_url.empty? || short_id.nil?
      next if known_discussions.include?(short_id)

      # A self-post has no article: point at its discussion and mark it so the
      # batch skips the fetch instead of dropping it silently.
      external_url = item["url"].to_s.strip
      target = external_url.empty? ? short_id_url : external_url
      key = UrlKey.call(target)
      next unless key
      next if known_urls.include?(key)

      known_urls << key
      candidates << {
        "title" => title,
        "url" => target,
        "source" => name,
        "external_id" => short_id,
        "discovery_url" => short_id_url,
        "submitted_at" => submitted_at(item["created_at"]),
        "score" => item["score"],
        "fetch" => !external_url.empty?
      }
    end

    candidates
  end

  # Archive rows already imported from this source, plus every archived article
  # URL. A short id in a discovery link marks the story seen even when its
  # article was later archived under a different canonical URL.
  def archive_keys(rows)
    DiscoveryKeys.call(rows, name) do |discovery|
      next nil unless discovery["url"].is_a?(String)

      short_id_from(discovery["url"])
    end
  end

  def short_id_from(url)
    path = URI.parse(url.to_s).path.to_s
    match = SHORT_ID_PATH.match(path)
    match && match[1]
  rescue URI::InvalidURIError
    nil
  end

  private

  # Lobsters sends an ISO 8601 timestamp with an offset. An item whose
  # timestamp cannot be parsed still counts as a candidate; only its
  # submitted_at is unknown.
  def submitted_at(value)
    Time.iso8601(value.to_s).utc.iso8601
  rescue ArgumentError
    nil
  end
end
