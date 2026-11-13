# The global top bar and its account area, exercised through the real HTTP
# routes against a disposable sqlite database. The bar sits in the layout, so
# every screen carries it: the product title on the left, the account menu on
# the right, in both signed-out and signed-in states.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"

include TestReport

TOPBAR_DB_DIR = Dir.mktmpdir("newsagg-topbar-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(TOPBAR_DB_DIR) if File.directory?(TOPBAR_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(TOPBAR_DB_DIR, "topbar.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

# Both account-area routes (/account and /admin) ship with the app now, so the
# bar is checked against the real helpers rather than a stub.

rows = [{
  "title" => "A headline for the bar", "summary" => "Archive content.",
  "url" => "https://example.test/bar", "publisher" => "Fixture Press",
  "depth" => "Overview", "topics" => [], "sources" => ["Hacker News"],
  "discoveries" => [], "topic_mappings" => [], "published_date" => nil,
  "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00"
}]
Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

PASSWORD = "correct horse battery"

def new_session
  Rack::Test::Session.new(Rails.application)
end

# The first account on a fresh database is promoted to super_admin on create, so
# each role is applied after the row exists.
def account(email, role: :member)
  user = User.create!(email: email, password: PASSWORD)
  user.update!(role: role)
  user
end

def signed_in_session(user)
  session = new_session
  session.get("/users/sign_in")
  session.post("/users/sign_in", user: { email: user.email, password: PASSWORD })
  unless session.last_response.status == 302
    raise "sign-in as #{user.email} answered #{session.last_response.status}"
  end
  session
end

def link_to_path(body, path)
  body[/<a [^>]*href="#{Regexp.escape(path)}"[^>]*>.*?<\/a>/m]
end

# The account area, isolated so assertions about the menu cannot be satisfied by
# a landing-page link elsewhere in the body.
def account_area(body)
  body[%r{<(?:nav|div|section)[^>]*class="[^"]*topbar-account[^"]*"[^>]*>.*?</(?:nav|div|section)>}m]
end

TestReport.run do
  check "the top bar names the product and links home" do
    session = new_session
    session.get("/")

    body = session.last_response.body
    title_link = body[/<a [^>]*class="[^"]*topbar-title[^"]*"[^>]*>.*?<\/a>/m]
    assert(title_link, "the page carries no top bar title link")
    assert(title_link.include?("NewsAgg: Your media aggregator"),
           "the top bar title is not the product name: #{title_link}")
    assert(title_link.include?('href="/"'), "the top bar title does not link home: #{title_link}")
  end

  check "a signed-out visitor gets Sign in and Create account and no account email" do
    session = new_session
    session.get("/")

    body = session.last_response.body
    area = account_area(body)
    assert(area, "the top bar has no account area")
    assert(area.include?("Sign in"), "the account area offers no sign-in link: #{area}")
    assert(link_to_path(area, "/users/sign_in"), "the sign-in link does not target the sign-in route")
    assert(area.include?("Create account"), "the account area offers no create-account link: #{area}")
    assert(link_to_path(area, "/users/sign_up"),
           "the create-account link does not target the registration route")
    assert(!area.match?(/[\w.+-]+@[\w-]+\.[\w.]+/), "a signed-out visitor sees an email address: #{area}")
  end

  check "a signed-in member sees their email, role, Profile and Sign out but no admin console" do
    user = account("member@example.com", role: :member)
    session = signed_in_session(user)
    session.get("/dashboard")

    body = session.last_response.body
    area = account_area(body)
    assert(area, "the top bar has no account area")
    assert(area.include?("member@example.com"), "the account area does not show the email: #{area}")
    assert(area.include?("member"), "the account area does not show the member role: #{area}")
    assert(link_to_path(area, "/account"), "the account area offers no Profile link: #{area}")
    assert(area.include?("Profile"), "the Profile link is not labelled 'Profile'")
    assert(area.include?("Sign out"), "the account area offers no sign-out control")

    sign_out_form = area[/<form[^>]*action="\/users\/sign_out"[^>]*>.*?<\/form>/m]
    assert(sign_out_form, "sign out is not a form posting to the sign-out route: #{area}")
    assert(sign_out_form.match?(/name="_method"[^>]*value="delete"/) ||
           sign_out_form.match?(/value="delete"[^>]*name="_method"/),
           "sign out is not submitted as a DELETE: #{sign_out_form}")
    assert(!area.include?("Admin console"), "a member is offered the admin console: #{area}")
  end

  check "admins and super admins are offered the admin console" do
    { admin: "admin@example.com", super_admin: "root@example.com" }.each do |role, email|
      user = account(email, role: role)
      session = signed_in_session(user)
      session.get("/dashboard")

      area = account_area(session.last_response.body)
      assert(area, "the top bar has no account area for #{role}")
      label = role == :super_admin ? "super admin" : "admin"
      assert(area.include?(">#{label}<") || area.include?(label),
             "the account area does not show the #{label} role: #{area}")
      assert(link_to_path(area, "/admin"), "the #{role} is not offered the admin console: #{area}")
      assert(area.include?("Admin console"), "the admin link is not labelled 'Admin console'")
    end
  end

  check "the dashboard carries the product title exactly once" do
    user = account("single-title@example.com")
    session = signed_in_session(user)
    session.get("/dashboard")

    # The document <title> repeats the product name by design; the rendered page
    # itself must carry it once - in the top bar, not again as a page heading.
    page_body = session.last_response.body[%r{<body[^>]*>(.*)</body>}m, 1].to_s
    occurrences = page_body.scan("Your media aggregator").length
    assert(occurrences == 1, "expected one copy of the product title in the page, found #{occurrences}")
    assert(!page_body.match?(%r{<h1[^>]*>[^<]*Your media aggregator}), "the dashboard still repeats the title as a heading")
  end

  check "the top bar does not break the Devise sign-in form" do
    user = account("form-reader@example.com")
    session = new_session
    session.get("/users/sign_in")
    # A direct visit is allowed to hand the guest to the card on the landing
    # page; what matters here is the page it ends on, which still carries the
    # top bar and still signs the reader in through the same form.
    session.follow_redirect! if session.last_response.redirect?

    page = session.last_response
    assert(page.status == 200, "GET /users/sign_in answered #{page.status}")
    assert(account_area(page.body), "the sign-in page carries no top bar account area")

    session.post("/users/sign_in", user: { email: user.email, password: PASSWORD })
    assert(session.last_response.status == 302,
           "signing in through the form answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
           "sign-in sent the reader to #{session.last_response['Location']}")
  end

  check "a failed sign-in still re-renders the form inside the layout" do
    user = account("wrong-password@example.com")
    session = new_session
    session.get("/users/sign_in")
    session.follow_redirect! if session.last_response.redirect?
    session.post("/users/sign_in", user: { email: user.email, password: "not the password" })

    assert(session.last_response.status == 200, "a failed sign-in answered #{session.last_response.status}")
    body = session.last_response.body
    assert(body.include?('action="/users/sign_in"'), "the re-rendered page has no sign-in form")
    assert(account_area(body), "the re-rendered sign-in page carries no top bar account area")
  end
end
