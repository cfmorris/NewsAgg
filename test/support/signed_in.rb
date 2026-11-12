# A disposable sqlite database plus a sign-in helper for integration tests that
# drive Rack::MockRequest: the app now requires a session, so the dashboard and
# infographic suites need a cookie the same way a reader would.
require "fileutils"
require "rack/test"
require "tmpdir"

TEST_DB_DIR = Dir.mktmpdir("newsagg-support-db-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(TEST_DB_DIR) if File.directory?(TEST_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(TEST_DB_DIR, "support.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

TEST_ACCOUNT_PASSWORD = "correct horse battery"

# Every cookie a response set, flattened into one Cookie request header.
def cookie_header(response)
  response["Set-Cookie"].to_s.split("\n").filter_map do |line|
    pair = line.split(";").first
    pair if pair&.include?("=")
  end.join("; ")
end

# Signs a reader in through the real sign-in route and returns the Cookie header
# the following requests must carry. The form is loaded first, exactly as a
# browser does before it submits.
def sign_in_cookie(email = nil)
  email ||= "reader-#{SecureRandom.hex(4)}@example.com"
  user = User.find_by(email: email) || User.create!(email: email, password: TEST_ACCOUNT_PASSWORD)

  session = Rack::Test::Session.new(Rails.application)
  session.get("/users/sign_in")
  session.post("/users/sign_in", user: { email: user.email, password: TEST_ACCOUNT_PASSWORD })
  unless session.last_response.status == 302 && session.last_response["Location"].to_s.end_with?("/dashboard")
    raise "sign-in as #{email} answered #{session.last_response.status} #{session.last_response['Location']}"
  end

  cookie_header(session.last_response)
end
