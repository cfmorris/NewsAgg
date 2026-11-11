require "json"
require "net/http"
require "uri"

# Small JSON HTTP client used by the Hacker News and DeepSeek services.
class HttpClient
  class Error < StandardError; end

  def get_json(url, timeout: 10)
    body = get(url, timeout: timeout)
    JSON.parse(body)
  rescue JSON::ParserError
    raise Error, "#{url} returned invalid JSON"
  end

  def post_json(url, headers: {}, body:, timeout: 30)
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri.request_uri)
    headers.each { |key, value| request[key] = value }
    request["content-type"] = "application/json"
    request.body = body

    response = start(uri, timeout).start { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{url} returned HTTP #{response.code}"
    end
    response.body
  rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => error
    raise Error, error.message
  end

  private

  def get(url, timeout:)
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri.request_uri)
    request["accept"] = "application/json"
    response = start(uri, timeout).start { |http| http.request(request) }
    raise Error, "#{url} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => error
    raise Error, error.message
  end

  def start(uri, timeout)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [timeout, 5].min
    http.read_timeout = timeout
    http
  end
end
