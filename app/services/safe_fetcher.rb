require "ipaddr"
require "net/http"
require "resolv"
require "uri"

require_relative "url_key"

# Fetches public article pages with SSRF, redirect, size and time bounds.
class SafeFetcher
  class FetchError < StandardError; end

  LIMITS = {
    timeout: 10,
    lookup_timeout: 5,
    max_redirects: 5,
    max_body_bytes: 2 * 1024 * 1024
  }.freeze

  USER_AGENT = "NewsAgg-ingestion/1.0".freeze
  REDIRECT_CODES = [301, 302, 303, 307, 308].freeze
  HTML_TYPE = %r{\A(?:text/html|application/xhtml\+xml)\b}i

  PRIVATE_V4 = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
  ].map { |range| IPAddr.new(range) }.freeze

  PRIVATE_V6 = %w[
    ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001::/32
    2001:2::/48 2001:db8::/32 2002::/16 3fff::/10 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  def initialize(resolver: nil, now: -> { Time.now })
    @resolve = resolver || method(:resolve_public_address)
    @now = now
  end

  def fetch(value, timeout: LIMITS[:timeout], max_redirects: LIMITS[:max_redirects],
    max_body_bytes: LIMITS[:max_body_bytes])
    deadline = @now.call.to_f + timeout
    current = assert_public_url(value)

    (max_redirects + 1).times do |redirects|
      result = request_once(current, deadline, max_body_bytes)
      return { url: current.to_s, body: result[:body], content_type: result[:content_type] } unless result[:redirect]

      raise FetchError, "Article redirected too many times" if redirects == max_redirects

      next_url = begin
        assert_public_url(URI.join(current.to_s, result[:redirect]).to_s)
      rescue URI::InvalidURIError
        raise FetchError, "Article redirected to an invalid URL"
      end
      if current.scheme == "https" && next_url.scheme == "http"
        raise FetchError, "Refusing an HTTPS to HTTP redirect"
      end
      current = next_url
    end

    raise FetchError, "Article redirected too many times"
  end

  def assert_public_url(value)
    uri = begin
      URI.parse(value.to_s)
    rescue URI::InvalidURIError
      raise FetchError, "Article URL is not valid"
    end
    unless uri.is_a?(URI::HTTP)
      raise FetchError, "Only public HTTP(S) article URLs are allowed"
    end
    raise FetchError, "Article URLs must not contain credentials" if uri.userinfo
    raise FetchError, "Article URL has no host" if uri.hostname.to_s.empty?
    raise FetchError, "Article URL is too long" if uri.to_s.length > 2_048

    host = bare_hostname(uri.hostname)
    if ip_address?(host)
      raise FetchError, "Article URL points to a private destination" if private_address?(host)
      return uri
    end
    if host.casecmp?("localhost") || host.downcase.end_with?(".localhost", ".local", ".internal") ||
        host.casecmp?("home.arpa") || host.downcase.end_with?(".home.arpa")
      raise FetchError, "Article URL points to a private destination"
    end
    uri
  end

  def private_address?(address)
    ip = IPAddr.new(address)
    if ip.ipv4?
      PRIVATE_V4.any? { |range| range.include?(ip) }
    else
      PRIVATE_V6.any? { |range| range.include?(ip) } ||
        !IPAddr.new("2000::/3").include?(ip)
    end
  rescue IPAddr::InvalidAddressError
    true
  end

  def ip_address?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  private

  def bare_hostname(hostname)
    hostname.to_s.start_with?("[") && hostname.to_s.end_with?("]") ?
      hostname.to_s[1..-2] : hostname.to_s
  end

  def resolve_public_address(host)
    return [host, host.include?(":") ? 6 : 4] if ip_address?(host)

    addresses = resolve_all(host)
    raise FetchError, "Could not resolve article host" if addresses.empty?

    # A mixed public/private answer is hostile: DNS tricks must not reach a
    # private network after the initial check.
    if addresses.any? { |address| private_address?(address) }
      raise FetchError, "Article host resolves to a private destination"
    end
    address = addresses.first
    [address, address.include?(":") ? 6 : 4]
  rescue Resolv::ResolvError, SocketError
    raise FetchError, "Could not resolve article host"
  end

  def resolve_all(host)
    Resolv::DNS.open do |dns|
      records = dns.getaddresses(host)
      records.map(&:to_s)
    end
  end

  def request_once(uri, deadline, max_body_bytes)
    remaining = deadline - @now.call.to_f
    raise FetchError, "Timed out fetching article" if remaining <= 0

    address, _family = @resolve.call(uri.hostname)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.ipaddr = address
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [remaining, LIMITS[:lookup_timeout]].min
    http.read_timeout = remaining
    http.write_timeout = remaining

    request = Net::HTTP::Get.new(uri.request_uri)
    request["user-agent"] = USER_AGENT
    request["accept"] = "text/html,application/xhtml+xml,text/plain;q=0.8"
    request["accept-language"] = "en;q=0.9"
    request["accept-encoding"] = "identity"

    result = nil
    http.start do |connection|
      connection.request(request) do |response|
        status = response.code.to_i
        location = response["location"]
        result = { redirect: location } and next if REDIRECT_CODES.include?(status) && location
        raise FetchError, "Article returned HTTP #{status}" unless status == 200

        content_type = response["content-type"].to_s
        declared = response["content-length"].to_i
        raise FetchError, "Article body is too large" if declared > max_body_bytes
        unless content_type.empty? || content_type.match?(HTML_TYPE) || content_type.match?(%r{\Atext/plain\b}i)
          raise FetchError, "Article is not an HTML or text document"
        end

        body = +""
        response.read_body do |chunk|
          body << chunk
          raise FetchError, "Article body is too large" if body.bytesize > max_body_bytes
        end
        result = { body: body, content_type: content_type }
      end
    end
    result || raise(FetchError, "Article download failed")
  rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => error
    raise FetchError, "Article request failed (#{error.class})"
  end
end
