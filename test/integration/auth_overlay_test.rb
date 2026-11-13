# The landing page's sign-in overlay, exercised through the real HTTP routes
# against a disposable sqlite database. The landing page keeps two ordinary
# links (they still work with JavaScript off); with JavaScript they open a
# dialog holding an iframe of the Devise form, and that form renders chrome-free
# while carrying the same fields, CSRF token and errors as the full page.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "rack/test"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/fake_archive"

include TestReport

OVERLAY_DB_DIR = Dir.mktmpdir("newsagg-overlay-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(OVERLAY_DB_DIR) if File.directory?(OVERLAY_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: File.join(OVERLAY_DB_DIR, "overlay.sqlite3")
)
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

Rails.application.config.x.archive_factory = -> { FakeArchive.new([]) }

PASSWORD = "correct horse battery"

def new_session
  Rack::Test::Session.new(Rails.application)
end

def account(email, password: PASSWORD)
  User.create!(email: email, password: password)
end

# The landing page's two calls to action, each an ordinary link that also names
# the embedded source it opens in the dialog.
def trigger(body, label)
  body[/<a [^>]*data-auth-overlay="[^"]*"[^>]*>.*?#{Regexp.escape(label)}.*?<\/a>/m]
end

# The Devise form a page renders, so two renders can be compared field by field.
def form_for_path(body, path)
  body[%r{<form[^>]*action="#{Regexp.escape(path)}"[^>]*>.*?</form>}m]
end

def field_names(form)
  form.scan(/name="([^"]+)"/).flatten.sort
end

# Every anchor a page renders, by href. The link set is what has to keep
# answering, whichever Devise modules the User model enables.
def anchor_hrefs(body)
  body.scan(/<a [^>]*href="([^"]*)"/).flatten.sort
end

def top_bar_present?(body)
  body.match?(/class="topbar"/) || body.include?("topbar-account")
end

TestReport.run do
  check "the landing page ships the overlay dialog and both triggers keep their href" do
    session = new_session
    session.get("/")

    assert(session.last_response.status == 200, "expected HTTP 200, got #{session.last_response.status}")
    body = session.last_response.body

    dialog = body[%r{<[^>]+role="dialog"[^>]*>}m]
    assert(dialog, "the landing page carries no dialog element")
    assert(dialog.include?('aria-modal="true"'), "the dialog is not marked modal: #{dialog}")

    overlay = body[%r{<div[^>]*id="auth-overlay"[^>]*>}m]
    assert(overlay, "the landing page carries no overlay container")
    assert(overlay.include?("hidden"),
           "the overlay is not hidden by default, so it would cover the no-JavaScript page: #{overlay}")

    frame = body[/<iframe [^>]*id="auth-overlay-frame"[^>]*>/m]
    assert(frame, "the dialog holds no iframe for the Devise form")

    assert(body.match?(/data-auth-overlay-close/), "the dialog has no close control")

    sign_in = trigger(body, "Sign in")
    sign_up = trigger(body, "Create account")
    assert(sign_in, "the landing page lost its sign-in trigger")
    assert(sign_up, "the landing page lost its create-account trigger")
    assert(sign_in.match?(/href="\/users\/sign_in"/),
           "the sign-in trigger has no href fallback: #{sign_in}")
    assert(sign_up.match?(/href="\/users\/sign_up"/),
           "the create-account trigger has no href fallback: #{sign_up}")

    [["/users/sign_in?embedded=1", sign_in], ["/users/sign_up?embedded=1", sign_up]].each do |source, link|
      assert(link.include?(%(data-auth-overlay-src="#{source}")),
             "the trigger does not name the embedded source #{source}: #{link}")
    end
  end

  check "the embedded sign-in page renders chrome-free with the same form" do
    session = new_session
    session.get("/users/sign_in?embedded=1")

    response = session.last_response
    assert(response.status == 200, "GET /users/sign_in?embedded=1 answered #{response.status}")
    body = response.body

    assert(!top_bar_present?(body), "the embedded sign-in page still renders the top bar")
    assert(body.include?('class="auth-card"'), "the embedded sign-in page renders no compact card")
    assert(body.include?('name="user[email]"'), "the embedded sign-in form has no email field")
    assert(body.include?('name="user[password]"'), "the embedded sign-in form has no password field")
    assert(body.include?('href="/dashboard.css"'), "the embedded page does not load the stylesheet")

    embedded_form = form_for_path(body, "/users/sign_in")
    assert(embedded_form, "the embedded form does not post to the sign-in route: #{body}")
    assert(embedded_form.match?(/name="embedded"[^>]*value="1"/),
           "the embedded form does not carry the marker: #{embedded_form}")
    assert(embedded_form.include?('data-turbo="false"'),
           "the embedded form is still submitted by Turbo, which swallows the failure page: #{embedded_form}")

    # The frame carries the same form as the full page, field for field - the
    # CSRF token included.
    session.get("/users/sign_in")
    full_form = form_for_path(session.last_response.body, "/users/sign_in")
    assert(full_form, "the full sign-in page renders no form")
    assert(field_names(embedded_form) - ["embedded"] == field_names(full_form),
           "the embedded form's fields differ from the full page's: " \
           "#{field_names(embedded_form).inspect} vs #{field_names(full_form).inspect}")
  end

  check "the embedded sign-up page renders chrome-free with the same form" do
    session = new_session
    session.get("/users/sign_up?embedded=1")

    response = session.last_response
    assert(response.status == 200, "GET /users/sign_up?embedded=1 answered #{response.status}")
    body = response.body

    assert(!top_bar_present?(body), "the embedded sign-up page still renders the top bar")
    assert(body.include?('name="user[email]"'), "the embedded sign-up form has no email field")
    assert(body.include?('name="user[password_confirmation]"'),
           "the embedded sign-up form has no password confirmation field")
    sign_up_form = form_for_path(body, "/users")
    assert(sign_up_form, "the embedded sign-up form does not post to the registration route: #{body}")
    assert(sign_up_form.match?(/name="embedded"[^>]*value="1"/),
           "the embedded sign-up form does not carry the marker: #{sign_up_form}")
  end

  check "a direct visit to the sign-in page still renders the top bar" do
    session = new_session
    session.get("/users/sign_in")
    # Once the deep link lands, a guest is handed to the landing page, where the
    # same form opens in the card's frame; before that, the form is in the page.
    session.follow_redirect! if session.last_response.redirect?

    response = session.last_response
    assert(response.status == 200, "GET /users/sign_in answered #{response.status}")
    assert(top_bar_present?(response.body), "the page a direct sign-in visit lands on lost its top bar")
    assert(response.body.include?('name="user[email]"') ||
           response.body.include?('data-auth-overlay-src="/users/sign_in?embedded=1"'),
           "the page a direct sign-in visit lands on offers no sign-in form")
    assert(!response.body.include?('class="auth-card"'),
           "the full sign-in page renders the embedded card")
  end

  # The frame used to pin itself to a fixed 520px, so the taller card scrolled
  # inside it and both ends were cut off: the heading at the top, the last link
  # below the fold. The frame now carries the embedded card's own height and the
  # stylesheet caps it at the viewport, so a longer form scrolls inside the frame
  # instead of being clipped.
  check "the frame is sized from the embedded card, not from a fixed height" do
    session = new_session
    session.get("/dashboard.css")
    assert(session.last_response.status == 200,
           "GET /dashboard.css answered #{session.last_response.status}")
    css = session.last_response.body

    frame_rule = css[%r!\.auth-overlay-frame\s*\{[^}]*\}!m].to_s
    assert(!frame_rule.empty?, "the stylesheet has no .auth-overlay-frame rule")
    assert(!frame_rule.match?(/(?<![\w-])height:\s*[\d.]+px/),
           "the frame still assumes one form's length: #{frame_rule}")
    assert(frame_rule.match?(/max-height:\s*calc\(100vh - 2\.5rem\)/),
           "the frame has no viewport cap: #{frame_rule}")

    session.get("/dashboard.js")
    js = session.last_response.body
    assert(js.match?(/querySelector\("\.auth-card"\)/),
           "the overlay script never measures the embedded card")
    assert(js.match?(/frame\.style\.height\s*=/),
           "the overlay script never gives the frame the card's height")
  end

  check "signing in through the embedded form lands on the dashboard" do
    user = account("overlay-reader@example.com")
    session = new_session
    session.get("/users/sign_in?embedded=1")
    session.post("/users/sign_in", { user: { email: user.email, password: PASSWORD },
                                     embedded: "1" })

    assert(session.last_response.status == 302,
           "embedded sign-in answered #{session.last_response.status}")
    assert(session.last_response["Location"].to_s.end_with?("/dashboard"),
           "embedded sign-in sent the reader to #{session.last_response['Location']}")

    session.get("/dashboard")
    assert(session.last_response.status == 200,
           "the signed-in dashboard answered #{session.last_response.status}")
  end

  check "a wrong password in the embedded form shows the error in the frame" do
    user = account("overlay-wrong@example.com")
    session = new_session
    session.get("/users/sign_in?embedded=1")
    session.post("/users/sign_in", { user: { email: user.email, password: "not the password" },
                                     embedded: "1" })

    response = session.last_response
    assert(response.status == 200, "a failed embedded sign-in answered #{response.status}")
    body = response.body
    assert(body.match?(/Invalid Email or password/i), "the frame shows no sign-in error: #{body}")
    assert(!top_bar_present?(body), "the failed attempt fell back to the full page chrome")
    assert(body.include?('name="user[password]"'), "the re-rendered frame lost its form fields")

    session.get("/dashboard")
    assert(session.last_response.status == 302,
           "a failed sign-in left the visitor signed in: dashboard answered #{session.last_response.status}")
  end

  # The card's links are Devise's, rendered from whichever modules the User
  # model enables. A module turned on without a working route behind it - or
  # turned off while the view still offers its link - shows up here.
  check "every link on the embedded sign-in card leads somewhere that answers" do
    session = new_session
    session.get("/users/sign_in?embedded=1")
    body = session.last_response.body

    hrefs = anchor_hrefs(body)
    assert(hrefs == ["/users/password/new", "/users/sign_up?embedded=1", "/users/unlock/new"],
           "the sign-in card's link set changed: #{hrefs.inspect}")

    hrefs.each do |href|
      target = new_session
      target.get(href)
      assert(target.last_response.status == 200,
             "the sign-in card's #{href} link answered #{target.last_response.status}")
    end
  end

  # A link that renders is not yet a link that works: /users/unlock/new answers
  # 200 whether or not its form can send anything. The fixture account is locked
  # the way Devise locks one, so the email has to arrive and its token has to
  # unlock the account.
  check "the unlock link reaches a form that unlocks the account" do
    user = account("overlay-locked@example.com")
    user.lock_access!
    ActionMailer::Base.deliveries.clear

    session = new_session
    session.get("/users/unlock/new")
    assert(session.last_response.status == 200,
           "the unlock form answered #{session.last_response.status}")

    session.post("/users/unlock", user: { email: user.email })
    assert(ActionMailer::Base.deliveries.any?, "the unlock form sent no mail")

    mail = ActionMailer::Base.deliveries.last
    assert(mail.to == [user.email], "the unlock mail went to #{mail.to.inspect}")
    unlock_path = mail.body.to_s[%r{/users/unlock\?unlock_token=[^"]+}]
    assert(unlock_path, "the unlock mail carries no unlock link: #{mail.body}")

    unlock = new_session
    unlock.get(unlock_path)
    assert(!user.reload.access_locked?, "the mailed unlock link did not unlock the account")
  end
end
