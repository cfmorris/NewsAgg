require_relative "url_key"

# The archive-key scan shared by the API adapters: every archived article URL,
# plus the discovery ids belonging to one source. Extracting the id is the only
# source-specific step, so the caller passes it as a block.
module DiscoveryKeys
  def self.call(rows, source_name)
    known_urls = []
    known_ids = []
    Array(rows).each do |article|
      key = UrlKey.call(article["url"])
      known_urls << key if key
      Array(article["discoveries"]).each do |discovery|
        next unless discovery.is_a?(Hash) && discovery["source"] == source_name

        id = yield(discovery)
        known_ids << id if id
      end
    end
    [known_urls, known_ids]
  end
end
