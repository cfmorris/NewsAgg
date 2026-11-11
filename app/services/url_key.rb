require "uri"

# Normalizes article URLs so the same story is archived once.
module UrlKey
  module_function

  def call(value)
    return nil if value.nil? || value.to_s.strip.empty?

    uri = URI.parse(value.to_s)
    return nil unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil?

    uri.scheme = uri.scheme.downcase
    uri.host = uri.host.downcase
    uri.fragment = nil
    uri.port = nil if (uri.scheme == "http" && uri.port == 80) ||
      (uri.scheme == "https" && uri.port == 443)
    if uri.query
      pairs = URI.decode_www_form(uri.query).reject { |key, _| key.match?(/\Autm_/i) }
      uri.query = pairs.empty? ? nil : URI.encode_www_form(pairs)
    end
    uri.path = "/" if uri.path.nil? || uri.path.empty?
    uri.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
