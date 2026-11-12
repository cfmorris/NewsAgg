# The public landing page and the sign-in gate, exercised through the real HTTP
# routes against a disposable sqlite database. A guest must reach the landing
# page (and the Devise screens) and nothing else; a signed-in reader reaches
# every screen the app shipped before this change.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "json"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"

include TestReport

GATE_DB_DIR = Dir.mktmpdir("newsagg-gate-")
GATE_FLAG_DIR = Dir.mktmpdir("newsagg-gate-flag-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(GATE_DB_DIR) if File.directory?(GATE_DB_DIR)
    FileUtils.remove_entry(GATE_FLAG_DIR) if File.directory?(GATE_FLAG_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(GATE_DB_DIR, "gate.sqlite3"))
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

PASSWORD = "correct horse battery"

def article(overrides)
  {
    "title" => "Untitled", "summary" => "", "publisher" => "Fixture Press",
    "depth" => "Overview", "topics" => [], "sources" => ["Hacker News"],
    "discoveries" => [], "topic_mappings" => [], "published_date" => nil,
    "archive_date" => "2026-11-11", "archive_timestamp" => "2026-11-11T12:00:00-05:00"
  }.merge(overrides)
end

private_title = "A headline only signed-in readers may see"
rows = [article("title" => private_title, "summary" => "Archive content.", "url" => "https://example.test/private")]
Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }

previous_flag_path = Rails.application.config.x.auto_pull_flag_path
Rails.application.config.x.auto_pull_flag_path = File.join(GATE_FLAG_DIR, "auto-pull.enabled")
at_exit do
  Rails.application.config.x.auto_pull_flag_path = previous_flag_path
end

def new_session
  Rack::Test::Session.new(Rails.application)
end

def account(email, password: PASSWORD)
  User.create!(email: email, password: password)
end

def sign_in(session, user, password: PASSWORD)
  session.get("/users/sign_in")
  session.post("/users/sign_in", user: { email: user.email, password: password })
end

def signed_in_session(user)
  session = new_session
  sign_in(session, user)
  session
end

def redirected_to_sign_in?(session, response)
  response.status == 302 && response["Location"].to_s.include?("/users/sign_in")
end

def json_response?(response)
  response["content-type"].to_s.include?("application/json")
end

TestReport.run do
  check "a guest sees the landing page with both ways in and no archive content" do
    session = new_session
    session.get("/")

    assert(session.last_response.status == 200, "expected HTTP 200, got #{session.last_response.status}")
    body = session.last_response.body
    sign_in_link = body[/<a [^>]*href="\/users\/sign_in"[^>]*>.*?<\/a>/m]
    sign_up_link = body[/<a [^>]*href="\/users\/sign_up"[^>]*>.*?<\/a>/m]
    assert(sign_in_link, "the landing page offers no sign-in link")
    assert(sign_up_link, "the landing page offers no create-account link")
    assert(sign_in_link.include?("Sign in"), "the sign-in link is not labelled 'Sign in': #{sign_in_link}")
    assert(sign_up_link.include?("Create account"),
           "the create-account link is not labelled 'Create account': #{sign_up_link}")
    assert(!body.include?(private_title), "the landing page rendered archive content")
  end

  check "the landing page names the product and describes it in one sentence" do
    session = new_session
    session.get("/")

    body = session.last_response.body
    assert(body.include?("NewsAgg"), "the landing page does not name the product")
    assert(body.match?(%r{<h1[^>]*>}), "the landing page has no heading")
    assert(body.include?('href="/dashboard.css"'), "the landing page does not load the stylesheet")
    assert(body.include?("Browse the archive"), "the landing page carries no description")
  end

  check "a signed-in reader sees a single way through to the dashboard" do
    user = account("landing-reader@example.com")
    session = signed_in_session(user)
    session.get("/")

    body = session.last_response.body
    assert(session.last_response.status == 200, "expected HTTP 200, got #{session.last_response.status}")
    assert(body.include?('href="/dashboard"'), "the landing page offers no dashboard link to a signed-in reader")
    assert(body.include?("Go to dashboard"), "the dashboard link is not labelled 'Go to dashboard'")
    assert(!body.include?('href="/users/sign_up"'), "a signed-in reader is still offered create-account")
  end

  check "the landing page renders when the archive is unavailable" do
    Rails.application.config.x.archive_factory = -> { UnavailableArchive.new }
    session = new_session
    session.get("/")

    assert(session.last_response.status == 200,
           "expected HTTP 200 with a dead archive, got #{session.last_response.status}")
    assert(session.last_response.body.include?("Sign in"), "the landing page lost its sign-in action")
  ensure
    Rails.application.config.x.archive_factory = -> { FakeArchive.new(rows) }
  end

  check "a guest is sent to sign-in from the HTML screens" do
    session = new_session
    ["/dashboard", "/infographic"].each do |path|
      session.get(path)
      assert(redirected_to_sign_in?(session, session.last_response),
             "guest GET #{path} answered #{session.last_response.status} #{session.last_response['Location']}")
    end
  end

  check "a guest gets 401 JSON, not a redirect, from the fetch endpoints" do
    session = new_session
    ["/articles", "/auto-pull", "/dashboard/stream"].each do |path|
      session.get(path)
      response = session.last_response
      assert(response.status == 401, "guest GET #{path} answered #{response.status}")
      assert(json_response?(response), "guest GET #{path} answered #{response['content-type'].inspect}, not JSON")
      assert(JSON.parse(response.body) == { "error" => "unauthorized" },
             "guest GET #{path} answered #{response.body.inspect}")
    end
  end

  check "a guest cannot switch auto-pull on" do
    flag = Rails.application.config.x.auto_pull_flag_path
    FileUtils.rm_f(flag)

    session = new_session
    session.put("/auto-pull", JSON.generate(enabled: true),
      { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "http://127.0.0.1:3000" })

    assert(session.last_response.status == 401, "guest PUT /auto-pull answered #{session.last_response.status}")
    assert(!File.exist?(flag), "a guest switched auto-pull on")
  end

  check "a signed-in reader reaches every screen" do
    user = account("gate-reader@example.com")
    session = signed_in_session(user)

    ["/dashboard", "/articles", "/infographic", "/auto-pull"].each do |path|
      session.get(path)
      assert(session.last_response.status == 200,
             "signed-in GET #{path} answered #{session.last_response.status}")
    end

    session.get("/dashboard")
    assert(session.last_response.body.include?(private_title), "the dashboard rendered no articles")
  end

  check "signing in lands on the dashboard" do
    user = account("arriving@example.com")
    session = new_session
    sign_in(session, user)

    assert(session.last_response.status == 302, "sign-in answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
           "sign-in redirected to #{session.last_response['Location']}")
  end

  check "a guest sent back from the dashboard returns there after signing in" do
    user = account("returning@example.com")
    session = new_session
    session.get("/dashboard?q=rails")
    assert(redirected_to_sign_in?(session, session.last_response), "the dashboard did not gate the guest")

    sign_in(session, user)
    assert(session.last_response["Location"].to_s.end_with?("/dashboard?q=rails"),
           "sign-in returned the reader to #{session.last_response['Location']}")
  end

  check "signing up lands on the dashboard as a member" do
    session = new_session
    session.post("/users", user: {
      email: "fresh@example.com", password: PASSWORD, password_confirmation: PASSWORD
    })

    assert(session.last_response.status == 302, "sign-up answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
           "sign-up redirected to #{session.last_response['Location']}")
  end

  check "the static asset routes stay public" do
    session = new_session
    ["/turbo.js", "/dashboard.js", "/dashboard.css"].each do |path|
      session.get(path)
      assert(session.last_response.status == 200, "guest GET #{path} answered #{session.last_response.status}")
    end
  end
end
