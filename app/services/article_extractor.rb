require "json"
require "uri"

# Extracts publisher, text and publication date from public article HTML.
class ArticleExtractor
  MAX_TEXT = 12_000
  MAX_PUBLISHER = 120
  MAX_TITLE = 300

  NAMED_ENTITIES = {
    "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'",
    "nbsp" => " ", "ndash" => "\u2013", "mdash" => "\u2014", "hellip" => "\u2026",
    "lsquo" => "\u2018", "rsquo" => "\u2019", "ldquo" => "\u201C", "rdquo" => "\u201D"
  }.freeze

  UNSAFE_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/

  def decode_entities(value)
    String(value).gsub(/&(?:#(\d+)|#x([0-9a-f]+)|([a-z][a-z0-9]+));/i) do
      decimal = Regexp.last_match(1)
      hexadecimal = Regexp.last_match(2)
      name = Regexp.last_match(3)
      if decimal
        code_point(decimal)
      elsif hexadecimal
        code_point(hexadecimal.to_i(16))
      else
        NAMED_ENTITIES.fetch(name.downcase, Regexp.last_match(0))
      end
    end
  end

  def clean_text(value, limit = MAX_TEXT)
    text = normalize_text(value)
    text = decode_entities(text)
    3.times { text = text.gsub(/<[^>]*>/, " ") if text.include?("<") }
    text = text.gsub(UNSAFE_CHARS, " ").gsub(/[<>]/, " ")
    text = text.gsub(/\s+/, " ").strip
    text.each_char.to_a.first(limit).join.strip
  end

  def sanitize_publisher(value, fallback = "")
    text = clean_text(value, MAX_PUBLISHER).sub(/\A@+/, "").strip
    text.empty? ? fallback : text
  end

  def sanitize_title(value)
    clean_text(value, MAX_TITLE)
  end

  def extract(html, url, content_type: "text/html")
    source = normalize_text(html)
    uri = url.is_a?(URI) ? url : URI.parse(url.to_s)
    fallback_publisher = uri.hostname.to_s.sub(/\Awww\./i, "")

    if content_type.match?(/\Atext\/plain\b/i)
      return {
        final_url: uri.to_s,
        title: "",
        publisher: sanitize_publisher("", fallback_publisher),
        text: clean_text(source),
        published_date: nil
      }
    end

    meta = read_meta(source)
    structured = read_structured_data(source)
    raw_publisher = meta["og:site_name"] || structured["publisher"] ||
      meta["application-name"] || meta["publisher"] ||
      meta["twitter:site"] || structured["author"]
    publisher = sanitize_publisher(raw_publisher, fallback_publisher)

    text = clean_text(html_to_text(source))
    if text.length < 80
      description = meta["og:description"] || meta["description"] || ""
      text = clean_text("#{description} #{text}")
    end

    published = published_date(
      meta["article:published_time"] || meta["datepublished"] ||
      meta["date"] || structured["published"]
    )

    {
      final_url: uri.to_s,
      title: sanitize_title(meta["og:title"] || ""),
      publisher: publisher,
      text: text,
      published_date: published
    }
  end

  private

  # Net::HTTP tags response bodies ASCII-8BIT and pages occasionally carry stray
  # invalid bytes. Everything downstream matches UTF-8 regexps, so convert once
  # here: binary is assumed UTF-8, invalid bytes are replaced (not dropped), and
  # valid UTF-8 passes through untouched.
  def normalize_text(value)
    text = String(value)
    text = text.dup.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
    text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless text.encoding == Encoding::UTF_8
    text.valid_encoding? ? text : text.scrub
  rescue EncodingError, ArgumentError
    text.dup.force_encoding(Encoding::UTF_8).scrub
  end

  def code_point(value)
    number = value.to_i
    return "" unless number.positive? && number <= 0x10ffff
    return "" if number.between?(0xd800, 0xdfff)

    [number].pack("U")
  end

  def parse_attributes(tag)
    attributes = {}
    tag.scan(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/) do
      key = Regexp.last_match(1).downcase
      attributes[key] = Regexp.last_match(2) || Regexp.last_match(3) || Regexp.last_match(4) || ""
    end
    attributes
  end

  def read_meta(html)
    values = {}
    html.scan(/<meta\b[^>]*>/i) do |match|
      attributes = parse_attributes(match)
      key = (attributes["property"] || attributes["name"] || attributes["itemprop"] || "").downcase
      next if key.empty? || attributes["content"].nil?

      values[key] ||= attributes["content"]
    end
    values
  end

  def read_structured_data(html)
    found = { "publisher" => "", "author" => "", "published" => "" }
    html.scan(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/i) do |match|
      data = begin
        JSON.parse(decode_entities(match.first).strip)
      rescue JSON::ParserError
        next
      end
      walk_structured_data(data) do |node|
        types = Array(node["@type"]).compact.map(&:to_s)
        next unless types.any? { |type| type.match?(/article|posting|blog/i) }

        if found["publisher"].empty?
          publisher = node["publisher"]
          found["publisher"] = publisher.is_a?(String) ? publisher :
            (publisher.is_a?(Hash) ? (publisher["name"] || publisher["legalName"] || "") : "")
        end
        if found["author"].empty?
          author = node["author"]
          found["author"] = author.is_a?(String) ? author :
            (author.is_a?(Array) ? (author.first.is_a?(Hash) ? author.first["name"] : "") :
              (author.is_a?(Hash) ? author["name"] : "")) || ""
        end
        if found["published"].empty? && node["datePublished"].is_a?(String)
          found["published"] = node["datePublished"]
        end
      end
    end
    found
  end

  def walk_structured_data(node, &block)
    case node
    when Array
      node.each { |child| walk_structured_data(child, &block) }
    when Hash
      block.call(node)
      node.each_value { |value| walk_structured_data(value, &block) }
    end
  end

  def html_to_text(html)
    preferred = html.match(%r{<(article|main)\b[^>]*>([\s\S]*?)</\1>}i)
    body = preferred ? preferred[2] : html
    body = body.gsub(%r{<(script|style|noscript|template|svg|iframe|object)\b[^>]*>[\s\S]*?</\1>}i, " ")
    body = body.gsub(/<!--[\s\S]*?-->/, " ")
    body = body.gsub(%r{</(p|div|li|h[1-6]|tr|section|article|main|blockquote)>}i, "\n")
    body = body.gsub(/<br\s*\/?>/i, "\n")
    body = body.gsub(/<[^>]*>/, " ")
    decode_entities(body).gsub(/\s+/, " ").strip
  end

  def published_date(value)
    match = /\A(\d{4})-(\d{2})-(\d{2})/.match(String(value).strip)
    return nil unless match

    year, month, day = match.captures.map(&:to_i)
    date = Date.new(year, month, day)
    return nil unless date.year == year && date.month == month && date.day == day

    match[0]
  rescue ArgumentError
    nil
  end
end
