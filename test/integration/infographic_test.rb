ENV["RAILS_ENV"] = "test"

require "rack/mock"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"
require_relative "../support/signed_in"

include TestReport

def article(overrides)
  {
    "title" => "Untitled", "summary" => "", "publisher" => "Fixture Press",
    "depth" => "Overview", "topics" => [], "sources" => ["Hacker News"],
    "discoveries" => [], "topic_mappings" => [], "published_date" => nil,
    "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00",
    "url" => "https://example.test/fixture"
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

# Two publishers (Repeat Press, Ops Weekly, Rails Press, Island Press) repeat;
# four appear exactly once. Five topics carry two or more headlines, two are briefs.
# One article is untagged, one publisher/title arrives as binary bytes.
rows = [
  article(
    "title" => "Fiber reaches the home", "publisher" => "Archive Press",
    "depth" => "Overview", "topics" => ["Networks"], "published_date" => "1996-11-08",
    "archive_timestamp" => "2026-11-11T14:54:00Z", "url" => "https://example.test/fiber"
  ),
  article(
    "title" => "Neural nets return", "publisher" => "Repeat Press",
    "depth" => "Technical analysis", "topics" => ["AI & ML", "Networks"],
    "published_date" => "2024-05-02", "archive_timestamp" => "2026-11-11T15:30:00Z",
    "url" => "https://example.test/neural"
  ),
  article(
    "title" => "Another AI piece", "publisher" => "Repeat Press",
    "depth" => "Technical analysis", "topics" => ["AI & ML"],
    "published_date" => "2025-01-01", "archive_timestamp" => "2026-11-11T16:00:00Z",
    "url" => "https://example.test/ai"
  ),
  article(
    "title" => "Edge models", "publisher" => "Ops Weekly",
    "depth" => "Deep dive", "topics" => ["AI & ML", "Systems & Hardware"],
    "published_date" => "2023-03-03", "archive_timestamp" => "2026-11-11T16:15:00Z",
    "url" => "https://example.test/edge"
  ),
  article(
    "title" => "Design systems at scale", "publisher" => "Ya\xFFz Aksoy".b,
    "depth" => "Overview", "topics" => ["Design"], "published_date" => "2022-02-02",
    "archive_timestamp" => "2026-11-11T16:30:00Z", "url" => "https://example.test/design"
  ),
  article(
    "title" => "Second design note", "publisher" => "Studio Press",
    "depth" => "Overview", "topics" => ["Design"], "published_date" => "2021-01-01",
    "archive_timestamp" => "2026-11-11T17:00:00Z", "url" => "https://example.test/design-2"
  ),
  article(
    "title" => "Rails renders the front page", "publisher" => "Rails Press",
    "depth" => "Overview", "topics" => ["Software Engineering"], "published_date" => "2022-06-06",
    "archive_timestamp" => "2026-11-11T17:30:00Z", "url" => "https://example.test/rails"
  ),
  article(
    "title" => "Ruby threads", "publisher" => "Rails Press",
    "depth" => "Technical analysis", "topics" => ["Software Engineering"],
    "published_date" => "2020-04-04", "archive_timestamp" => "2026-11-11T18:00:00Z",
    "url" => "https://example.test/threads"
  ),
  article(
    "title" => "Cluster telemetry", "publisher" => "Ops Weekly",
    "depth" => "Technical analysis", "topics" => ["Systems & Hardware", "Security"],
    "published_date" => "2023-09-09", "archive_timestamp" => "2026-11-11T18:30:00Z",
    "url" => "https://example.test/cluster"
  ),
  article(
    "title" => "Untagged oddity", "publisher" => "Lone Voice",
    "depth" => "Overview", "topics" => [], "published_date" => "2021-05-05",
    "archive_timestamp" => "2026-11-11T19:00:00Z", "url" => "https://example.test/untagged"
  ),
  article(
    "title" => "Broken \xC3 title".b, "publisher" => "Island Press",
    "depth" => "Overview", "topics" => ["Systems & Hardware"], "published_date" => "2019-02-02",
    "archive_timestamp" => "2026-11-11T22:00:00Z", "url" => "https://example.test/audit"
  ),
  article(
    "title" => "Privacy basics", "publisher" => "Island Press",
    "depth" => "Deep dive", "topics" => ["Privacy"], "published_date" => "2019-06-06",
    "archive_timestamp" => "2026-11-11T23:33:00Z", "url" => "https://example.test/privacy"
  )
]

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }
# The infographic is behind the sign-in gate now; every request below carries
# the cookie a signed-in reader would.
auth = host.merge("HTTP_COOKIE" => sign_in_cookie)

TestReport.run do
  Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

  check "the infographic renders a masthead with the edition and counts" do
    response = request.get("/infographic", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    body = response.body
    assert(body.match?(%r{<h1[^>]*>[^<]*Archive Broadsheet}), "masthead h1 missing")
    assert(body.include?("2026-11-11"), "edition date missing")
    assert(body.include?("12 articles"), "total article count missing")
    assert(body.include?("7 topics"), "topic count missing")
    assert(body.include?("8 publishers"), "publisher count missing")
    assert(body.include?('href="/dashboard.css"'), "dashboard stylesheet link missing")
  end

  check "five topic columns carry counts and headlines, the rest become briefs" do
    body = request.get("/infographic", auth).body
    columns = body.scan(/<section class="topic-column"[\s\S]*?<\/section>/)
    assert(columns.length == 5, "expected five topic columns, got #{columns.length}")

    expected = {
      "AI &amp; ML" => 3, "Design" => 2, "Networks" => 2,
      "Software Engineering" => 2, "Systems &amp; Hardware" => 3
    }
    expected.each do |name, count|
      column = columns.find { |candidate| candidate.include?(name) }
      assert(!column.nil?, "#{name} column missing")
      assert(column.include?("#{count} headlines"), "#{name} column should report #{count} headlines")
    end

    ai = columns.find { |column| column.include?("AI &amp; ML") }
    ["Neural nets return", "Another AI piece", "Edge models"].each do |title|
      assert(ai.include?(title), "#{title} missing from the AI & ML column")
    end
    assert(ai.include?("Repeat Press") && ai.include?("2024"), "column byline missing publisher or year")

    assert(body.include?("Briefs"), "briefs strip missing")
    assert(body.scan(/class="brief"/).length == 2, "expected two brief topics")
    assert(body.match?(/class="brief"[\s\S]*?Security/) || body.match?(/Security[\s\S]*?class="brief"/),
      "Security brief missing")
    assert(body.include?("Privacy"), "Privacy brief missing")
  end

  check "the depth block reports every depth value and its total" do
    body = request.get("/infographic", auth).body
    section = body[/<section class="depth-section"[\s\S]*?<\/section>/]
    assert(!section.nil?, "depth section missing")
    assert(section.include?("Technical analysis"), "Technical analysis missing from depth block")
    assert(section.include?("4 (33%)"), "Technical analysis count or share missing")
    assert(section.include?("Overview") && section.include?("6 (50%)"), "Overview count missing")
    assert(section.include?("Deep dive") && section.include?("2 (17%)"), "Deep dive count missing")
    assert(section.include?("12"), "depth total missing")
    assert(section.include?("<ol") || section.include?("<ul"), "depth breakdown has no list semantics")
  end

  check "the publisher strip separates repeat publishers from the single-article tail" do
    body = request.get("/infographic", auth).body
    section = body[/<section class="publisher-section"[\s\S]*?<\/section>/]
    assert(!section.nil?, "publisher section missing")
    named = section[/<ul class="named-publishers"[\s\S]*?<\/ul>/]
    assert(!named.nil?, "named publisher list missing")
    ["Island Press", "Ops Weekly", "Rails Press", "Repeat Press"].each do |publisher|
      assert(named.include?(publisher), "#{publisher} missing from the named publishers")
    end
    assert(named.include?("2"), "named publisher counts missing")
    assert(section.include?("4 publishers appear exactly once"),
      "the single-article tail size is not reported")
    assert(!named.include?("Archive Press"), "single-article publisher leaked into the named list")
    assert(section.scan(/class="publisher-dot/).length == 8, "expected one dot per publisher")
  end

  check "the dateline names the oldest article and its publication year" do
    body = request.get("/infographic", auth).body
    dateline = body[/<[^>]*class="dateline[^"]*"[\s\S]*?<\/p>/]
    assert(!dateline.nil?, "dateline callout missing")
    assert(dateline.include?("Fiber reaches the home"), "oldest article missing from the dateline")
    assert(dateline.include?("1996-11-08"), "oldest publication date missing from the dateline")
  end

  check "an untagged article lands in a catch-all section" do
    body = request.get("/infographic", auth).body
    assert(body.include?('id="catch-all"'), "catch-all section missing")
    assert(body.include?("Untagged oddity"), "untagged article vanished from the page")
  end

  check "binary publisher and title bytes are scrubbed instead of raising" do
    response = request.get("/infographic", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    body = response.body
    assert(body.valid_encoding?, "response body is not valid UTF-8")
    assert(body.include?("Ya") && body.include?("z Aksoy"), "scrubbed publisher missing")
    assert(body.include?("Broken ? title"), "scrubbed title missing")
  end

  check "an empty archive renders a composed no-edition state" do
    Rails.application.config.x.archive_factory = -> { FakeArchive.new([]) }
    response = request.get("/infographic", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(response.body.include?("No edition today"), "empty state missing")
    assert(response.body.include?("Archive Broadsheet"), "masthead missing from the empty state")
    assert(!response.body.include?("topic-column"), "empty state still renders topic columns")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end

  check "the infographic headings stay hierarchical and the stylesheet stays readable" do
    body = request.get("/infographic", auth).body
    assert(body.match?(%r{<h1[^>]*>}), "no h1 masthead")
    h2_count = body.scan(%r{<h2[^>]*>}).length
    assert(h2_count >= 4, "expected an h2 per section, got #{h2_count}")
    assert(body.include?('aria-hidden="true"'), "decorative bars should be hidden from assistive tech")

    css = request.get("/dashboard.css", host).body
    paper = css_color(css, "front-paper")
    assert(contrast_ratio(css_color(css, "front-ink"), paper) >= 7, "front-page ink contrast too low")
    assert(contrast_ratio(css_color(css, "front-muted"), paper) >= 4.5, "front-page muted text contrast too low")
    assert(contrast_ratio(css_color(css, "front-rule"), paper) >= 3, "front-page rule contrast too low")
    assert(css.match?(/@media \(max-width: 720px\)[\s\S]*?\.topic-columns\s*\{[^}]*grid-template-columns:\s*1fr/),
      "topic columns do not collapse to one column on narrow screens")
    assert(css.match?(/overflow-wrap:\s*anywhere/), "long headlines can force horizontal scrolling")
  end
end
