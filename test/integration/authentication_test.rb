# Signs up, signs in, signs out and resets a password through the real HTTP
# routes, against a disposable sqlite database so the development store is
# never touched.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/signed_in_probe"

include TestReport
include SignedInProbe

AUTH_DB_DIR = Dir.mktmpdir("newsagg-auth-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(AUTH_DB_DIR) if File.directory?(AUTH_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(AUTH_DB_DIR, "auth.sqlite3"))
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

def new_session
  Rack::Test::Session.new(Rails.application)
end

def sign_up(session, email, password: "correct horse battery")
  session.post("/users", user: { email: email, password: password, password_confirmation: password })
end

def sign_in(session, email, password)
  session.post("/users/sign_in", user: { email: email, password: password })
end

TestReport.run do
  check "signup creates a user and signs them in" do
    session = new_session
    sign_up(session, "newcomer@example.com")

    assert User.count == 1, "expected one user, found #{User.count}"
    assert User.find_by(email: "newcomer@example.com"), "the signed-up user was not stored"
    assert signed_in?(session), "signup did not establish a session"
  end

  check "sign-in succeeds with a valid password" do
    user = User.create!(email: "reader@example.com", password: "correct horse battery")

    session = new_session
    sign_in(session, user.email, "correct horse battery")

    assert signed_in?(session), "a valid password did not sign the user in"
    assert user.reload.sign_in_count.positive?, "trackable did not record the sign-in"
  end

  check "sign-in fails with a wrong password" do
    user = User.create!(email: "wrongpass@example.com", password: "correct horse battery")

    session = new_session
    sign_in(session, user.email, "not the password")

    assert session.last_response.status == 200, "expected the sign-in form, got #{session.last_response.status}"
    assert session.last_response.body.include?("Invalid"), "no invalid-credentials message was rendered"
    assert !signed_in?(session), "a wrong password still established a session"
  end

  check "sign-out ends the session" do
    user = User.create!(email: "leaver@example.com", password: "correct horse battery")

    session = new_session
    sign_in(session, user.email, "correct horse battery")
    assert signed_in?(session), "could not sign in before signing out"

    session.delete("/users/sign_out")

    assert session.last_response.status == 302, "sign-out should redirect, got #{session.last_response.status}"

    # Signing out is silent too: no "Signed out successfully." banner.
    session.follow_redirect!
    assert !session.last_response.body.include?("successfully"),
           "signing out still shows a notice"
    assert !signed_in?(session), "the session survived sign-out"
  end

  check "password reset sends reset instructions through the test delivery" do
    user = User.create!(email: "forgetful@example.com", password: "correct horse battery")

    ActionMailer::Base.deliveries.clear
    session = new_session
    session.post("/users/password", user: { email: user.email })

    assert ActionMailer::Base.deliveries.any?, "no reset mail was delivered"
    mail = ActionMailer::Base.deliveries.last
    assert mail.to == [user.email], "reset mail went to #{mail.to.inspect}"
    assert mail.body.to_s.include?("reset"), "reset mail carried no reset instructions"
    assert user.reload.reset_password_token.present?, "no reset token was stored"
  end

  check "a user who does not require OTP signs in without an OTP step" do
    user = User.create!(email: "single-step@example.com", password: "correct horse battery")
    assert user.otp_required_for_login == false, "MFA defaulted on for a new user"

    session = new_session
    sign_in(session, user.email, "correct horse battery")
    sign_in_body = session.last_response.body.to_s

    assert signed_in?(session), "an MFA-free user was not signed in"
    assert !sign_in_body.include?("one-time password"),
           "a user with MFA off was asked for an OTP"
  end

  check "duplicate email is rejected" do
    first = User.create!(email: "twin@example.com", password: "correct horse battery")
    assert first.persisted?, "the first user could not be created"

    session = new_session
    sign_up(session, "twin@example.com")

    assert User.where(email: "twin@example.com").count == 1, "a duplicate email created a second user"
    assert session.last_response.status == 200, "expected the sign-up form back, got #{session.last_response.status}"
  end

  check "the provider/uid index accepts several accounts without OAuth" do
    session = new_session
    sign_up(session, "plain-one@example.com")
    sign_up(session, "plain-two@example.com")

    assert User.where(provider: nil, uid: nil).count >= 2,
           "password-only accounts collided on the provider/uid index"
  end

  check "the provider/uid index still refuses duplicate OAuth identities" do
    User.create!(email: "oauth-one@example.com", password: "correct horse battery", provider: "github", uid: "42")
    duplicate = User.new(email: "oauth-two@example.com", password: "correct horse battery", provider: "github", uid: "42")

    raised = begin
      duplicate.save!
      false
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      true
    end

    assert raised, "a duplicate provider/uid pair was accepted"
  end
end
