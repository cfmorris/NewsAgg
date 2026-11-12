# The admin console landing page: who may open /admin, and what it shows.
# Driven through the real HTTP routes against a disposable sqlite database, so
# the guards and the numbers are exercised the way a browser exercises them.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

include TestReport

CONSOLE_DB_DIR = Dir.mktmpdir("newsagg-console-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(CONSOLE_DB_DIR) if File.directory?(CONSOLE_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(CONSOLE_DB_DIR, "console.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

PASSWORD = "correct horse battery"
JSON_HEADERS = { "HTTP_ACCEPT" => "application/json" }.freeze

# The first account on a fresh database is promoted to super_admin on create,
# so every seeded row gets its role applied after the row exists.
def account(email, role: :member, disabled: false)
  user = User.create!(email: email, password: PASSWORD)
  user.update!(role: role)
  user.update!(disabled_at: Time.current) if disabled
  user
end

def new_session
  Rack::Test::Session.new(Rails.application)
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

# Reads the rendered number out of a specific element, so a page that happens to
# contain the right digit somewhere else cannot pass the check.
def rendered_count(body, id)
  match = body.match(/id="#{Regexp.escape(id)}"[^>]*>\s*(\d+)\s*</)
  raise "the page has no ##{id}: #{body[0, 600]}" unless match
  match[1].to_i
end

def section_html(body, id)
  body[%r{<section[^>]*id="#{Regexp.escape(id)}".*?</section>}m]
end

# Exactly the population the console is asserted against: two members (one of
# them disabled), one admin and one super_admin.
SEED = {
  active_member: account("console-active-member@example.com"),
  disabled_member: account("console-disabled-member@example.com", disabled: true),
  admin: account("console-admin@example.com", role: :admin),
  super_admin: account("console-owner@example.com", role: :super_admin)
}.freeze

TestReport.run do
  check "a guest asking for /admin is sent to sign-in" do
    session = new_session
    session.get("/admin")

    assert session.last_response.status == 302, "expected a redirect, got #{session.last_response.status}"
    assert session.last_response.headers["Location"].to_s.include?("/users/sign_in"),
           "the guest was sent to #{session.last_response.headers['Location'].inspect}"
  end

  check "a member gets 403 from /admin in both formats" do
    session = signed_in_session(SEED[:active_member])

    session.get("/admin")
    assert session.last_response.status == 403, "expected 403 for HTML, got #{session.last_response.status}"
    assert session.last_response.body.include?("not permitted"), "the 403 carried no visible message"

    session.get("/admin", {}, JSON_HEADERS)
    assert session.last_response.status == 403, "expected 403 for JSON, got #{session.last_response.status}"
  end

  check "an admin sees the console with the stored role counts" do
    session = signed_in_session(SEED[:admin])
    session.get("/admin")

    assert session.last_response.status == 200, "the admin got #{session.last_response.status}"
    body = session.last_response.body

    assert rendered_count(body, "console-count-member") == 2,
           "member count was #{rendered_count(body, 'console-count-member')}, expected 2"
    assert rendered_count(body, "console-count-admin") == 1,
           "admin count was #{rendered_count(body, 'console-count-admin')}, expected 1"
    assert rendered_count(body, "console-count-super-admin") == 1,
           "super_admin count was #{rendered_count(body, 'console-count-super-admin')}, expected 1"
    assert rendered_count(body, "console-count-disabled") == 1,
           "disabled count was #{rendered_count(body, 'console-count-disabled')}, expected 1"
  end

  check "the console links into the user list and does not touch it" do
    session = signed_in_session(SEED[:admin])
    session.get("/admin")
    body = session.last_response.body

    assert body.include?('href="/admin/users"'), "the console does not link to /admin/users"

    session.get("/admin/users")
    assert session.last_response.status == 200, "the user list answered #{session.last_response.status}"
    assert session.last_response.body.include?(SEED[:disabled_member].email),
           "the user list no longer lists accounts"
  end

  check "a super_admin sees the same console" do
    session = signed_in_session(SEED[:super_admin])
    session.get("/admin")

    assert session.last_response.status == 200, "the super_admin got #{session.last_response.status}"
    assert rendered_count(session.last_response.body, "console-count-member") == 2,
           "the super_admin saw a different member count"
  end

  check "the Sources section is a labelled placeholder, not a dead link" do
    session = signed_in_session(SEED[:admin])
    session.get("/admin")
    body = session.last_response.body

    section = section_html(body, "console-sources")
    assert section, "the page has no sources section: #{body[0, 800]}"
    assert section.include?("Source management arrives with the source registry"),
           "the sources placeholder explains nothing: #{section}"
    assert section.include?("Not available yet"), "the sources section is not labelled as unavailable: #{section}"
    assert !section.include?("<a "), "the sources section is a link: #{section}"
    assert !body.include?("/admin/sources"), "the page points at a route that does not exist"
  end
end
