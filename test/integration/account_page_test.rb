# The account page: a signed-in account reads its own profile and changes its
# email or password through it. Every request goes through the real HTTP routes
# against a disposable sqlite database, because what matters is that the
# Devise-backed update paths keep requiring the current password and never let
# a submitted role through.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "rotp"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"

include TestReport

ACCOUNT_DB_DIR = Dir.mktmpdir("newsagg-account-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(ACCOUNT_DB_DIR) if File.directory?(ACCOUNT_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(ACCOUNT_DB_DIR, "account.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

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

def sign_in(session, user, password: PASSWORD)
  session.get("/users/sign_in")
  session.post("/users/sign_in", user: { email: user.email, password: password })
end

def signed_in_session(user, password: PASSWORD)
  session = new_session
  sign_in(session, user, password: password)
  session
end

def signed_in?(session)
  # Devise bounces an authenticated visitor from the sign-in page, so a
  # redirect there proves the session still carries a user.
  session.get("/users/sign_in")
  session.last_response.status == 302
end

# One labelled value from the account summary, so a check can name exactly the
# figure it is asserting instead of matching any occurrence in the page.
def detail(body, id)
  body[%r{<dd[^>]*id="#{Regexp.escape(id)}"[^>]*>(.*?)</dd>}m, 1].to_s.gsub(/<[^>]*>/, "").strip
end

def form_for_path?(body, path)
  body.match?(%r{<form[^>]*action="#{Regexp.escape(path)}"}m)
end

# The text of any labelled element, not just the summary's definition values.
# The MFA status is a paragraph, so `detail` cannot reach it.
def element_text(body, id)
  body[%r{<[a-z0-9]+[^>]*id="#{Regexp.escape(id)}"[^>]*>(.*?)</[a-z0-9]+>}m, 1]
    .to_s.gsub(/<[^>]*>/, "").strip
end

# The enrolment key the page printed, so a check can generate a code from the
# secret the reader was shown rather than reaching into the database for it.
def displayed_key(body)
  body[%r{<code[^>]*id="mfa-secret"[^>]*>(.*?)</code>}m, 1].to_s.strip
end

# The code an authenticator app would show for a key right now.
def totp_code(key)
  ROTP::TOTP.new(key).now
end

# A six-digit string that is not the code for this key, so a refusal check can
# never accidentally post the right number.
def wrong_totp_code(key)
  format("%06d", (totp_code(key).to_i + 1) % 1_000_000)
end

TestReport.run do
  check "a guest is sent to sign-in and returned to /account afterwards" do
    session = new_session
    session.get("/account")

    assert session.last_response.status == 302, "guest GET /account answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.include?("/users/sign_in"),
           "guest redirected to #{session.last_response['Location'].inspect}"

    user = account("returning-to-account@example.com")
    sign_in(session, user)

    assert session.last_response.status == 302, "sign-in answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "sign-in returned the reader to #{session.last_response['Location'].inspect}"

    session.follow_redirect!
    assert session.last_response.status == 200, "GET /account answered #{session.last_response.status}"
    assert session.last_response.body.include?(user.email), "the account page did not render the account"
  end

  check "a signed-in member sees their own email, role, joined date, last sign-in and sign-in count" do
    user = account("profile-member@example.com")
    session = signed_in_session(user)
    session.get("/account")

    assert session.last_response.status == 200, "GET /account answered #{session.last_response.status}"
    body = session.last_response.body

    assert detail(body, "account-email") == user.email,
           "the account page shows #{detail(body, 'account-email').inspect}, expected #{user.email.inspect}"
    assert detail(body, "account-role") == "member",
           "the account page shows role #{detail(body, 'account-role').inspect}"
    assert detail(body, "account-joined") == user.created_at.strftime("%Y-%m-%d"),
           "the account page shows joined #{detail(body, 'account-joined').inspect}"
    assert detail(body, "account-status") == "active",
           "the account page shows status #{detail(body, 'account-status').inspect}"
    assert detail(body, "account-sign-in-count") == "1",
           "the account page shows sign-in count #{detail(body, 'account-sign-in-count').inspect}"

    assert user.reload.last_sign_in_at.present?, "the sign-in recorded no timestamp"
    assert detail(body, "account-last-sign-in") == user.last_sign_in_at.strftime("%Y-%m-%d %H:%M"),
           "the account page shows last sign-in #{detail(body, 'account-last-sign-in').inspect}"
  end

  check "an account with no recorded sign-in shows a dash rather than a blank or a crash" do
    user = account("never-signed-in@example.com")
    session = signed_in_session(user)

    # A session can outlive the trackable record written at authentication time
    # (an imported or repaired account row, for one). The page must render a
    # dash instead of a blank or raising on a nil timestamp.
    user.update_columns(last_sign_in_at: nil, current_sign_in_at: nil, sign_in_count: 0)

    session.get("/account")
    assert session.last_response.status == 200, "GET /account answered #{session.last_response.status}"
    body = session.last_response.body

    assert detail(body, "account-last-sign-in") == "—",
           "a never-signed-in account shows #{detail(body, 'account-last-sign-in').inspect}"
    assert detail(body, "account-sign-in-count") == "0",
           "a never-signed-in account shows sign-in count #{detail(body, 'account-sign-in-count').inspect}"
  end

  check "a later visit shows the previous sign-in and the running count" do
    user = account("profile-returning@example.com")
    signed_in_session(user)
    user.reload
    previous_sign_in = user.last_sign_in_at
    assert previous_sign_in, "the first sign-in recorded no timestamp"

    session = signed_in_session(user)
    user.reload
    session.get("/account")
    body = session.last_response.body

    assert detail(body, "account-last-sign-in") == previous_sign_in.strftime("%Y-%m-%d %H:%M"),
           "the account page shows last sign-in #{detail(body, 'account-last-sign-in').inspect}, " \
           "expected #{previous_sign_in.strftime('%Y-%m-%d %H:%M').inspect}"
    assert detail(body, "account-sign-in-count") == "2",
           "the account page shows sign-in count #{detail(body, 'account-sign-in-count').inspect}"
  end

  check "the role label reads as words for admin and super admin" do
    { admin: "admin", super_admin: "super admin" }.each do |role, label|
      user = account("#{label.tr(' ', '-')}-profile@example.com", role: role)
      session = signed_in_session(user)
      session.get("/account")

      body = session.last_response.body
      assert detail(body, "account-role") == label,
             "a #{role} sees role #{detail(body, 'account-role').inspect}, expected #{label.inspect}"
    end
  end

  check "the account page offers both forms and no way to edit the role" do
    user = account("form-reader@example.com")
    session = signed_in_session(user)
    session.get("/account")
    body = session.last_response.body

    assert form_for_path?(body, "/account/email"), "the account page has no email form: #{body[0, 600]}"
    assert form_for_path?(body, "/account/password"), "the account page has no password form"
    assert body.include?('name="user[email]"'), "the email form has no email field"
    assert body.include?('name="user[current_password]"'), "the email form has no current-password field"
    assert body.include?('name="user[password]"'), "the password form has no password field"
    assert body.include?('name="user[password_confirmation]"'), "the password form has no confirmation field"
    assert !body.include?('name="user[role]"'), "the account page renders a role field"
    assert !body.match?(/<select[^>]*name="user\[role\]"/), "the account page renders a role selector"
  end

  check "changing the email with the current password updates the account" do
    user = account("email-change@example.com")
    session = signed_in_session(user)

    session.patch("/account/email",
                  user: { email: "email-changed@example.com", current_password: PASSWORD })

    assert session.last_response.status == 302,
           "PATCH /account/email answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "the update redirected to #{session.last_response['Location'].inspect}"

    session.follow_redirect!
    assert session.last_response.status == 200, "the followed update answered #{session.last_response.status}"
    assert session.last_response.body.match?(/email .*(updated|changed)/i),
           "the page showed no confirmation: #{session.last_response.body[0, 400]}"

    assert user.reload.email == "email-changed@example.com",
           "the email is #{user.email.inspect} after the update"
    assert detail(session.last_response.body, "account-email") == "email-changed@example.com",
           "the page still shows the old email"
  end

  check "a wrong current password refuses the email change and leaves the record alone" do
    user = account("email-refused@example.com")
    session = signed_in_session(user)

    session.patch("/account/email",
                  user: { email: "should-not-land@example.com", current_password: "not the password" })

    assert session.last_response.status == 422,
           "a wrong current password answered #{session.last_response.status}"
    body = session.last_response.body
    assert body.match?(/current password/i) && body.match?(/invalid|incorrect/i),
           "no current-password error on the page: #{body[0, 800]}"
    assert user.reload.email == "email-refused@example.com",
           "a refused email change wrote #{user.email.inspect}"
  end

  check "an email already in use is refused with a validation error" do
    taken = account("already-taken@example.com")
    user = account("email-conflict@example.com")
    session = signed_in_session(user)

    session.patch("/account/email",
                  user: { email: taken.email, current_password: PASSWORD })

    assert session.last_response.status == 422,
           "a taken email answered #{session.last_response.status}"
    body = session.last_response.body
    assert body.match?(/already been taken/i), "no uniqueness error on the page: #{body[0, 800]}"
    assert user.reload.email == "email-conflict@example.com",
           "a refused email change wrote #{user.email.inspect}"
    assert taken.reload.email == "already-taken@example.com", "the other account's email changed"
  end

  check "changing the password keeps the session and the account signs in with the new one only" do
    user = account("password-change@example.com")
    session = signed_in_session(user)
    new_password = "a much better passphrase"

    session.patch("/account/password", user: {
      password: new_password, password_confirmation: new_password, current_password: PASSWORD
    })

    assert session.last_response.status == 302,
           "PATCH /account/password answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "the password change redirected to #{session.last_response['Location'].inspect}"

    session.follow_redirect!
    assert session.last_response.status == 200, "the followed change answered #{session.last_response.status}"
    assert session.last_response.body.match?(/password .*(changed|updated)/i),
           "no confirmation after the password change: #{session.last_response.body[0, 400]}"

    # Devise's sign_in_after_change_password default: the reader who just
    # changed their password stays signed in.
    assert signed_in?(session), "the session was dropped by the password change"
    session.get("/dashboard")
    assert session.last_response.status == 200,
           "the kept session reached /dashboard with #{session.last_response.status}"

    assert user.reload.valid_password?(new_password), "the new password does not authenticate"
    assert !user.valid_password?(PASSWORD), "the old password still authenticates"

    fresh = new_session
    sign_in(fresh, user, password: new_password)
    assert fresh.last_response.status == 302, "the new password answered #{fresh.last_response.status} on sign-in"
    assert fresh.last_response["Location"].to_s.end_with?("/dashboard"),
           "the new password landed on #{fresh.last_response['Location'].inspect}"

    stale = new_session
    sign_in(stale, user, password: PASSWORD)
    assert stale.last_response.status == 200, "the old password answered #{stale.last_response.status} on sign-in"
    assert !signed_in?(stale), "the old password still signs the account in"
  end

  check "a short password and a mismatched confirmation surface as inline errors" do
    user = account("password-errors@example.com")
    session = signed_in_session(user)

    session.patch("/account/password",
                  user: { password: "short", password_confirmation: "short", current_password: PASSWORD })
    assert session.last_response.status == 422, "a short password answered #{session.last_response.status}"
    assert session.last_response.body.match?(/too short/i),
           "no minimum-length error on the page: #{session.last_response.body[0, 800]}"

    session.patch("/account/password", user: {
      password: "a perfectly long password", password_confirmation: "a different long password",
      current_password: PASSWORD
    })
    assert session.last_response.status == 422, "a mismatched confirmation answered #{session.last_response.status}"
    assert session.last_response.body.match?(/password confirmation[^<]*match/i),
           "no confirmation error on the page: #{session.last_response.body[0, 800]}"

    assert user.reload.valid_password?(PASSWORD), "a refused password change altered the password"
  end

  check "posting a role alongside either change leaves the role untouched" do
    user = account("role-guard@example.com", role: :member)
    session = signed_in_session(user)

    session.patch("/account/email", user: {
      email: "role-guard-renamed@example.com", current_password: PASSWORD, role: "super_admin"
    })
    assert session.last_response.status == 302,
           "the email change with a role answered #{session.last_response.status}"
    assert user.reload.member?, "posting role=super_admin through the email form promoted the account"

    new_password = "yet another passphrase"
    session.patch("/account/password", user: {
      password: new_password, password_confirmation: new_password,
      current_password: PASSWORD, role: "super_admin"
    })
    assert session.last_response.status == 302,
           "the password change with a role answered #{session.last_response.status}"
    assert user.reload.member?, "posting role=super_admin through the password form promoted the account"
    assert user.role == "member", "the account role is #{user.role.inspect}"
  end

  check "a disabled account holding a session cannot reach the page" do
    user = account("disabled-reader@example.com")
    session = signed_in_session(user)
    assert signed_in?(session), "the account could not sign in while active"

    user.update!(disabled_at: Time.current)

    session.get("/account")
    assert session.last_response.status == 302,
           "a disabled session reached /account with #{session.last_response.status}"
    assert session.last_response["Location"].to_s.include?("/users/sign_in"),
           "the disabled session was sent to #{session.last_response['Location'].inspect}"

    # The session is ended, not merely bounced once: the next request is a
    # plain guest and the sign-in page does not pretend the account is signed in.
    assert !signed_in?(session), "the disabled account still holds a session"
    session.get("/account")
    assert session.last_response.status == 302,
           "a repeat request answered #{session.last_response.status}"

    session.follow_redirect!
    assert session.last_response.status == 200, "the sign-in page answered #{session.last_response.status}"
    assert !session.last_response.body.include?("Change password"),
           "the disabled account was shown the account forms"
  end

  check "with two-factor off the page offers setup and no disable action" do
    user = account("mfa-off@example.com")
    session = signed_in_session(user)
    session.get("/account")
    body = session.last_response.body

    assert element_text(body, "account-mfa-status").start_with?("Off"),
           "the MFA status reads #{element_text(body, 'account-mfa-status').inspect}"
    assert body.include?("Set up two-factor"), "an MFA-off account has no setup action"
    assert form_for_path?(body, "/account/two_factor"), "the setup action has no form"
    assert !body.include?("Disable two-factor"), "an MFA-off account was offered the disable action"
    assert !body.include?('id="mfa-secret"'), "an MFA-off account was shown a key"
    assert !user.reload.otp_required_for_login?, "a plain visit turned MFA on"
  end

  check "starting enrolment prints an otpauth URI and the key without turning MFA on" do
    user = account("mfa-enrol@example.com")
    session = signed_in_session(user)

    session.post("/account/two_factor")
    assert session.last_response.status == 302,
           "POST /account/two_factor answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "the setup redirected to #{session.last_response['Location'].inspect}"

    session.follow_redirect!
    body = session.last_response.body
    key = displayed_key(body)

    assert key.match?(/\A[A-Z2-7]{16,}\z/i), "the page printed #{key.inspect} as the key"
    assert body.include?("otpauth://totp/"), "the page printed no otpauth URI"

    uri = element_text(body, "mfa-provisioning-uri")
    assert uri.start_with?("otpauth://totp/"), "the setup URI reads #{uri.inspect}"
    assert uri.include?(key), "the setup URI does not carry the key the page printed"
    assert uri.include?("NewsAgg"), "the setup URI names no issuer"

    assert body.include?('name="user[otp_attempt]"'), "there is no confirmation-code field"

    user.reload
    assert !user.otp_required_for_login?, "enrolment turned MFA on before the code was confirmed"
    assert user.otp_secret.blank?, "the unconfirmed key was written to the account"
  end

  check "a code from the printed key turns two-factor on" do
    user = account("mfa-confirm@example.com")
    session = signed_in_session(user)

    session.post("/account/two_factor")
    session.follow_redirect!
    key = displayed_key(session.last_response.body)
    assert key.present?, "enrolment printed no key"

    session.patch("/account/two_factor", user: { otp_attempt: totp_code(key) })
    assert session.last_response.status == 302,
           "confirming the code answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "the confirmation redirected to #{session.last_response['Location'].inspect}"

    session.follow_redirect!
    body = session.last_response.body

    assert body.match?(/two-factor authentication is on/i),
           "no confirmation that MFA is on: #{body[0, 600]}"
    assert element_text(body, "account-mfa-status").start_with?("On"),
           "the MFA status reads #{element_text(body, 'account-mfa-status').inspect}"
    assert body.include?("Disable two-factor"), "the enabled account has no disable action"
    assert !body.include?('id="mfa-secret"'), "the key is still printed after enrolment"

    user.reload
    assert user.otp_required_for_login?, "the account still has MFA off"
    assert user.otp_secret == key, "the stored key differs from the key the page printed"
  end

  check "a wrong code leaves two-factor off and lets the reader retry" do
    user = account("mfa-wrong-code@example.com")
    session = signed_in_session(user)

    session.post("/account/two_factor")
    session.follow_redirect!
    key = displayed_key(session.last_response.body)

    session.patch("/account/two_factor", user: { otp_attempt: wrong_totp_code(key) })
    assert session.last_response.status == 422,
           "a wrong code answered #{session.last_response.status}"
    body = session.last_response.body
    assert body.match?(/did not match/i), "no wrong-code message on the page: #{body[0, 800]}"
    assert body.include?('id="mfa-secret"'),
           "the refused attempt hid the key, so there was no way to retry"

    user.reload
    assert !user.otp_required_for_login?, "a wrong code turned MFA on"
    assert user.otp_secret.blank?, "a wrong code stored the key"

    session.patch("/account/two_factor", user: { otp_attempt: totp_code(key) })
    assert session.last_response.status == 302,
           "the retry with the right code answered #{session.last_response.status}"
    assert user.reload.otp_required_for_login?, "the retry with the right code did not turn MFA on"
  end

  check "a malformed code is refused like a wrong one" do
    user = account("mfa-malformed-code@example.com")
    session = signed_in_session(user)

    session.post("/account/two_factor")
    session.follow_redirect!

    ["", "abc123", "12345", "1234567"].each do |code|
      session.patch("/account/two_factor", user: { otp_attempt: code })
      assert session.last_response.status == 422,
             "the code #{code.inspect} answered #{session.last_response.status}"
      assert !user.reload.otp_required_for_login?, "the code #{code.inspect} turned MFA on"
    end
  end

  check "confirming without a pending key cannot turn two-factor on" do
    user = account("mfa-no-pending@example.com")
    session = signed_in_session(user)

    session.patch("/account/two_factor", user: { otp_attempt: totp_code(User.generate_otp_secret) })
    assert session.last_response.status == 302,
           "a confirmation with no setup answered #{session.last_response.status}"
    assert session.last_response["Location"].to_s.end_with?("/account"),
           "a confirmation with no setup redirected to #{session.last_response['Location'].inspect}"

    user.reload
    assert !user.otp_required_for_login?, "a confirmation with no setup turned MFA on"
    assert user.otp_secret.blank?, "a confirmation with no setup stored a key"
  end

  check "turning two-factor off requires the current password" do
    user = account("mfa-disable@example.com")
    # Signed in first, then enabled directly: the sign-in path is deliberately
    # untouched here, because this card is the account page's half of MFA.
    session = signed_in_session(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    enabled_key = user.otp_secret

    session.get("/account")
    body = session.last_response.body
    assert element_text(body, "account-mfa-status").start_with?("On"),
           "the enabled account shows status #{element_text(body, 'account-mfa-status').inspect}"
    assert body.include?("Disable two-factor"), "the enabled account has no disable form"

    session.delete("/account/two_factor", user: { current_password: "not the password" })
    assert session.last_response.status == 422,
           "a wrong password answered #{session.last_response.status}"
    body = session.last_response.body
    assert body.match?(/current password/i) && body.match?(/invalid|incorrect/i),
           "no current-password error on the page: #{body[0, 800]}"

    user.reload
    assert user.otp_required_for_login?, "a wrong password turned MFA off"
    assert user.otp_secret == enabled_key, "a wrong password discarded the key"

    session.delete("/account/two_factor", user: { current_password: PASSWORD })
    assert session.last_response.status == 302,
           "the right password answered #{session.last_response.status}"
    session.follow_redirect!
    body = session.last_response.body

    assert body.match?(/two-factor authentication is off/i),
           "no confirmation that MFA is off: #{body[0, 600]}"
    assert element_text(body, "account-mfa-status").start_with?("Off"),
           "the MFA status reads #{element_text(body, 'account-mfa-status').inspect}"
    assert body.include?("Set up two-factor"), "the MFA-off account has no setup action"

    user.reload
    assert !user.otp_required_for_login?, "the account still requires MFA"
    assert user.otp_secret.blank?, "the key survived being disabled"
  end

  check "one account never sees another account's key or MFA state" do
    owner = account("mfa-owner@example.com")
    other = account("mfa-other@example.com")
    owner_session = signed_in_session(owner)
    other_session = signed_in_session(other)

    owner_session.post("/account/two_factor")
    owner_session.follow_redirect!
    key = displayed_key(owner_session.last_response.body)
    assert key.present?, "the owner's enrolment printed no key"

    other_session.get("/account")
    body = other_session.last_response.body
    assert !body.include?(key), "another account's page printed the owner's key"
    assert !body.include?("otpauth://"), "another account's page printed the owner's setup URI"
    assert body.include?("Set up two-factor"), "another account has no setup action of its own"

    guest = new_session
    guest.get("/account")
    assert guest.last_response.status == 302,
           "a guest GET /account answered #{guest.last_response.status}"
    assert !guest.last_response.body.to_s.include?(key), "a guest was shown a key"
  end
end
