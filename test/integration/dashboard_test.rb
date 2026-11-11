require "cgi"
require "json"
require "rack/mock"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"

include TestReport

def article(overrides)
  {
    "title" => "Untitled", "summary" => "", "publisher" => "Fixture Press",
    "depth" => "Overview", "topics" => [], "sources" => ["Hacker News"],
    "discoveries" => [], "topic_mappings" => [], "published_date" => nil,
    "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00"
  }.merge(overrides)
end

def relative_luminance(hex)
  channels = hex.delete_prefix("#").scan(/../).map { |value| value.to_i(16) / 255.0 }
  linear = channels.map { |value| value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4 }
  (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2])
end

def contrast_ratio(foreground, background)
  high, low = [relative_luminance(foreground), relative_luminance(background)].sort.reverse
  (high + 0.05) / (low + 0.05)
end

def css_color(css, name)
  value = css[/--#{Regexp.escape(name)}:\s*(#[0-9a-fA-F]{6})/, 1]
  raise "missing --#{name} in the dashboard stylesheet" unless value

  value
end

rows = [
  article(
    "title" => "Rails renders the dashboard",
    "summary" => "Controllers and views now filter articles and count them on the server.",
    "publisher" => "Rails Press",
    "depth" => "Deep dive",
    "topics" => ["Software Engineering", "AI & ML"],
    "url" => "https://example.test/rails",
    "discoveries" => [{ "source" => "Hacker News", "url" => "https://news.ycombinator.com/item?id=9001" }],
    "topic_mappings" => [
      { "heading" => "Software and its engineering", "topic" => "Software Engineering" },
      { "heading" => "Computing methodologies", "topic" => "AI & ML" }
    ]
  ),
  article(
    "title" => "A cluster observes itself",
    "summary" => "Kubernetes telemetry feeds a quieter operations dashboard.",
    "publisher" => "Ops Weekly",
    "depth" => "Technical analysis",
    "topics" => ["Systems & Hardware"],
    "url" => "https://example.test/cluster",
    "published_date" => "2026-11-01",
    "sources" => ["Lobsters"],
    "discoveries" => [{ "source" => "Lobsters", "url" => "https://lobste.rs/s/cluster" }],
    "topic_mappings" => [
      { "heading" => "Computer systems organization", "topic" => "Systems & Hardware" }
    ]
  )
]

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }

TestReport.run do
  check "the dashboard renders without an archive factory" do
    password = ENV.delete("NEO4J_PASSWORD")
    response = request.get("/", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response.body.include?("Could not load Neo4j"), "archive error missing")
  ensure
    ENV["NEO4J_PASSWORD"] = password
  end

  Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

  check "the dashboard renders server-side counts and articles" do
    response = request.get("/", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response.body.include?("NewsAgg: Your media aggregator"), "dashboard heading missing")
    assert(response.body.include?("2 articles"), "expected a two-article count")
    assert(response.body.include?("Rails renders the dashboard"), "first article missing")
    assert(response.body.include?("A cluster observes itself"), "second article missing")
    assert(response.body.include?("<turbo-frame id=\"dashboard\">"), "dashboard turbo frame missing")
  end

  check "search narrows the article list and count" do
    response = request.get("/?q=kubernetes", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response.body.include?("1 article"), "expected one matching article")
    assert(response.body.include?("A cluster observes itself"), "matching article missing")
    assert(!response.body.include?("Rails renders the dashboard"), "non-matching article still rendered")
  end

  check "publisher, source and depth facets filter together" do
    response = request.get("/?publisher=Ops+Weekly&source=Lobsters&depth=Technical+analysis", host)
    assert(response.body.include?("1 article"), "expected one facet match")
    assert(response.body.include?("A cluster observes itself"), "facet match missing")
  end

  check "topic links filter and report the selected topic in the count" do
    response = request.get("/?topic=#{CGI.escape("AI & ML")}", host)
    assert(response.body.include?("1 article · AI &amp; ML"), "topic count label missing")
    assert(response.body.include?("Rails renders the dashboard"), "topic article missing")
    assert(!response.body.include?("A cluster observes itself"), "unrelated article rendered")
  end

  check "topic headings aggregate their unmapped children" do
    response = request.get("/?heading=#{CGI.escape("Computer systems organization")}", host)
    assert(response.body.include?("1 article · Computer systems organization"), "heading count label missing")
    assert(response.body.include?("A cluster observes itself"), "heading article missing")
  end

  check "the publication-date facet excludes undated articles" do
    response = request.get("/?published_from=2026-10-31", host)
    assert(response.body.include?("1 article"), "expected one published article")
    assert(response.body.include?("A cluster observes itself"), "published article missing")
  end

  check "an empty result explains itself" do
    response = request.get("/?q=nothing-matches-this", host)
    assert(response.body.include?("0 articles"), "expected a zero count")
    assert(response.body.include?("No articles match these filters."), "empty-state message missing")
    assert(response.body.include?('class="empty-state"'), "empty state is not styled")
    assert(response.body.include?("Clear filters"), "empty state offers no way back")
  end

  check "the dashboard ships one permanent night theme" do
    response = request.get("/", host)
    assert(response.body.include?('data-theme="night"'), "night theme marker missing")
    assert(response.body.include?('href="/dashboard.css"'), "night stylesheet link missing")
    assert(response.body.include?('name="color-scheme" content="dark"'), "dark color-scheme hint missing")
    assert(!response.body.match?(/theme[-\s]?toggle|light[-\s]?theme/i), "found a theme toggle")
  end

  check "the stylesheet is served as a dark CSS document" do
    response = request.get("/dashboard.css", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response["content-type"].to_s.include?("text/css"), "expected a CSS content type")
    assert(response.body.include?("color-scheme: dark"), "expected a dark color scheme")
    assert(response.body.include?(":focus-visible"), "keyboard focus styles missing")
    assert(response.body.include?("turbo-frame[busy]"), "loading state styles missing")
  end

  check "the night palette keeps text, controls and focus readable" do
    css = request.get("/dashboard.css", host).body
    surface = css_color(css, "surface")
    assert(contrast_ratio(css_color(css, "text"), surface) >= 7, "body text contrast too low")
    assert(contrast_ratio(css_color(css, "text-muted"), surface) >= 4.5, "muted text contrast too low")
    assert(contrast_ratio(css_color(css, "accent"), surface) >= 4.5, "link contrast too low")
    assert(contrast_ratio(css_color(css, "on-accent"), css_color(css, "accent-fill")) >= 4.5,
      "button label contrast too low")
    assert(contrast_ratio(css_color(css, "focus"), surface) >= 3, "focus ring contrast too low")
    assert(contrast_ratio(css_color(css, "border-control"), surface) >= 3, "control border contrast too low")
  end

  check "the Turbo stream publishes an archive version and honors ETags" do
    first = request.get("/dashboard/stream", host)
    assert(first.ok?, "expected HTTP 200, got #{first.status}")
    assert(first["content-type"].to_s.include?("turbo-stream"), "expected a turbo-stream response")
    assert(first.body.include?("archive-version"), "version target missing")
    etag = first["ETag"]
    assert(!etag.to_s.empty?, "expected an ETag")
    second = request.get("/dashboard/stream", host.merge("HTTP_IF_NONE_MATCH" => etag))
    assert(second.status == 304, "expected HTTP 304, got #{second.status}")
  end

  check "Auto-pull reads and writes its flag through the Rails endpoint" do
    enable = request.put("/auto-pull", host.merge(
      "CONTENT_TYPE" => "application/json",
      "HTTP_ORIGIN" => "http://127.0.0.1:3000",
      input: JSON.generate(enabled: true)
    ))
    assert(enable.status == 200, "enable failed with #{enable.status}")
    assert(JSON.parse(enable.body)["enabled"] == true, "flag was not enabled")
    page = request.get("/", host)
    assert(page.body.match?(/id="auto-pull"[^>]*checked/m), "toggle did not render checked")

    disable = request.put("/auto-pull", host.merge(
      "CONTENT_TYPE" => "application/json",
      "HTTP_ORIGIN" => "http://127.0.0.1:3000",
      input: JSON.generate(enabled: false)
    ))
    assert(disable.status == 200, "disable failed with #{disable.status}")
    assert(JSON.parse(disable.body)["enabled"] == false, "flag was not disabled")
  end

  check "an unavailable archive still renders the dashboard shell" do
    Rails.application.config.x.archive_factory = -> { UnavailableArchive.new }
    response = request.get("/", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response.body.include?("Could not load Neo4j"), "archive error message missing")
    assert(response.body.include?('class="notice notice-error"'), "archive error is not styled")
    assert(response.body.include?('role="alert"'), "archive error is not announced")
    assert(response.body.include?("NewsAgg: Your media aggregator"), "dashboard heading missing")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end
end
