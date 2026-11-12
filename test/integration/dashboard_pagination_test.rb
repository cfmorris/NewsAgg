ENV["RAILS_ENV"] = "test"

require "cgi"
require "json"
require "rack/mock"
require "uri"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"
require_relative "../support/signed_in"

include TestReport

# A disposable archive of 60 articles: the first 30 carry the AI & ML topic,
# the last 30 carry Systems & Hardware, and the first 40 were archived on
# 2026-11-05 while the rest are older. That gives the pagination tests a
# filtered set that still spans more than one page.
def paged_article(index)
  ai = index < 30
  recent = index < 40
  date = recent ? "2026-11-05" : "2026-09-01"
  {
    "title" => "Article #{index}",
    "summary" => "Summary for article #{index}.",
    "publisher" => "Fixture Press",
    "depth" => "Overview",
    "topics" => [ai ? "AI & ML" : "Systems & Hardware"],
    "sources" => ["Hacker News"],
    "discoveries" => [],
    "topic_mappings" => [
      {
        "heading" => ai ? "Computing methodologies" : "Computer systems organization",
        "topic" => ai ? "AI & ML" : "Systems & Hardware"
      }
    ],
    "published_date" => nil,
    "archive_date" => date,
    "archive_timestamp" => "#{date}T12:00:00-05:00"
  }
end

rows = (0...60).map { |index| paged_article(index) }

def article_titles(html)
  html.scan(%r{<h3[^>]*>.*?</h3>}m).filter_map { |heading| heading[/Article \d+/] }
end

def article_cards(html)
  html.scan(%r{<article>.*?</article>}m)
end

# The href of the first anchor whose visible text is exactly the given label.
def link_with_text(html, label)
  html.scan(/<a [^>]*>.*?<\/a>/m).each do |anchor|
    text = CGI.unescapeHTML(anchor.gsub(/<[^>]+>/, "")).strip
    next unless text == label

    href = anchor[/href="([^"]+)"/, 1]
    return CGI.unescapeHTML(href) if href
  end
  nil
end

# The href of the first anchor whose stripped text starts with the given label
# and whose opening tag carries the given CSS class.
def filter_anchor(html, label, css_class)
  html.scan(/<a [^>]*>.*?<\/a>/m).each do |anchor|
    next unless anchor[/^<a [^>]*>/].to_s.include?("class=\"#{css_class}\"")

    text = CGI.unescapeHTML(anchor.gsub(/<[^>]+>/, "")).strip
    next unless text.start_with?(label)

    href = anchor[/href="([^"]+)"/, 1]
    return CGI.unescapeHTML(href) if href
  end
  nil
end

def query_of(href)
  query = URI(href).query
  return {} if query.nil? || query.empty?

  query.split("&").to_h { |pair| pair.split("=", 2).map { |part| CGI.unescape(part.tr("+", " ")) } }
end

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }
auth = host.merge("HTTP_COOKIE" => sign_in_cookie)

Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

TestReport.run do
  check "page 1 shows the first 25 of 60 articles" do
    response = request.get("/dashboard", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(article_cards(response.body).length == 25,
      "page 1 rendered #{article_cards(response.body).length} cards, expected 25")
    assert(article_titles(response.body) == (0...25).map { |index| "Article #{index}" },
      "page 1 rendered #{article_titles(response.body).inspect}")
  end

  check "page 2 shows the next 25 articles" do
    response = request.get("/dashboard?page=2", auth)
    assert(article_titles(response.body) == (25...50).map { |index| "Article #{index}" },
      "page 2 rendered #{article_titles(response.body).inspect}")
  end

  check "page 3 shows the remaining 10 articles and reports the page" do
    response = request.get("/dashboard?page=3", auth)
    assert(article_cards(response.body).length == 10,
      "page 3 rendered #{article_cards(response.body).length} cards, expected 10")
    assert(article_titles(response.body) == (50...60).map { |index| "Article #{index}" },
      "page 3 rendered #{article_titles(response.body).inspect}")
    assert(response.body.include?("Page 3 of 3"), "page indicator missing for page 3")
    assert(response.body.include?("60 articles"), "the filtered total should still read 60 articles")
  end

  check "a page beyond the last page renders the last valid page" do
    response = request.get("/dashboard?page=4", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    assert(article_titles(response.body) == (50...60).map { |index| "Article #{index}" },
      "page 4 rendered #{article_titles(response.body).inspect} instead of the last page")
    assert(response.body.include?("Page 3 of 3"), "page 4 was not clamped to page 3")
  end

  check "a page below 1 renders the first page" do
    zero = request.get("/dashboard?page=0", auth)
    assert(article_titles(zero.body) == (0...25).map { |index| "Article #{index}" },
      "page 0 rendered #{article_titles(zero.body).inspect}")
    negative = request.get("/dashboard?page=-3", auth)
    assert(article_titles(negative.body) == (0...25).map { |index| "Article #{index}" },
      "page -3 rendered #{article_titles(negative.body).inspect}")
  end

  check "the page indicator reflects the filtered set" do
    response = request.get("/dashboard?topic=#{CGI.escape("AI & ML")}", auth)
    assert(response.body.include?("30 articles · AI &amp; ML"),
      "the filtered count should read 30 articles for the topic")
    assert(!response.body.include?("60 articles"), "the filtered count leaked the unfiltered total")
    assert(response.body.include?("Page 1 of 2"), "the page indicator should count the filtered pages")
  end

  check "a topic filter survives the page links" do
    response = request.get("/dashboard?topic=#{CGI.escape("AI & ML")}", auth)
    href = link_with_text(response.body, "2")
    assert(href, "no page 2 link rendered for the topic-filtered view")
    query = query_of(href)
    assert(query["topic"] == "AI & ML", "the page link dropped the topic filter: #{href}")
    assert(query["page"] == "2", "the page link does not target page 2: #{href}")

    followed = request.get(href, auth)
    assert(article_cards(followed.body).length == 5,
      "the filtered page 2 rendered #{article_cards(followed.body).length} cards, expected 5")
    assert(article_titles(followed.body) == (25...30).map { |index| "Article #{index}" },
      "the filtered page 2 rendered #{article_titles(followed.body).inspect}")
  end

  check "a date filter survives the page links" do
    response = request.get("/dashboard?date_from=2026-10-01", auth)
    assert(response.body.include?("40 articles"), "the date-filtered count should read 40 articles")
    href = link_with_text(response.body, "2")
    assert(href, "no page 2 link rendered for the date-filtered view")
    query = query_of(href)
    assert(query["date_from"] == "2026-10-01", "the page link dropped the date filter: #{href}")
    assert(query["page"] == "2", "the page link does not target page 2: #{href}")

    followed = request.get(href, auth)
    assert(article_cards(followed.body).length == 15,
      "the date-filtered page 2 rendered #{article_cards(followed.body).length} cards, expected 15")
  end

  check "changing a filter returns to the first page" do
    response = request.get("/dashboard?page=2&heading=#{CGI.escape("Computing methodologies")}", auth)
    href = filter_anchor(response.body, "Computer systems organization", "bar heading-caption")
    assert(href, "no heading link rendered for the other heading")
    assert(!query_of(href).key?("page"), "the heading link kept page=#{query_of(href)["page"]}")
    assert(query_of(href)["heading"] == "Computer systems organization",
      "the heading link lost its heading: #{href}")

    clear = link_with_text(response.body, "Clear filters")
    assert(clear, "clear filters link missing")
    assert(!query_of(clear).key?("page"), "clear filters kept page=#{query_of(clear)["page"]}")

    # Search, date and facet controls live in the filter form, which only
    # submits its own named controls, so a new filter can never carry a page.
    form = response.body[/<form id="filter-form".*?<\/form>/m].to_s
    assert(!form.empty?, "filter form missing")
    assert(!form.match?(/name="page"/), "the filter form submits a page parameter")
  end

  check "the first page renders a next link but no previous link" do
    body = request.get("/dashboard", auth).body
    assert(!body.match?(/href="[^"]*page=0/), "the first page links backwards to page 0")
    assert(!body.include?('rel="prev"'), "the first page still renders an active previous link")
    next_link = link_with_text(body, "Next")
    assert(next_link, "the first page renders no next link")
    assert(query_of(next_link)["page"] == "2", "the next link points at #{next_link}")
  end

  check "the last page renders a previous link but no next link" do
    body = request.get("/dashboard?page=3", auth).body
    assert(!body.match?(/href="[^"]*page=4/), "the last page links forwards to page 4")
    assert(!body.include?('rel="next"'), "the last page still renders an active next link")
    prev_link = link_with_text(body, "Previous")
    assert(prev_link, "the last page renders no previous link")
    assert(query_of(prev_link)["page"] == "2", "the previous link points at #{prev_link}")
  end

  check "GET /articles paginates a bare array and reports the counts in headers" do
    response = request.get("/articles?page=2&per_page=10", auth)
    assert(response.ok?, "expected HTTP 200, got #{response.status}")
    payload = JSON.parse(response.body)
    assert(payload.is_a?(Array), "the /articles body is no longer a bare JSON array")
    assert(payload.length == 10, "/articles returned #{payload.length} rows, expected 10")
    assert(payload.first["title"] == "Article 10", "page 2 starts at #{payload.first["title"].inspect}")
    assert(response["X-Total-Count"] == "60", "X-Total-Count was #{response["X-Total-Count"].inspect}")
    assert(response["X-Page-Count"] == "6", "X-Page-Count was #{response["X-Page-Count"].inspect}")
    assert(response["X-Page"] == "2", "X-Page was #{response["X-Page"].inspect}")
  end

  check "GET /articles keeps its default page size" do
    response = request.get("/articles", auth)
    payload = JSON.parse(response.body)
    assert(payload.length == 25, "/articles returned #{payload.length} rows by default, expected 25")
    assert(response["X-Page-Count"] == "3", "X-Page-Count was #{response["X-Page-Count"].inspect}")
    assert(response["X-Page"] == "1", "X-Page was #{response["X-Page"].inspect}")
  end

  check "GET /articles clamps per_page to 100" do
    response = request.get("/articles?per_page=500", auth)
    payload = JSON.parse(response.body)
    assert(payload.length == 60, "/articles returned #{payload.length} rows, expected the clamped 60")
    assert(response["X-Page-Count"] == "1", "X-Page-Count was #{response["X-Page-Count"].inspect}")
  end

  check "GET /articles falls back to the default page size for a zero or negative per_page" do
    zero = request.get("/articles?per_page=0", auth)
    assert(JSON.parse(zero.body).length == 25, "per_page=0 did not fall back to 25")
    negative = request.get("/articles?per_page=-5", auth)
    assert(JSON.parse(negative.body).length == 25, "per_page=-5 did not fall back to 25")
  end

  check "GET /articles clamps an out-of-range page" do
    beyond = request.get("/articles?page=99", auth)
    payload = JSON.parse(beyond.body)
    assert(beyond["X-Page"] == "3", "an out-of-range page reported X-Page=#{beyond["X-Page"].inspect}")
    assert(payload.length == 10, "an out-of-range page returned #{payload.length} rows, expected 10")
    below = request.get("/articles?page=0", auth)
    assert(below["X-Page"] == "1", "page 0 reported X-Page=#{below["X-Page"].inspect}")
  end
end
