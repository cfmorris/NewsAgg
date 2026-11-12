ENV["RAILS_ENV"] = "test"

require "rack/mock"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/signed_in"

include TestReport

# The stylesheet carries the disclosure arrow (U+25B8) and the meta separator
# (U+00B7) as raw UTF-8. These are the bytes a browser must receive.
ARROW_GLYPH_BYTES = "\xE2\x96\xBE".b
SEPARATOR_GLYPH_BYTES = "\xC2\xB7".b

def binary_body(response)
  response.body.to_s.dup.force_encoding(Encoding::BINARY)
end

def charset_utf8?(response)
  response["Content-Type"].to_s.downcase.match?(/charset\s*=\s*utf-8/)
end

def asset_urls(html)
  html.scan(/(?:href|src)="([^"]+\.(?:css|js))"/).flatten.uniq
end

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }

TestReport.run do
  check "the dashboard stylesheet declares utf-8 in its content type" do
    response = request.get("/dashboard.css", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(charset_utf8?(response),
      "expected the stylesheet Content-Type to declare utf-8, got #{response['Content-Type'].inspect}")
  end

  check "the dashboard stylesheet still serves the glyphs as UTF-8 bytes" do
    body = binary_body(request.get("/dashboard.css", host))
    assert(body.include?(ARROW_GLYPH_BYTES),
      "the disclosure arrow (E2 96 BE) is missing from the served stylesheet")
    assert(body.include?(SEPARATOR_GLYPH_BYTES),
      "the meta separator (C2 B7) is missing from the served stylesheet")
  end

  check "both scripts declare utf-8 in their content type" do
    %w[/dashboard.js /turbo.js].each do |path|
      response = request.get(path, host)
      assert(response.ok?, "#{path} answered HTTP #{response.status}")
      assert(charset_utf8?(response),
        "#{path} Content-Type does not declare utf-8: #{response['Content-Type'].inspect}")
      assert(response["Content-Type"].to_s.match?(%r{\A(?:application|text)/javascript\b}),
        "#{path} no longer serves a JavaScript content type: #{response['Content-Type'].inspect}")
    end
  end

  check "the landing page loads its stylesheet and scripts" do
    page = request.get("/", host)
    assert(page.ok?, "expected the landing page to answer HTTP 200, got #{page.status}")
    assert(page.body.include?("<meta charset=\"utf-8\">"),
      "the layout lost its meta charset")
    urls = asset_urls(page.body)
    assert(urls.any? { |url| url.end_with?(".css") }, "the landing page links no stylesheet")
    urls.each do |url|
      asset = request.get(url, host)
      assert(asset.ok?, "landing page asset #{url} answered HTTP #{asset.status}")
    end
  end

  check "the sign-in page loads its stylesheet and scripts" do
    page = request.get("/users/sign_in", host)
    assert(page.ok?, "expected the sign-in page to answer HTTP 200, got #{page.status}")
    urls = asset_urls(page.body)
    assert(urls.any? { |url| url.end_with?(".css") }, "the sign-in page links no stylesheet")
    urls.each do |url|
      asset = request.get(url, host)
      assert(asset.ok?, "sign-in page asset #{url} answered HTTP #{asset.status}")
    end
  end
end
