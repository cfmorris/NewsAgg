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

# Every asset the app serves itself. The `mime` pattern is the Content-Type
# family without the charset, which is asserted separately.
ASSET_ROUTES = {
  "/dashboard.css" => { action: "dashboard_css", mime: %r{\Atext/css\b}, file: "dashboard.css" },
  "/dashboard.js" => { action: "dashboard_js", mime: %r{\Aapplication/javascript\b}, file: "dashboard.js" },
  "/turbo.js" => { action: "turbo", mime: %r{\Aapplication/javascript\b}, file: "turbo.js" }
}.freeze

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
# Rack::MockRequest drives the complete middleware stack, so these requests are
# answered the way a browser's are: ActionDispatch::Static gets first refusal,
# then the router, then DashboardController. Calling the controller method
# directly would skip all of that and prove nothing about the wire.

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

  # Every asset must come back from DashboardController. The static file
  # middleware leaves two fingerprints the controller never does: a
  # Last-Modified header taken from the file's mtime, and no Content-Disposition
  # (send_file always sets it to "inline").
  check "every asset is answered by its controller action, not the static middleware" do
    ASSET_ROUTES.each do |path, asset|
      response = request.get(path, host)
      assert(response.ok?, "#{path} answered HTTP #{response.status}")
      assert(response["Last-Modified"].nil?,
        "#{path} carries Last-Modified #{response['Last-Modified'].inspect}: the request was answered by " \
        "ActionDispatch::Static off public/, not by DashboardController##{asset[:action]}")
      assert(response["Content-Disposition"].to_s.include?("inline"),
        "#{path} has no inline Content-Disposition, so DashboardController##{asset[:action]} did not send the " \
        "file (Content-Disposition was #{response['Content-Disposition'].inspect})")
      assert(response["Content-Type"].to_s.match?(asset[:mime]),
        "#{path} Content-Type is #{response['Content-Type'].inspect}, expected a #{asset[:mime].source} type")
    end
  end

  # Reproduces the arrangement the live app fell into: a static file handler in
  # front of the app, pointed at public/. While the assets live in public/ the
  # handler answers them itself, from disk, with a bare text/css or
  # text/javascript Content-Type and a Last-Modified header -- the browser then
  # decodes the UTF-8 glyphs as cp1252. Once the files leave public/ the handler
  # finds nothing, falls through to the router, and the charset survives.
  check "a static mount over public/ cannot strip the charset from any asset" do
    shadowing_app = ActionDispatch::Static.new(Rails.application, Rails.root.join("public").to_s)
    shadowing_request = Rack::MockRequest.new(shadowing_app)
    ASSET_ROUTES.each do |path, asset|
      response = shadowing_request.get(path, host)
      assert(response.ok?, "#{path} answered HTTP #{response.status} behind a static mount over public/")
      assert(charset_utf8?(response),
        "#{path} loses its charset when a static mount sits over public/: " \
        "Content-Type is #{response['Content-Type'].inspect}. The response is coming off disk, not from " \
        "DashboardController##{asset[:action]}.")
      assert(response["Last-Modified"].nil?,
        "#{path} is served by the static handler (Last-Modified #{response['Last-Modified'].inspect}) " \
        "when public/ is mounted in front of the app")
    end
  end

  # "/dashboard.css" and "/dashboard.js" are also valid /dashboard requests with a
  # format suffix. If the asset routes lose their place ahead of /dashboard, the
  # dashboard action swallows them and the charset disappears again.
  check "the asset routes resolve to DashboardController, not to a format-suffixed /dashboard" do
    ASSET_ROUTES.each do |path, asset|
      recognised = Rails.application.routes.recognize_path(path, method: :get)
      assert(recognised[:controller].to_s == "dashboard",
        "#{path} routes to #{recognised[:controller].inspect}, expected \"dashboard\"")
      assert(recognised[:action].to_s == asset[:action],
        "#{path} routes to #{recognised[:controller]}##{recognised[:action]}, expected ##{asset[:action]}")
    end
  end

  # The whole point of the fix: nothing the router serves may also sit in
  # public/. ActionDispatch::Static (or any future static mount pointed at
  # public/) would win the race and strip the charset again, silently.
  check "no asset served by a route is also present in public/" do
    public_dir = Rails.root.join("public")
    shadowing = ASSET_ROUTES.values.map { |asset| asset[:file] }
      .select { |file| File.exist?(public_dir.join(file)) }
    assert(shadowing.empty?,
      "public/ still contains #{shadowing.join(', ')}; the static handler can shadow the controller actions " \
      "and drop the charset. Move them under app/.")
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
    # The direct visit may first hand the guest to the landing page that frames
    # the form; either way the page the reader lands on must serve its assets.
    page = request.get(page["Location"], host) if page.redirect?
    assert(page.ok?, "expected the sign-in page to answer HTTP 200, got #{page.status}")
    urls = asset_urls(page.body)
    assert(urls.any? { |url| url.end_with?(".css") }, "the sign-in page links no stylesheet")
    urls.each do |url|
      asset = request.get(url, host)
      assert(asset.ok?, "sign-in page asset #{url} answered HTTP #{asset.status}")
    end
  end
end
