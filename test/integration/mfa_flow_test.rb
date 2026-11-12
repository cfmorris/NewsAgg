# The whole MFA journey in one place: an account turns two-factor on through
# /account, signs out, and signs back in with a code generated from the key the
# page printed. A wrong code is retryable and never locks the account, turning
# MFA off restores the one-step sign-in, and no other account can see the key,
# the setup URI, or the fact that MFA is on.
#
# Every request goes through the real HTTP routes against a disposable sqlite
# database. The account page's own suite covers its forms in isolation; this
# suite is the seam between enrolment and sign-in, which is where the two
# features have to agree on otp_secret, drift and the consumed timestep.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "rotp"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"

include TestReport

MFA_FLOW_DB_DIR = Dir.mktmpdir("newsagg-mfa-flow-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(MFA_FLOW_DB_DIR) if File.directory?(MFA_FLOW_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(MFA_FLOW_DB_DIR, "mfa-flow.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

# Signing in lands on the dashboard, which asks the archive for articles.
Rails.application.config.x.archive_factory = -> { FakeArchive.new([]) }

PASSWORD = "correct horse battery"
MAXIMUM_ATTEMPTS = Devise.maximum_attempts

def new_session
  Rack::Test::Session.new(Rails.application)
end

def account(email)
  User.create!(email: email, password: PASSWORD)
end

def sign_in(session, email, password: PASSWORD)
  session.get("/users/sign_in")
  session.post("/users/sign_in", user: { email: email, password: password })
end

def signed_in_session(user)
  session = new_session
  sign_in(session, user.email)
  session
end

# Devise bounces an authenticated visitor from the sign-in page, so a redirect
# there is proof the session carries a user.
def signed_in?(session)
  session.get("/users/sign_in")
  session.last_response.status == 302
end

# The text of a labelled element, so a check can name the exact figure it means
# instead of matching any occurrence on the page.
def element_text(body, id)
  body[%r{<[a-z0-9]+[^>]*id="#{Regexp.escape(id)}"[^>]*>(.*?)</[a-z0-9]+>}m, 1]
    .to_s.gsub(/<[^>]*>/, "").strip
end

def mfa_status(body)
  element_text(body, "account-mfa-status")
end

# The enrolment key the page printed. Codes are generated from this string, not
# from the database, because the printed key is all a reader's app ever gets.
def displayed_key(body)
  body[%r{<code[^>]*id="mfa-secret"[^>]*>(.*?)</code>}m, 1].to_s.strip
end

def totp_code(key)
  ROTP::TOTP.new(key).now
end

# A six-digit string that is not the code for this key now, nor the code for
# either step the challenge's drift window accepts, so a refusal check can never
# accidentally post a valid number.
def wrong_totp_code(key, offset: 7)
  totp = ROTP::TOTP.new(key)
  candidate = format("%06d", (totp.now.to_i + offset) % 1_000_000)
  candidate = format("%06d", (candidate.to_i + 1) % 1_000_000) while
    totp.verify(candidate, drift_behind: 30, drift_ahead: 30).present?
  candidate
end

# Begin enrolment on the account page and return the key it printed.
def start_enrolment(session)
  session.post("/account/two_factor")
  assert(session.last_response.status == 302,
         "starting enrolment answered #{session.last_response.status}")
  session.follow_redirect!
  body = session.last_response.body
  key = displayed_key(body)
  assert(key.present?, "the setup page printed no key: #{body[0, 800]}")
  assert(body.include?("otpauth://"), "the setup page printed no provisioning URI")
  key
end

# Confirm the printed key with a code from it, which turns MFA on.
def confirm_enrolment(session, key)
  session.patch("/account/two_factor", user: { otp_attempt: totp_code(key) })
  assert(session.last_response.status == 302,
         "confirming a code from the printed key answered #{session.last_response.status}")
  assert(session.last_response["Location"].to_s.end_with?("/account"),
         "the confirmation redirected to #{session.last_response['Location'].inspect}")
end

# The whole enrolment, from a signed-in session, so each check can start from an
# account that really has MFA on rather than one poked into place.
def enable_mfa!(session, user)
  key = start_enrolment(session)
  confirm_enrolment(session, key)
  assert(user.reload.otp_required_for_login?, "the confirmed key did not turn MFA on")
  key
end

def code_prompt?(body)
  body.include?('name="user[otp_attempt]"')
end

TestReport.run do
  check "enrolling prints a key whose code signs the account in" do
    user = account("mfa-journey@example.com")
    browser = signed_in_session(user)

    browser.get("/account")
    assert(mfa_status(browser.last_response.body).start_with?("Off"),
           "a fresh account starts with MFA #{mfa_status(browser.last_response.body).inspect}")

    key = enable_mfa!(browser, user)

    # Once on, the page reports it and stops printing the key.
    browser.get("/account")
    body = browser.last_response.body
    assert(mfa_status(body).start_with?("On"),
           "the enabled account shows MFA #{mfa_status(body).inspect}")
    assert(body.include?("Disable two-factor"), "the enabled account has no disable action")
    assert(!body.include?(key), "the account page still prints the key after enrolment")
    assert(!body.include?("otpauth://"), "the account page still prints the setup URI after enrolment")

    # A reader with the printed key and the password is now the only way in.
    second = new_session
    sign_in(second, user.email)
    assert(second.last_response.status == 200,
           "the password step for an MFA account answered #{second.last_response.status}")
    assert(code_prompt?(second.last_response.body), "the password step asked for no code")
    assert(!signed_in?(second), "the password step signed an MFA account in without a code")

    second.post("/users/sign_in/two_factor", user: { otp_attempt: totp_code(key) })
    assert(second.last_response.status == 302,
           "the code generated from the printed key answered #{second.last_response.status}")
    assert(second.last_response["Location"].to_s.end_with?("/dashboard"),
           "the code step sent the reader to #{second.last_response['Location'].inspect}")
    assert(signed_in?(second), "the code generated from the printed key did not sign the account in")

    second.get("/dashboard")
    assert(second.last_response.status == 200,
           "the dashboard answered #{second.last_response.status} after the MFA sign-in")
  end

  check "a wrong code is refused repeatedly without locking the account" do
    user = account("mfa-journey-wrong@example.com")
    key = enable_mfa!(signed_in_session(user), user)

    browser = new_session
    sign_in(browser, user.email)
    assert(code_prompt?(browser.last_response.body), "the password step asked for no code")

    bad_code = wrong_totp_code(key)
    (MAXIMUM_ATTEMPTS + 5).times do |attempt|
      browser.post("/users/sign_in/two_factor", user: { otp_attempt: bad_code })
      response = browser.last_response
      assert(response.status == 422,
             "wrong code #{attempt + 1} answered #{response.status}")
      assert(code_prompt?(response.body), "wrong code #{attempt + 1} dropped the code field")
      assert(!signed_in?(browser), "wrong code #{attempt + 1} signed the account in")
    end

    user.reload
    assert(!user.access_locked?, "#{MAXIMUM_ATTEMPTS + 5} wrong codes locked the account")
    assert(user.failed_attempts.zero?,
           "wrong codes were charged #{user.failed_attempts} failed attempts")
    assert(user.otp_required_for_login?, "wrong codes turned MFA off")
    assert(user.otp_secret.present?, "wrong codes discarded the key")

    # The account is still usable: the right code completes the sign-in.
    browser.post("/users/sign_in/two_factor", user: { otp_attempt: totp_code(key) })
    assert(browser.last_response.status == 302,
           "the right code after wrong ones answered #{browser.last_response.status}")
    assert(signed_in?(browser), "the right code after wrong ones did not sign the account in")
  end

  check "disabling MFA restores single-factor sign-in" do
    user = account("mfa-journey-disable@example.com")
    browser = signed_in_session(user)
    key = enable_mfa!(browser, user)

    # While MFA is on, one POST cannot sign in.
    before = new_session
    sign_in(before, user.email)
    assert(before.last_response.status == 200 && code_prompt?(before.last_response.body),
           "MFA was on but the password step signed the account in")

    browser.get("/account")
    assert(mfa_status(browser.last_response.body).start_with?("On"),
           "the account page shows MFA #{mfa_status(browser.last_response.body).inspect}")

    # A borrowed session must not strip the second factor.
    browser.delete("/account/two_factor", user: { current_password: "not the password" })
    assert(browser.last_response.status == 422,
           "a wrong password for disable answered #{browser.last_response.status}")
    user.reload
    assert(user.otp_required_for_login?, "a wrong password turned MFA off")
    assert(user.otp_secret == key, "a wrong password discarded the key")

    browser.delete("/account/two_factor", user: { current_password: PASSWORD })
    assert(browser.last_response.status == 302,
           "the right password for disable answered #{browser.last_response.status}")
    browser.follow_redirect!
    body = browser.last_response.body
    assert(mfa_status(body).start_with?("Off"),
           "after disabling, the account page shows MFA #{mfa_status(body).inspect}")
    assert(body.include?("Set up two-factor"), "the disabled account was not offered setup")
    assert(!body.include?(key), "the account page still prints the discarded key")

    user.reload
    assert(!user.otp_required_for_login?, "disabling left MFA on")
    assert(user.otp_secret.blank?, "disabling kept the key")
    assert(user.consumed_timestep.nil?, "disabling kept the consumed timestep")

    # Single-factor sign-in works again, in one POST, with no code field.
    after = new_session
    sign_in(after, user.email)
    assert(after.last_response.status == 302,
           "the single-factor sign-in answered #{after.last_response.status}")
    assert(after.last_response["Location"].to_s.end_with?("/dashboard"),
           "the single-factor sign-in went to #{after.last_response['Location'].inspect}")
    assert(signed_in?(after), "the single-factor sign-in did not establish a session")

    page = new_session.get("/users/sign_in")
    assert(!code_prompt?(page.body), "the sign-in page asks for a code after MFA was disabled")
  end

  check "another account never sees the key, the URI, or that MFA is on" do
    owner = account("mfa-journey-owner@example.com")
    other = account("mfa-journey-other@example.com")
    key = enable_mfa!(signed_in_session(owner), owner)

    other_browser = signed_in_session(other)
    other_browser.get("/account")
    body = other_browser.last_response.body
    assert(!body.include?(key), "another account's page printed the owner's key")
    assert(!body.include?("otpauth://"), "another account's page printed the owner's setup URI")
    assert(mfa_status(body).start_with?("Off"),
           "another account's page leaks the owner's MFA state: #{mfa_status(body).inspect}")
    assert(!body.include?("Signing in asks for your password and a code"),
           "another account's page says MFA is on")
    assert(body.include?("Set up two-factor"), "another account has no setup action of its own")
    assert(!body.include?("Disable two-factor"), "another account was offered the owner's disable action")

    # Posting the owner's key or password to the shared path changes nothing for
    # the owner: the forms only ever act on the signed-in account.
    other_browser.patch("/account/two_factor", user: { otp_attempt: totp_code(key) })
    other_browser.delete("/account/two_factor", user: { current_password: PASSWORD })

    owner.reload
    assert(owner.otp_required_for_login?, "another account turned the owner's MFA off")
    assert(owner.otp_secret == key, "another account replaced or discarded the owner's key")
    other.reload
    assert(!other.otp_required_for_login?, "another account enrolled itself from the owner's code")

    guest = new_session
    guest.get("/account")
    assert(guest.last_response.status == 302,
           "a guest GET /account answered #{guest.last_response.status}")
    assert(!guest.last_response.body.to_s.include?(key), "a guest was shown a key")
  end
end
