require "nokogiri"
require "time"
require "uri"

require_relative "article_extractor"
require_relative "http_client"
require_relative "url_key"

# Reads one RSS 2.0 or Atom feed and returns article candidates.
#
# Candidates carry the same keys HackerNewsClient emits (title, url, source,
# external_id, discovery_url, submitted_at, score) so the rest of ingestion never
# has to know which kind of source produced a story. The registry name is
# injected, exactly as it is for the Hacker News adapter: the adapter labels its
# candidates with the allowlist entry that named it and never invents a source of
# its own.
class RssClient
  # Raised when the feed cannot be read or is not a well-formed RSS/Atom
  # document. IngestBatch records it as an adapter failure, so one broken feed
  # costs its own items and never the whole run.
  class FeedError < StandardError; end

  ACCEPT = "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1".freeze

  # RSS 2.0 is <rss>, RSS 1.0 is <rdf:RDF>, Atom is <feed>.
  ROOTS = %w[rss rdf feed].freeze

  # Feed links are attacker-controlled like any other input; the same ceiling
  # SafeFetcher applies to article URLs keeps a pathological link out of the
  # archive.
  MAX_URL = 2_048

  attr_reader :name, :feed_url, :last_error

  def initialize(name:, feed_url:, http: HttpClient.new, extractor: ArticleExtractor.new,
    now: -> { Time.now.utc })
    @name = name.to_s
    @feed_url = feed_url.to_s
    @http = http
    @extractor = extractor
    @now = now
    @last_error = nil
  end

  # Candidates from this feed, in the order the feed lists them (newest first
  # for the feeds this app reads). An item without a usable title or URL is
  # skipped, an item already archived is skipped, and a repeated guid inside one
  # feed yields one candidate rather than two.
  #
  # `feed` is accepted for adapter parity with HackerNewsClient, which needs a
  # feed name; an RSS source is one feed, so it is ignored here.
  def collect_candidates(feed: nil, limit:, archive_rows: [])
    unless limit.is_a?(Integer) && limit.positive?
      raise ArgumentError, "limit must be a positive integer"
    end

    @last_error = nil
    known_urls, known_external_ids = archive_keys(archive_rows)
    document = parse(@http.get_text(feed_url, accept: ACCEPT))
    candidates = []
    seen_urls = []
    seen_external_ids = []

    feed_items(document).each do |item|
      break if candidates.length >= limit

      candidate = candidate_for(item)
      next unless candidate

      key = UrlKey.call(candidate["url"])
      next unless key

      external_id = candidate["external_id"]
      next if known_urls.include?(key) || known_external_ids.include?(external_id)
      next if seen_urls.include?(key) || seen_external_ids.include?(external_id)

      seen_urls << key
      seen_external_ids << external_id
      candidates << candidate
    end

    candidates
  end

  # Archived URL keys plus the external ids this source already contributed, so
  # a repeated poll is skipped before the article is fetched instead of deduped
  # afterwards by the archive. The second slot is the archive's `discoveries`
  # contract, which HackerNewsClient fills with discussion ids.
  def archive_keys(rows)
    known_urls = []
    known_external_ids = []
    Array(rows).each do |article|
      next unless article.is_a?(Hash)

      key = UrlKey.call(article["url"])
      known_urls << key if key
      Array(article["discoveries"]).each do |discovery|
        next unless discovery.is_a?(Hash) && discovery["source"] == name

        external_id = discovery["external_id"].to_s
        known_external_ids << external_id unless external_id.strip.empty?
      end
    end
    [known_urls, known_external_ids]
  end

  private

  def parse(body)
    text = body.to_s
    raise FeedError, "#{feed_url} returned an empty feed" if text.strip.empty?

    document = Nokogiri::XML(text) { |config| config.strict.nonet }
    root = document.root ? document.root.name.to_s.downcase : ""
    unless ROOTS.include?(root)
      raise FeedError, "#{feed_url} returned #{root.empty? ? "no document" : root.inspect}, " \
        "not an RSS or Atom feed"
    end

    document
  rescue Nokogiri::XML::SyntaxError => error
    detail = error.message.to_s.lines.first.to_s.strip
    raise FeedError, "#{feed_url} is not well-formed XML (#{detail})"
  end

  def feed_items(document)
    items = document.xpath("//*[local-name()='item']")
    items = document.xpath("//*[local-name()='entry']") if items.empty?
    items
  end

  def candidate_for(item)
    title = @extractor.sanitize_title(text(item, "title"))
    url = absolute_url(link_for(item))
    return nil if title.empty? || url.nil?

    {
      "title" => title,
      "url" => url,
      "source" => name,
      "external_id" => external_id_for(item, url),
      "discovery_url" => feed_url,
      "submitted_at" => submitted_at(item),
      # RSS carries no score; the key stays in the candidate so every adapter
      # produces the same shape.
      "score" => nil
    }
  end

  # RSS 2.0 keeps the URL in the <link> text, Atom in the href of a rel=alternate
  # <link>. A feed that only marks the guid as a permalink still yields a usable
  # URL, and a feed with neither is skipped by the caller.
  def link_for(item)
    value = text(item, "link")
    return value unless value.empty?

    links = item.xpath("./*[local-name()='link'][@href]")
    node = links.find { |link| link["rel"].to_s.empty? || link["rel"].to_s == "alternate" } || links.first
    return node["href"].to_s unless node.nil?

    guid = @extractor.decode_entities(text(item, "guid")).strip
    guid.match?(%r{\Ahttps?://}i) ? guid : ""
  end

  # An item without a guid is identified by its normalized article URL, which is
  # stable across polls because it is the same key the archive dedupes on. Atom
  # carries the identifier in <id> instead of <guid>.
  def external_id_for(item, url)
    guid = @extractor.decode_entities(text(item, "guid")).strip
    guid = @extractor.decode_entities(text(item, "id")).strip if guid.empty?
    return guid unless guid.empty?

    UrlKey.call(url) || url
  end

  def submitted_at(item)
    raw = %w[pubDate published updated date].map { |name| text(item, name) }
      .find { |value| !value.empty? }
    (parse_time(raw) || @now.call).utc.iso8601
  end

  def parse_time(value)
    return nil if value.to_s.strip.empty?

    Time.rfc2822(value)
  rescue ArgumentError
    begin
      Time.iso8601(value)
    rescue ArgumentError
      nil
    end
  end

  # Resolves an absolute, root-relative or path-relative link against the feed
  # URL. Only public http(s) URLs without credentials survive.
  def absolute_url(value)
    text = @extractor.decode_entities(value.to_s).strip
    return nil if text.empty?

    uri = parse_url(text) || parse_url(text.gsub(" ", "%20"))
    return nil unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil?
    return nil if uri.to_s.length > MAX_URL

    uri.to_s
  end

  def parse_url(value)
    uri = URI.parse(value)
    uri = URI.join(feed_url, uri.to_s) if uri.relative?
    uri
  rescue URI::InvalidURIError
    nil
  end

  def text(item, name)
    node = item.xpath("./*[local-name()='#{name}']").first
    node.nil? ? "" : node.text.to_s.strip
  end
end
