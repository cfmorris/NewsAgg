require "json"
require "uri"

require_relative "discovery_keys"
require_relative "http_client"
require_relative "url_key"

# Reads one Hacker News API feed and returns unseen story candidates.
#
# The registry name is injected: the adapter labels its candidates with the
# allowlist entry that named it and never invents a source of its own.
class HackerNewsClient
  API = "https://hacker-news.firebaseio.com/v0".freeze
  FEEDS = %w[new top best].freeze
  CONCURRENCY = 12

  attr_reader :name, :api

  def initialize(name:, http: HttpClient.new, api: API)
    @name = name.to_s
    @http = http
    @api = api
  end

  def collect_candidates(feed:, limit:, archive_rows:)
    raise ArgumentError, "Use --feed new|top|best and --limit 1-500." unless
      FEEDS.include?(feed.to_s) && limit.is_a?(Integer) && limit.between?(1, 500)

    ids = @http.get_json("#{@api}/#{feed}stories.json")
    raise ArgumentError, "Expected Hacker News ID arrays." unless ids.is_a?(Array)

    known_urls, known_discussions = archive_keys(archive_rows)
    unseen = ids.uniq.select { |id| id.is_a?(Integer) && !known_discussions.include?(id.to_s) }
    stories = []

    unseen.each_slice(CONCURRENCY) do |slice|
      break if stories.length >= limit

      slice.each do |id|
        break if stories.length >= limit

        item = begin
          @http.get_json("#{@api}/item/#{id}.json")
        rescue HttpClient::Error
          nil
        end
        next unless item.is_a?(Hash)
        next unless item["type"] == "story" && !item["dead"] && !item["deleted"] && item["title"]

        discovery_url = "https://news.ycombinator.com/item?id=#{item["id"]}"
        key = UrlKey.call(item["url"] || discovery_url)
        next unless key
        next if known_urls.include?(key)

        known_urls << key
        stories << {
          "title" => item["title"],
          "url" => item["url"] || discovery_url,
          "source" => name,
          "external_id" => item["id"].to_s,
          "discovery_url" => discovery_url,
          "submitted_at" => Time.at(item["time"].to_i).utc.iso8601,
          "score" => item["score"]
        }
      end
    end

    stories
  end

  def archive_keys(rows)
    DiscoveryKeys.call(rows, name) do |discovery|
      next nil unless discovery["url"].is_a?(String)

      begin
        URI.decode_www_form(URI.parse(discovery["url"]).query.to_s).to_h["id"]
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
