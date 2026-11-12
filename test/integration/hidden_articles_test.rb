ENV["RAILS_ENV"] = "test"

require "cgi"
require "json"
require "rack/mock"
require "rack/test"
require "uri"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"
require_relative "../support/signed_in"

include TestReport

# Hiding is account state, so these tests drive the two endpoints over HTTP with
# real sessions: a hide has to disappear from one reader's screens and stay put
# on another's.
def story(index, title = nil)
  {
    "title" => title || "Article #{index}",
    "url" => "https://example.com/story-#{index}",
    "summary" => "Summary for article #{index}.",
    "publisher" => "Fixture Press",
    "depth" => "Overview",
    "topics" => ["AI & ML"],
    "sources" => ["Hacker News"],
    "discoveries" => [],
    "topic_mappings" => [{ "heading" => "Computing methodologies", "topic" => "AI & ML" }],
    "published_date" => nil,
    "archive_date" => "2026-11-11",
    "archive_timestamp" => "2026-11-11T12:00:00-05:00"
  }
end

def article_titles(html)
  html.scan(%r{<h3[^>]*>.*?</h3>}m).filter_map { |heading| heading[/Article \d+/] }
end

def article_cards(html)
  html.scan(%r{<article>.*?</article>}m)
end

def card_for(html, title)
  article_cards(html).find { |card| card.include?(title) } ||
    raise("no article card rendered for #{title.inspect}")
end

# The text of the sidebar's Hidden entry, or nil when the entry is absent.
def hidden_entry_text(html)
  anchor = html[/<a [^>]*class="bar hidden-topic"[^>]*>.*?<\/a>/m]
  anchor && CGI.unescapeHTML(anchor.gsub(/<[^>]+>/, " ").split.join(" "))
end

# A JSON write against the hide endpoints, which default to answering a fetch()
# caller rather than a browser form.
def json_post(request, path, cookie, method: :post, url:)
  options = {
    "HTTP_COOKIE" => cookie,
    "HTTP_HOST" => "127.0.0.1:3000",
    "CONTENT_TYPE" => "application/json",
    "HTTP_ACCEPT" => "application/json",
    input: JSON.generate(url: url)
  }
  method == :delete ? request.delete(path, options) : request.post(path, options)
end

def json_rows(response)
  JSON.parse(response.body)
end

alice_email = "alice-#{SecureRandom.hex(3)}@example.com"
bob_email = "bob-#{SecureRandom.hex(3)}@example.com"
alice = sign_in_cookie(alice_email)
bob = sign_in_cookie(bob_email)
alice_id = User.find_by!(email: alice_email).id
bob_id = User.find_by!(email: bob_email).id

rows = (0...4).map { |index| story(index) }

request = Rack::MockRequest.new(Rails.application)
host = { "HTTP_HOST" => "127.0.0.1:3000" }
alice_request = host.merge("HTTP_COOKIE" => alice)
bob_request = host.merge("HTTP_COOKIE" => bob)

Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

TestReport.run do
  check "a user hides an article and it leaves their dashboard and /articles" do
    response = json_post(request, "/articles/hide", alice, url: story(0)["url"])
    assert(response.status == 200, "hide answered #{response.status}, expected 200")
    payload = json_rows(response)
    assert(payload["hidden"] == true, "hide answered #{payload.inspect}, expected hidden true")

    dashboard = request.get("/dashboard", alice_request)
    assert(dashboard.ok?, "expected HTTP 200, got #{dashboard.status}")
    assert(!dashboard.body.include?("Article 0"), "the hidden article is still on the dashboard")
    assert(dashboard.body.include?("Article 1"), "the other articles disappeared too")

    articles = request.get("/articles", alice_request)
    urls = json_rows(articles).map { |row| row["url"] }
    assert(!urls.include?(story(0)["url"]), "/articles still returns the hidden article")
    assert(urls.include?(story(1)["url"]), "/articles dropped an article that is not hidden")
  end

  check "the Hidden topic lists the hidden article with an unhide control" do
    dashboard = request.get("/dashboard", alice_request)
    entry = hidden_entry_text(dashboard.body)
    assert(entry, "the topics sidebar has no Hidden entry")
    assert(entry.include?("Hidden") && entry.include?("1"),
      "the Hidden entry reads #{entry.inspect}, expected the count 1")

    hidden_view = request.get("/dashboard?view=hidden", alice_request)
    assert(hidden_view.ok?, "the Hidden view answered #{hidden_view.status}")
    assert(article_titles(hidden_view.body) == ["Article 0"],
      "the Hidden view rendered #{article_titles(hidden_view.body).inspect}")
    assert(card_for(hidden_view.body, "Article 0").include?("Unhide"),
      "the Hidden view does not offer an unhide control")
  end

  check "another account still sees the same article" do
    dashboard = request.get("/dashboard", bob_request)
    assert(article_titles(dashboard.body).include?("Article 0"),
      "the article vanished for an account that never hid it")
    urls = json_rows(request.get("/articles", bob_request)).map { |row| row["url"] }
    assert(urls.include?(story(0)["url"]), "/articles excluded the article for the wrong account")
    assert(hidden_entry_text(dashboard.body).nil?,
      "another account's sidebar shows a Hidden entry it never filled")
  end

  check "hiding the same article twice leaves exactly one row" do
    again = json_post(request, "/articles/hide", alice, url: story(0)["url"])
    assert(again.status == 200, "the second hide answered #{again.status}, expected 200")
    count = HiddenArticle.where(user_id: alice_id, article_url: story(0)["url"]).count
    assert(count == 1, "the second hide left #{count} rows, expected 1")
  end

  check "unhiding an article that was never hidden is a no-op success" do
    response = json_post(request, "/articles/hide", alice, method: :delete, url: story(3)["url"])
    assert(response.status == 200, "unhide answered #{response.status}, expected 200")
    assert(json_rows(response)["hidden"] == false, "unhide did not report hidden false")
    count = HiddenArticle.where(user_id: alice_id, article_url: story(3)["url"]).count
    assert(count.zero?, "unhiding something never hidden wrote #{count} rows")
  end

  check "a guest's JSON hide is refused with 401 and writes nothing" do
    response = request.post("/articles/hide",
      host.merge("CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json",
        input: JSON.generate(url: story(2)["url"])))
    assert(response.status == 401, "a guest's JSON hide answered #{response.status}, expected 401")
    assert(HiddenArticle.where(article_url: story(2)["url"]).count.zero?,
      "a guest's hide wrote a row")
  end

  check "a guest's HTML hide is redirected to sign-in and writes nothing" do
    response = request.post("/articles/hide",
      host.merge("CONTENT_TYPE" => "application/x-www-form-urlencoded",
        input: URI.encode_www_form(url: story(2)["url"])))
    assert(response.status == 302, "a guest's form hide answered #{response.status}, expected 302")
    assert(response["Location"].to_s.include?("/users/sign_in"),
      "a guest's form hide redirected to #{response['Location'].inspect}")
    assert(HiddenArticle.where(article_url: story(2)["url"]).count.zero?,
      "a guest's form hide wrote a row")
  end

  check "the hide button redirects back to the current view with a flash" do
    session = Rack::Test::Session.new(Rails.application)
    session.get("/users/sign_in", {}, host)
    session.post("/users/sign_in",
      { user: { email: alice_email, password: TEST_ACCOUNT_PASSWORD } }, host)
    assert(session.last_response.status == 302, "sign-in failed in the session flow")

    session.post("/articles/hide", { url: story(2)["url"] },
      host.merge("HTTP_REFERER" => "http://127.0.0.1:3000/dashboard"))
    assert(session.last_response.status == 302,
      "the form hide answered #{session.last_response.status}, expected 302")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
      "the form hide redirected to #{session.last_response['Location'].inspect}")

    session.follow_redirect!
    assert(session.last_response.body.include?("Article hidden"),
      "the redirected dashboard carries no hide flash")
    assert(!session.last_response.body.include?("Article 2"),
      "the article is still listed after the form hide")

    session.delete("/articles/hide", { url: story(2)["url"] },
      host.merge("HTTP_REFERER" => "http://127.0.0.1:3000/dashboard"))
    assert(session.last_response.status == 302, "the form unhide did not redirect")
  end

  check "unhide restores the article and clears the Hidden topic when empty" do
    response = json_post(request, "/articles/hide", alice, method: :delete, url: story(0)["url"])
    assert(response.status == 200, "unhide answered #{response.status}, expected 200")
    assert(json_rows(response)["hidden"] == false, "unhide did not report hidden false")

    dashboard = request.get("/dashboard", alice_request)
    assert(article_titles(dashboard.body).include?("Article 0"),
      "the unhidden article did not come back to the dashboard")
    assert(hidden_entry_text(dashboard.body).nil?,
      "the Hidden topic entry survived the last unhide")

    urls = json_rows(request.get("/articles", alice_request)).map { |row| row["url"] }
    assert(urls.include?(story(0)["url"]), "the unhidden article is still missing from /articles")
    assert(HiddenArticle.where(user_id: alice_id).count.zero?, "unhide left a row behind")
  end

  check "an empty Hidden view explains how articles get there" do
    hidden_view = request.get("/dashboard?view=hidden", alice_request)
    assert(hidden_view.ok?, "the empty Hidden view answered #{hidden_view.status}")
    assert(!hidden_view.body.include?("Article 0"), "the empty Hidden view lists an article")
    assert(hidden_view.body.include?("Nothing hidden"),
      "the empty Hidden view does not explain how articles get there")
  end

  check "a hide survives a brand new request and session" do
    json_post(request, "/articles/hide", alice, url: story(1)["url"])
    fresh_cookie = sign_in_cookie(alice_email)
    fresh = Rack::MockRequest.new(Rails.application)
    dashboard = fresh.get("/dashboard", host.merge("HTTP_COOKIE" => fresh_cookie))
    assert(!dashboard.body.include?("Article 1"),
      "the hidden article came back on a fresh request")
    urls = json_rows(fresh.get("/articles", host.merge("HTTP_COOKIE" => fresh_cookie))).map { |row| row["url"] }
    assert(!urls.include?(story(1)["url"]), "/articles returned the hidden article to a fresh session")
    assert(HiddenArticle.where(user_id: alice_id).count == 1,
      "the hide is not one row scoped to the account that made it")
    assert(HiddenArticle.where(user_id: bob_id).count.zero?, "another account gained a hide row")
  end

  check "hidden articles are excluded before the pagination counts are computed" do
    carol_email = "carol-#{SecureRandom.hex(3)}@example.com"
    carol = sign_in_cookie(carol_email)
    carol_request = host.merge("HTTP_COOKIE" => carol)
    many = (100...126).map { |index| story(index) }
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(many) }

    json_post(request, "/articles/hide", carol, url: story(100)["url"])
    response = request.get("/articles", carol_request)
    assert(response["X-Total-Count"] == "25",
      "X-Total-Count was #{response['X-Total-Count'].inspect}, expected 25 after one hide")
    assert(response["X-Page-Count"] == "1",
      "X-Page-Count was #{response['X-Page-Count'].inspect}, expected 1")
    assert(json_rows(response).length == 25, "/articles returned #{json_rows(response).length} rows")

    dashboard = request.get("/dashboard", carol_request)
    assert(dashboard.body.include?("25 articles"), "the dashboard count still includes the hidden article")

    with_hidden = request.get("/articles?include_hidden=1&per_page=100", carol_request)
    urls = json_rows(with_hidden).map { |row| row["url"] }
    assert(urls.include?(story(100)["url"]), "?include_hidden=1 did not return the hidden article")
    assert(urls.length == 26, "?include_hidden=1 returned #{urls.length} rows, expected 26")
  end
end
