# Sign-in for an account with MFA on, exercised through the real HTTP routes
# against a disposable sqlite database. The password step must hand off to a
# six-digit code step; a correct code finishes the sign-in, a wrong one fails
# in place without charging the account a failed attempt, and an account with
# MFA off still signs in with one POST.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"
require_relative "../support/signed_in_probe"

include TestReport
include SignedInProbe

MFA_DB_DIR = Dir.mktmpdir("newsagg-mfa-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(MFA_DB_DIR) if File.directory?(MFA_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(MFA_DB_DIR, "mfa.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

Rails.application.config.x.archive_factory = -> { FakeArchive.new([]) }

PASSWORD = "correct horse battery"
MAXIMUM_ATTEMPTS = Devise.maximum_attempts

def new_session
  Rack::Test::Session.new(Rails.application)
end

# An account that already finished enrolment: a secret is stored and MFA is on.
def mfa_account(email, password: PASSWORD)
  user = User.create!(email: email, password: password)
  user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
  user
end

def account(email, password: PASSWORD)
  User.create!(email: email, password: password)
end

# Step one: the password form.
def post_password(session, email, password, embedded: false)
  params = { user: { email: email, password: password } }
  params[:embedded] = "1" if embedded
  session.post("/users/sign_in", params)
end

# Step two: the code form.
def post_code(session, code, embedded: false)
  params = { user: { otp_attempt: code } }
  params[:embedded] = "1" if embedded
  session.post("/users/sign_in/two_factor", params)
end

def top_bar_present?(body)
  body.match?(/class="topbar"/) || body.include?("topbar-account")
end

TestReport.run do
  check "the password step asks an MFA account for a code instead of signing it in" do
    user = mfa_account("mfa-step-one@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)

    response = session.last_response
    assert(response.status == 200,
           "the password step answered #{response.status} instead of the code form")
    body = response.body
    assert(body.include?('name="user[otp_attempt]"'), "the code form has no otp_attempt field")
    assert(body.include?('/users/sign_in/two_factor'), "the code form does not post to the challenge route")
    assert(body.include?("six-digit code"), "the challenge never mentions the six-digit code")
    assert(!signed_in?(session), "the password step signed an MFA account in without a code")
  end

  check "a valid TOTP code completes the sign-in" do
    user = mfa_account("mfa-valid@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)
    post_code(session, user.current_otp)

    response = session.last_response
    assert(response.status == 302, "the code step answered #{response.status} instead of a redirect")
    assert(response["Location"].to_s.end_with?("/dashboard"),
           "the code step sent the reader to #{response['Location']}")

    # The code step completes the sign-in in the app's own controller, so this
    # is where a leftover welcome notice would show: the dashboard must not
    # carry one. Follow the redirect before probing the session, so the probe's
    # own request cannot replace the page this check is about.
    session.follow_redirect!
    assert(session.last_response.status == 200,
           "the dashboard answered #{session.last_response.status} after the code step")
    assert(!session.last_response.body.include?("successfully"),
           "the code step landed on the dashboard with a welcome notice")
    assert(!session.last_response.body.include?("Welcome!"),
           "the code step landed on the dashboard with a welcome notice")

    assert(signed_in?(session), "a valid code did not establish a session")

    session.get("/dashboard")
    assert(session.last_response.status == 200,
           "the dashboard answered #{session.last_response.status} after signing in")
    assert(user.reload.sign_in_count.positive?, "trackable did not record the sign-in")
    assert(user.failed_attempts.zero?, "a successful sign-in left #{user.failed_attempts} failed attempts")
    assert(user.current_sign_in_at.present?, "trackable did not record the sign-in time")
  end

  check "a wrong code fails the challenge and leaves the account unlocked" do
    user = mfa_account("mfa-wrong@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)
    post_code(session, "000000")

    response = session.last_response
    assert(response.status == 422, "a wrong code answered #{response.status} instead of the challenge")
    body = response.body
    assert(body.include?("That code did not work"), "the challenge showed no failure message")
    assert(body.include?('name="user[otp_attempt]"'), "the failed challenge lost its code field")
    assert(!signed_in?(session), "a wrong code established a session")

    user.reload
    assert(!user.access_locked?, "a wrong code locked the account")
    assert(user.failed_attempts.zero?, "a wrong code was charged #{user.failed_attempts} failed attempts")
  end

  check "the challenge can be retried with the right code after a wrong one" do
    user = mfa_account("mfa-retry@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)
    post_code(session, "123456")
    assert(!signed_in?(session), "the wrong code signed the reader in")

    post_code(session, user.current_otp)
    assert(session.last_response.status == 302,
           "the retry answered #{session.last_response.status}")
    assert(signed_in?(session), "the retry with the right code did not establish a session")
  end

  check "repeated wrong codes never lock the account" do
    user = mfa_account("mfa-guesses@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)

    (MAXIMUM_ATTEMPTS + 5).times do |attempt|
      post_code(session, format("%06d", attempt % 100))
      assert(session.last_response.status == 422,
             "guess #{attempt + 1} answered #{session.last_response.status}")
    end

    user.reload
    assert(!user.access_locked?, "guessing at the code locked the account")
    assert(user.failed_attempts.zero?,
           "guessing at the code charged #{user.failed_attempts} failed attempts")
    assert(user.locked_at.nil?, "guessing at the code set locked_at")
  end

  check "the password step cannot be skipped" do
    user = mfa_account("mfa-skip@example.com")
    session = new_session
    post_code(session, user.current_otp)

    assert(session.last_response.status == 302,
           "a code posted without the password step answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.include?("/users/sign_in"),
           "a code without the password step went to #{session.last_response['Location']}")
    assert(!signed_in?(session), "a code posted without the password step established a session")
  end

  check "a wrong password for an MFA account fails before the challenge" do
    user = mfa_account("mfa-wrongpass@example.com")
    session = new_session
    post_password(session, user.email, "not the password")

    body = session.last_response.body
    assert(body.include?("Invalid"), "the failed password showed no invalid-credentials message")
    assert(!body.include?('name="user[otp_attempt]"'),
           "a wrong password still reached the code step")
    assert(!signed_in?(session), "a wrong password established a session")
  end

  check "the challenge stays inside the sign-in overlay" do
    user = mfa_account("mfa-overlay@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD, embedded: true)

    response = session.last_response
    assert(response.status == 200, "the embedded password step answered #{response.status}")
    body = response.body
    assert(!top_bar_present?(body), "the embedded challenge fell back to the full page chrome")
    assert(body.include?('class="auth-card"'), "the embedded challenge renders no compact card")
    assert(body.include?('name="embedded"'), "the challenge form dropped the overlay marker")

    post_code(session, "000000", embedded: true)
    body = session.last_response.body
    assert(body.include?('class="auth-card"'), "the failed embedded challenge left the overlay")
    assert(body.include?('data-turbo="false"'), "the embedded challenge form is still submitted by Turbo")

    post_code(session, user.current_otp, embedded: true)
    assert(session.last_response.status == 302,
           "the embedded code step answered #{session.last_response.status}")
  end

  check "a wrong password is charged one failed attempt, not two" do
    user = account("single-factor-wrong@example.com")
    session = new_session
    post_password(session, user.email, "not the password")

    assert(!signed_in?(session), "a wrong password established a session")
    assert(user.reload.failed_attempts == 1,
           "a wrong password was charged #{user.failed_attempts} failed attempts")
  end

  check "an account with MFA off still signs in with one POST" do
    user = account("single-factor@example.com")
    session = new_session
    post_password(session, user.email, PASSWORD)

    assert(session.last_response.status == 302,
           "a single-factor sign-in answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
           "a single-factor sign-in went to #{session.last_response['Location']}")
    assert(signed_in?(session), "a single-factor sign-in did not establish a session")
    assert(user.reload.sign_in_count.positive?, "trackable did not record the sign-in")
  end

  check "a locked account is refused, not offered the code" do
    user = mfa_account("mfa-locked@example.com")
    user.update!(failed_attempts: MAXIMUM_ATTEMPTS, locked_at: Time.current)

    session = new_session
    post_password(session, user.email, PASSWORD)

    body = session.last_response.body
    assert(!body.include?('name="user[otp_attempt]"'), "a locked account was offered the code step")
    assert(!signed_in?(session), "a locked account was signed in")
  end

  check "a disabled account is refused, not offered the code" do
    user = mfa_account("mfa-disabled@example.com")
    user.update!(disabled_at: Time.current)

    session = new_session
    post_password(session, user.email, PASSWORD)

    body = session.last_response.body
    assert(!body.include?('name="user[otp_attempt]"'), "a disabled account was offered the code step")
    assert(!signed_in?(session), "a disabled account was signed in")
  end
end
