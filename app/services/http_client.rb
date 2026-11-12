require "json"
require "net/http"
require "time"
require "uri"

# Small JSON HTTP client used by the Hacker News and DeepSeek services.
class HttpClient
  # retry_after carries the server's Retry-After seconds when it sent one, so a
  # 429 or 503 can push the breaker past the default cooldown.
  class Error < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  def get_json(url, timeout: 10)
    body = get(url, timeout: timeout)
    JSON.parse(body)
  rescue JSON::ParserError
    raise Error, "#{url} returned invalid JSON"
  end

  # Fetches a non-JSON document such as an RSS feed, with an explicit Accept
  # header. Same timeout and error contract as get_json.
  def get_text(url, accept: "application/xml, text/xml;q=0.9, */*;q=0.1", timeout: 15)
    get(url, timeout: timeout, accept: accept)
  end

  def post_json(url, headers: {}, body:, timeout: 30)
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri.request_uri)
    headers.each { |key, value| request[key] = value }
    request["content-type"] = "application/json"
    request.body = body

    response = start(uri, timeout).start { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise Error.new("#{url} returned HTTP #{response.code}", retry_after: retry_after_seconds(response))
    end
    response.body
  rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => error
    raise Error, error.message
  end

  private

  def get(url, timeout:, accept: "application/json")
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri.request_uri)
    request["accept"] = accept
    response = start(uri, timeout).start { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise Error.new("#{url} returned HTTP #{response.code}", retry_after: retry_after_seconds(response))
    end

    response.body
  rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => error
    raise Error, error.message
  end

  def retry_after_seconds(response)
    value = response["retry-after"].to_s.strip
    return nil if value.empty?
    return value.to_i if value.match?(/\A\d+\z/)

    [(Time.httpdate(value) - Time.now).ceil, 0].max
  rescue ArgumentError
    nil
  end

  def start(uri, timeout)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [timeout, 5].min
    http.read_timeout = timeout
    http
  end
end
