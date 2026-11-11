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

# The href of the first anchor carrying the given class and aria-pressed state.
def filter_href(body, css_class, pressed = nil)
  body.scan(/<a [^>]*>/).each do |anchor|
    next unless anchor.include?("class=\"#{css_class}\"")
    next if pressed && !anchor.include?("aria-pressed=\"#{pressed}\"")

    href = anchor[/href="([^"]+)"/, 1]
    return CGI.unescapeHTML(href) if href
  end
  nil
end

def query_of(href)
  require "uri"
  query = URI(href).query
  return {} if query.nil? || query.empty?

  parse = ->(string) { string.split("&").to_h { |pair| pair.split("=", 2).map { |part| CGI.unescape(part.tr("+", " ")) } } }
  parse.call(query)
end

recent_timestamp = (Time.now.utc - 3600).iso8601
older_timestamp = (Time.now.utc - (72 * 3600)).iso8601

def article_cards(html)
  html.scan(%r{<article>.*?</article>}m)
end

def card_for(html, title)
  article_cards(html).find { |card| card.include?(title) } ||
    raise("no article card rendered for #{title.inspect}")
end

def heading_of(card)
  card[%r{<h3[^>]*>.*?</h3>}m] || raise("article card has no h3 title row")
end

def paragraph_of(card)
  card[%r{<p[^>]*>.*?</p>}m] || raise("article card has no summary paragraph")
end

# True when every anchor in the card lives inside its title row or its summary.
def links_only_in_title_row_and_summary?(card)
  rest = card.gsub(%r{<h3[^>]*>.*?</h3>}m, "").gsub(%r{<p[^>]*>.*?</p>}m, "")
  !rest.include?("<a ")
end

rows = [
  article(
    "archive_timestamp" => recent_timestamp,
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
    "archive_date" => "2026-11-01",
    "archive_timestamp" => older_timestamp,
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

  check "tag pills sit in the title row instead of their own row" do
    response = request.get("/", host)
    card = card_for(response.body, "Rails renders the dashboard")
    heading = heading_of(card)
    assert(heading.include?("Software Engineering"), "topic pill missing from the h3 title row")
    assert(heading.include?("AI &amp; ML"), "second topic pill missing from the h3 title row")
    assert(heading.include?('class="tag"'), "topic pills lost their tag styling hook")
    assert(heading.include?('data-turbo-frame="dashboard"'), "topic pills lost the Turbo frame target")
    assert(heading.include?("aria-pressed"), "topic pills lost their pressed state")
    assert(links_only_in_title_row_and_summary?(card),
      "a link renders outside the title row and the summary paragraph")
    assert(card.scan(%r{<h3}).length == 1, "the card renders more than one heading")
  end

  check "topic pills keep filtering the dashboard through the Turbo frame" do
    response = request.get("/", host)
    card = card_for(response.body, "Rails renders the dashboard")
    pill = heading_of(card)[%r{<a [^>]*>AI &amp; ML</a>}]
    assert(pill, "topic pill missing from the title row")
    assert(pill.include?("topic=AI"), "topic pill no longer links to a topic filter: #{pill}")
    assert(pill.include?('aria-pressed="false"'), "unselected topic pill lost its pressed state")

    selected = request.get("/?topic=#{CGI.escape("AI & ML")}", host)
    selected_pill = heading_of(card_for(selected.body, "Rails renders the dashboard"))[%r{<a [^>]*>AI &amp; ML</a>}]
    assert(selected_pill, "selected topic pill missing from the title row")
    assert(selected_pill.include?('aria-pressed="true"'), "selected topic pill lost its pressed state")
  end

  check "the summary ends with the Original and discovery links inline" do
    response = request.get("/", host)
    summary = paragraph_of(card_for(response.body, "Rails renders the dashboard"))
    assert(summary.include?("Controllers and views now filter articles and count them on the server."),
      "the full summary text is not rendered")
    assert(summary.include?(" · <a"), "summary links are not separated by the card's separator")
    original = summary[%r{<a [^>]*>Original</a>}]
    assert(original, "Original link missing from the summary")
    assert(original.include?("https://example.test/rails"), "Original link points at #{original}")
    discussion = summary[%r{<a [^>]*>HN discussion</a>}]
    assert(discussion, "HN discussion link missing from the summary")
    assert(discussion.include?("https://news.ycombinator.com/item?id=9001"),
      "HN discussion link points at #{discussion}")
    assert(summary.strip.end_with?("</a></p>"), "summary paragraph does not end with its last link")
  end

  check "other discovery sources keep their own label inline" do
    response = request.get("/", host)
    summary = paragraph_of(card_for(response.body, "A cluster observes itself"))
    assert(summary[%r{<a [^>]*>Lobsters</a>}], "Lobsters discovery is not labelled by its source name")
    assert(!summary.include?("HN discussion"), "Lobsters discovery is mislabelled as Hacker News")
  end

  check "an article without discoveries links only to the original" do
    Rails.application.config.x.archive_factory = -> {
      FakeArchive.new([
        article(
          "title" => "No discoveries here", "summary" => "A summary with nothing to discuss.",
          "topics" => ["Software Engineering"], "url" => "https://example.test/solo",
          "discoveries" => []
        )
      ])
    }
    response = request.get("/", host)
    summary = paragraph_of(card_for(response.body, "No discoveries here"))
    assert(summary[%r{<a [^>]*>Original</a>}], "Original link missing for an undiscovered article")
    assert(!summary.include?("HN discussion"), "an undiscovered article rendered a discussion link")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end

  check "an article without topics renders no tag container" do
    Rails.application.config.x.archive_factory = -> {
      FakeArchive.new([
        article(
          "title" => "An untagged article", "summary" => "Summary text that stands on its own.",
          "topics" => [], "url" => "https://example.test/untagged", "discoveries" => []
        )
      ])
    }
    response = request.get("/", host)
    card = card_for(response.body, "An untagged article")
    assert(!card.include?('class="tags"'), "an empty tag container is still rendered")
    assert(heading_of(card).include?("An untagged article"), "title text missing from the heading")
    assert(paragraph_of(card).include?("Summary text that stands on its own."),
      "summary missing from an untagged article")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end

  check "an article with no summary still renders its links" do
    Rails.application.config.x.archive_factory = -> {
      FakeArchive.new([
        article("title" => "A silent article", "summary" => nil, "topics" => ["AI & ML"],
          "url" => "https://example.test/silent", "discoveries" => [])
      ])
    }
    response = request.get("/", host)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    summary = paragraph_of(card_for(response.body, "A silent article"))
    assert(summary[%r{<a [^>]*>Original</a>}], "Original link missing when the summary is nil")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end

  check "the compact card keeps type readable and the summary unclamped" do
    css = request.get("/dashboard.css", host).body
    meta_size = css[/article small \{[^}]*font-size:\s*([\d.]+)rem/, 1]
    tag_size = css[/\.tags a,[^{]*\{[^}]*font-size:\s*([\d.]+)rem/, 1]
    title_size = css[/\.article-title \{[^}]*font-size:\s*([\d.]+)rem/, 1]
    padding = css[/article \{[^}]*padding:\s*([\d.]+)rem [\d.]+rem/, 1]
    assert(meta_size && meta_size.to_f >= 0.75, "meta text shrank below .75rem")
    assert(tag_size && tag_size.to_f >= 0.75, "tag pills shrank below .75rem")
    assert(title_size && title_size.to_f <= 1.2, "the title did not drop a type step")
    assert(padding && padding.to_f <= 1.05, "the card padding did not tighten")
    summary_rule = css[/article p \{[^}]*\}/m].to_s
    assert(!summary_rule.match?(/line-clamp|text-overflow|overflow:\s*hidden/),
      "the summary paragraph is clamped or clipped")
  end

  check "the publication-date facet excludes undated articles" do
    response = request.get("/?published_from=2026-10-31", host)
    assert(response.body.include?("1 article"), "expected one published article")
    assert(response.body.include?("A cluster observes itself"), "published article missing")
  end

  check "the date controls collapse into one block" do
    response = request.get("/", host)
    body = response.body
    assert(!body.match?(/name="published_from"/), "published_from input still rendered")
    assert(!body.match?(/name="published_through"/), "published_through input still rendered")
    assert(!body.match?(/>Publication date</), "publication date heading still rendered")
    assert(body.scan(/class="date-block"/).length == 1, "expected exactly one date block")
    assert(body.scan(/name="date_preset"/).length == 1, "expected exactly one date preset control")
    assert(body.include?("<summary"), "expected a disclosure for the custom date range")
    assert(body.include?("Custom range"), "custom range disclosure label missing")
    assert(body.match?(/name="date_from"/), "date_from input missing from the custom range")
    assert(body.match?(/name="date_through"/), "date_through input missing from the custom range")
  end

  check "the custom range opens when a custom date is active" do
    response = request.get("/?date_from=2026-11-10", host)
    block = response.body[/<details[^>]*id="custom-range"[^>]*>/, 0].to_s
    assert(!block.empty?, "custom range disclosure missing")
    assert(block.include?("open"), "custom range should start open when a custom date is active")
    assert(response.body.match?(/<summary aria-expanded="true">Custom range<\/summary>/),
      "active disclosure should report aria-expanded=true")
  end

  check "topic navigation renders one flat level" do
    response = request.get("/?heading=#{CGI.escape("Software and its engineering")}", host)
    body = response.body
    assert(!body.include?('class="subtopics"'), "nested subtopics container still rendered")
    assert(body.match?(/class="bar heading-caption"/), "heading captions missing")
    assert(body.match?(/class="bar topic"/), "flat topic row missing")
    assert(body.include?("Software Engineering"), "topic row label missing")
    assert(body.scan(/class="bar topic"/).length == 1, "expected exactly one topic row per topic")
    assert(body.match?(/class="bar topic"[^>]*--share:/) || body.match?(/--share:[^"]*"[^>]*class="bar topic"/),
      "topic rows lost their share bar")
    assert(body.match?(/class="bar heading-caption"[^>]*aria-pressed="true"/) ||
      body.match?(/aria-pressed="true"[^>]*class="bar heading-caption"/),
      "selected heading caption is not pressed")
  end

  check "the panel summarises active filters" do
    response = request.get("/?q=rails&depth=Deep+dive", host)
    assert(response.body.include?('class="filter-count"'), "active filter count missing from the panel summary")
    assert(response.body.include?("2 active"), "expected the summary to report two active filters")

    clear = request.get("/", host)
    assert(clear.body.include?("No filters active"), "summary should say when no filters are active")
  end

  check "date presets, ranges, topics and headings narrow the visible set" do
    preset = request.get("/?date_preset=24", host)
    assert(preset.body.include?("1 article"), "date preset did not narrow the set")
    assert(preset.body.include?("Rails renders the dashboard"), "recent article missing from preset view")
    assert(!preset.body.include?("A cluster observes itself"), "old article survived the date preset")

    from = request.get("/?date_from=2026-11-10", host)
    assert(from.body.include?("1 article"), "date_from did not narrow the set")
    assert(from.body.include?("Rails renders the dashboard"), "date_from dropped the recent article")

    through = request.get("/?date_through=2026-11-05", host)
    assert(through.body.include?("1 article"), "date_through did not narrow the set")
    assert(through.body.include?("A cluster observes itself"), "date_through dropped the older article")

    topic = request.get("/?topic=#{CGI.escape("AI & ML")}", host)
    assert(topic.body.include?("1 article · AI &amp; ML"), "topic selection not reflected in the count")

    heading = request.get("/?heading=#{CGI.escape("Computer systems organization")}", host)
    assert(heading.body.include?("1 article · Computer systems organization"), "heading selection not reflected in the count")
  end

  check "filter links keep aria-pressed and disclosures keep aria-expanded" do
    response = request.get("/?heading=#{CGI.escape("Software and its engineering")}", host)
    links = response.body.scan(/<a [^>]*class="bar[^"]*"[^>]*>/)
    assert(links.length >= 3, "expected filter links in the panel")
    links.each do |link|
      assert(link.include?('aria-pressed='), "filter link missing aria-pressed: #{link}")
    end
    summaries = response.body.scan(/<summary[^>]*>/)
    assert(summaries.length >= 2, "expected panel and custom-range disclosures")
    summaries.each do |summary|
      assert(summary.include?('aria-expanded='), "disclosure summary missing aria-expanded: #{summary}")
    end
  end

  check "deselecting a topic returns to all articles while keeping the other filters" do
    response = request.get("/?topic=#{CGI.escape("AI & ML")}&heading=#{CGI.escape("Computing methodologies")}" \
      "&q=rails&publisher=#{CGI.escape("Rails Press")}&date_preset=72", host)
    href = filter_href(response.body, "bar topic", "true")
    assert(href, "selected topic link missing")
    query = query_of(href)
    assert(!query.key?("topic"), "deselecting the topic kept topic=#{query["topic"]}")
    assert(!query.key?("heading"), "deselecting the topic kept heading=#{query["heading"]}")
    assert(query["q"] == "rails", "search filter was lost")
    assert(query["publisher"] == "Rails Press", "publisher filter was lost")
    assert(query["date_preset"] == "72", "date preset filter was lost")
  end

  check "selecting a topic still narrows it to the topic and its heading" do
    response = request.get("/?heading=#{CGI.escape("Computing methodologies")}&q=rails", host)
    links = response.body.scan(/<a [^>]*>.*?<\/a>/m).select do |anchor|
      anchor.include?('class="bar topic"') && anchor.include?("AI &amp; ML")
    end
    href = links.filter_map { |anchor| anchor[/href="([^"]+)"/, 1] }.first
    assert(href, "topic link missing")
    query = query_of(CGI.unescapeHTML(href))
    assert(query["topic"] == "AI & ML", "topic was not selected")
    assert(query["heading"] == "Computing methodologies", "topic link lost its heading")
    assert(query["q"] == "rails", "selecting a topic dropped the search filter")
  end

  check "deselecting a heading returns to all articles and keeps the other filters" do
    response = request.get("/?heading=#{CGI.escape("Software and its engineering")}&q=rails&publisher=#{CGI.escape("Rails Press")}", host)
    href = filter_href(response.body, "bar heading-caption", "true")
    assert(href, "selected heading link missing")
    query = query_of(href)
    assert(!query.key?("heading"), "deselecting the heading kept heading=#{query["heading"]}")
    assert(!query.key?("topic"), "deselecting the heading added a topic")
    assert(query["q"] == "rails", "search filter was lost")
    assert(query["publisher"] == "Rails Press", "publisher filter was lost")
  end

  check "deselecting an article tag returns to all articles and keeps the other filters" do
    response = request.get("/?topic=#{CGI.escape("AI & ML")}&heading=#{CGI.escape("Computing methodologies")}&q=rails", host)
    href = filter_href(response.body, "tag", "true")
    assert(href, "selected article tag link missing")
    query = query_of(href)
    assert(!query.key?("topic"), "deselecting the tag kept topic=#{query["topic"]}")
    assert(!query.key?("heading"), "deselecting the tag kept heading=#{query["heading"]}")
    assert(query["q"] == "rails", "search filter was lost")
  end

  check "the filters panel opens for active filters and exposes its state hook" do
    active = request.get("/?q=rails", host).body[/<details class="filters-disclosure"[^>]*>/]
    assert(active, "filters disclosure missing")
    assert(active.match?(/\sopen[\s>]/), "panel should start open when a filter is active")
    key = active[/data-filters-state-key="([^"]+)"/, 1]
    assert(key && !key.empty?, "filters disclosure exposes no state storage key")

    idle = request.get("/", host).body[/<details class="filters-disclosure"[^>]*>/]
    assert(idle, "filters disclosure missing")
    assert(!idle.match?(/\sopen[\s>]/), "panel should start closed when no filter is active")
  end

  check "clear filters still drops every filter" do
    response = request.get("/?q=rails&topic=#{CGI.escape("AI & ML")}&publisher=#{CGI.escape("Rails Press")}", host)
    anchor = response.body.scan(/<a [^>]*>Clear filters<\/a>/).first
    assert(anchor, "clear filters link missing")
    assert(anchor.include?('href="/"'), "clear filters should link to a bare root path: #{anchor}")
  end

  check "the panel stays scrollable and pinned above 900px" do
    css = request.get("/dashboard.css", host).body
    assert(css.match?(/aside\.filter-panel\s*\{[^}]*position:\s*sticky/m), "panel is not sticky")
    assert(css.match?(/aside\.filter-panel\s*\{[^}]*max-height:\s*calc\(100vh - 2\.5rem\)/m), "panel has no viewport cap")
    assert(css.match?(/aside\.filter-panel\s*\{[^}]*overflow-y:\s*auto/m), "panel does not scroll internally")
    assert(css.match?(/aside\.filter-panel\s*\{[^}]*overscroll-behavior:\s*contain/m), "panel does not contain overscroll")
    assert(css.match?(/@media \(max-width: 900px\)[\s\S]*?aside\.filter-panel\s*\{[^}]*position:\s*static/m),
      "narrow panels should not be sticky")
    assert(css.include?("min-height: 2.75rem"), "touch targets are not 44px at narrow widths")
    assert(!css.include?(".subtopics"), "nested subtopic styling still present")
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
