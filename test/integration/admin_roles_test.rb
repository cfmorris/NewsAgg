# Roles, guest handling and the /admin area, exercised through the real HTTP
# routes and rake tasks against a disposable sqlite database.
ENV["RAILS_ENV"] = "test"

require "fileutils"
require "json"
require "rack/test"
require "rake"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../support/assertions"
require_relative "../support/signed_in_probe"

include TestReport
include SignedInProbe

ADMIN_DB_DIR = Dir.mktmpdir("newsagg-admin-")
at_exit do
  begin
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.remove_entry(ADMIN_DB_DIR) if File.directory?(ADMIN_DB_DIR)
  rescue StandardError
    # Windows can hold the sqlite file open until the process exits; the
    # temporary directory is disposable either way.
  end
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(ADMIN_DB_DIR, "admin.sqlite3"))
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

PASSWORD = "correct horse battery"
JSON_HEADERS = { "HTTP_ACCEPT" => "application/json" }.freeze

def new_session
  Rack::Test::Session.new(Rails.application)
end

def sign_in(session, user, password: PASSWORD)
  session.post("/users/sign_in", user: { email: user.email, password: password })
end

def account(email, role: :member)
  User.create!(email: email, password: PASSWORD, role: role)
end

def set_role(session, user, role)
  session.patch("/admin/users/#{user.id}/role", { role: role }, JSON_HEADERS)
end

def set_state(session, user, state)
  session.patch("/admin/users/#{user.id}/state", { state: state }, JSON_HEADERS)
end

# The page the browser ends up on after a refusal, whether the app answered
# with the page itself or with a redirect to it.
def followed_body(session)
  session.follow_redirect! if session.last_response.status.between?(300, 399)
  session.last_response.body.to_s
end

# Runs a rake task in this process and reports what it wrote plus its exit
# status, so operator tooling is covered through its real entry point.
Rake.application = Rake::Application.new
Rake.application.init("rake")
Rake.application.load_rakefile

def run_task(name, *args)
  task = Rake::Task[name]
  task.reenable
  out = StringIO.new
  err = StringIO.new
  stdout, stderr = $stdout, $stderr
  status = nil
  begin
    $stdout = out
    $stderr = err
    task.invoke(*args)
  rescue SystemExit => exit_signal
    status = exit_signal.status
  ensure
    $stdout = stdout
    $stderr = stderr
  end
  [out.string, err.string, status]
end

TestReport.run do
  check "the first user to register on an empty table becomes super_admin" do
    session = new_session
    session.post("/users", user: { email: "founder@example.com", password: PASSWORD, password_confirmation: PASSWORD })

    founder = User.find_by(email: "founder@example.com")
    assert founder, "signing up did not create a user"
    assert founder.super_admin?, "the first user was #{founder.role.inspect}, expected super_admin"
  end

  check "a later registrant is a plain member" do
    session = new_session
    session.post("/users", user: { email: "latecomer@example.com", password: PASSWORD, password_confirmation: PASSWORD })

    latecomer = User.find_by(email: "latecomer@example.com")
    assert latecomer, "signing up did not create a user"
    assert latecomer.member?, "a later registrant was #{latecomer.role.inspect}, expected member"
  end

  check "the role predicates and guest/registered predicates agree" do
    owner = account("predicate-owner@example.com", role: :super_admin)
    operator = account("predicate-operator@example.com", role: :admin)
    reader = account("predicate-reader@example.com", role: :member)

    assert owner.super_admin? && !owner.admin? && !owner.member?, "super_admin predicates disagreed"
    assert operator.admin? && !operator.super_admin? && !operator.member?, "admin predicates disagreed"
    assert reader.member? && !reader.admin? && !reader.super_admin?, "member predicates disagreed"

    assert ![owner, operator, reader].any?(&:guest?), "a stored user reported itself as a guest"
    assert [owner, operator, reader].all?(&:registered?), "a stored user reported itself as unregistered"
  end

  check "the GuestUser null object reports no capabilities" do
    guest = GuestUser.new

    assert guest.guest?, "a guest object did not report guest?"
    assert !guest.registered?, "a guest object reported registered?"
    assert !guest.member?, "a guest object reported member?"
    assert !guest.admin?, "a guest object reported admin?"
    assert !guest.super_admin?, "a guest object reported super_admin?"
    assert guest.email.nil?, "a guest object exposed an email: #{guest.email.inspect}"
  end

  check "current_actor falls back to a guest and returns the stored user otherwise" do
    reader = account("actor-reader@example.com")
    controller = ApplicationController.new
    controller.define_singleton_method(:current_user) { nil }
    assert controller.send(:current_actor).guest?, "an anonymous request did not get a guest actor"

    controller.define_singleton_method(:current_user) { reader }
    assert controller.send(:current_actor).equal?(reader), "current_actor did not return the signed-in user"
  end

  check "a guest is sent to sign-in for HTML and gets 401 for JSON" do
    session = new_session
    session.get("/admin/users")
    assert session.last_response.status == 302, "expected a redirect, got #{session.last_response.status}"
    assert session.last_response.headers["Location"].to_s.include?("/users/sign_in"),
           "guest redirected to #{session.last_response.headers["Location"].inspect}"

    session.get("/admin/users", {}, JSON_HEADERS)
    assert session.last_response.status == 401, "expected 401 for JSON, got #{session.last_response.status}"
  end

  check "a member has no admin access (403 for JSON and HTML)" do
    reader = account("blocked-reader@example.com")
    session = new_session
    sign_in(session, reader)
    assert signed_in?(session), "the member could not sign in"

    session.get("/admin/users", {}, JSON_HEADERS)
    assert session.last_response.status == 403, "expected 403 for JSON, got #{session.last_response.status}"

    session.get("/admin/users")
    assert session.last_response.status == 403, "expected 403 for HTML, got #{session.last_response.status}"
    assert session.last_response.body.include?("not permitted"), "the 403 page carried no visible message"
  end

  check "an admin and a super_admin can open /admin/users" do
    operator = account("listing-operator@example.com", role: :admin)
    owner = account("listing-owner@example.com", role: :super_admin)

    admin_session = new_session
    sign_in(admin_session, operator)
    admin_session.get("/admin/users")
    assert admin_session.last_response.status == 200, "admin got #{admin_session.last_response.status}"
    assert admin_session.last_response.body.include?(operator.email), "the user table did not list the admin's own row"

    owner_session = new_session
    sign_in(owner_session, owner)
    owner_session.get("/admin/users")
    assert owner_session.last_response.status == 200, "super_admin got #{owner_session.last_response.status}"
  end

  check "an admin disables and re-enables a member" do
    operator = account("state-operator@example.com", role: :admin)
    reader = account("state-reader@example.com")
    session = new_session
    sign_in(session, operator)

    set_state(session, reader, "disable")
    assert session.last_response.status == 200, "disabling a member answered #{session.last_response.status}"
    assert reader.reload.disabled?, "the member was not disabled"

    set_state(session, reader, "enable")
    assert session.last_response.status == 200, "enabling a member answered #{session.last_response.status}"
    assert !reader.reload.disabled?, "the member was not re-enabled"
  end

  check "an admin gets 403 acting on another admin and changes nothing" do
    operator = account("peer-operator@example.com", role: :admin)
    peer = account("peer-admin@example.com", role: :admin)
    session = new_session
    sign_in(session, operator)

    set_state(session, peer, "disable")
    assert session.last_response.status == 403, "expected 403, got #{session.last_response.status}"
    assert !peer.reload.disabled?, "a refused disable changed the peer admin"

    set_role(session, peer, "member")
    assert session.last_response.status == 403, "expected 403 on a peer role change, got #{session.last_response.status}"
    assert peer.reload.admin?, "a refused role change altered the peer admin"
  end

  check "a super_admin promotes a member and demotes an admin" do
    owner = account("matrix-owner@example.com", role: :super_admin)
    reader = account("matrix-reader@example.com")
    session = new_session
    sign_in(session, owner)

    set_role(session, reader, "admin")
    assert session.last_response.status == 200, "promotion answered #{session.last_response.status}"
    assert reader.reload.admin?, "the member was not promoted to admin"

    set_role(session, reader, "member")
    assert session.last_response.status == 200, "demotion answered #{session.last_response.status}"
    assert reader.reload.member?, "the admin was not demoted to member"
  end

  check "a super_admin grants and revokes super_admin" do
    owner = account("grant-owner@example.com", role: :super_admin)
    reader = account("grant-reader@example.com")
    session = new_session
    sign_in(session, owner)

    set_role(session, reader, "super_admin")
    assert session.last_response.status == 200, "grant answered #{session.last_response.status}"
    assert reader.reload.super_admin?, "super_admin was not granted"

    set_role(session, reader, "member")
    assert session.last_response.status == 200, "revoke answered #{session.last_response.status}"
    assert reader.reload.member?, "super_admin was not revoked"
  end

  check "an actor cannot change their own role" do
    owner = account("self-role-owner@example.com", role: :super_admin)
    account("self-role-witness@example.com", role: :super_admin)
    session = new_session
    sign_in(session, owner)

    set_role(session, owner, "member")
    assert session.last_response.status >= 400 && session.last_response.status < 500,
           "self-demotion answered #{session.last_response.status}"
    assert session.last_response.body.include?("own role"), "no visible self-demotion error: #{session.last_response.body}"
    assert owner.reload.super_admin?, "a refused self-demotion changed the actor's role"
  end

  check "an actor cannot disable their own account" do
    owner = account("self-state-owner@example.com", role: :super_admin)
    session = new_session
    sign_in(session, owner)

    set_state(session, owner, "disable")
    assert session.last_response.status >= 400 && session.last_response.status < 500,
           "self-disable answered #{session.last_response.status}"
    assert session.last_response.body.include?("own account"), "no visible self-disable error: #{session.last_response.body}"
    assert !owner.reload.disabled?, "a refused self-disable disabled the actor"
  end

  check "the last super_admin cannot be demoted or disabled" do
    owner = account("last-owner@example.com", role: :super_admin)
    # Guarantee owner is the only super_admin left before exercising the guard.
    User.where(role: User.roles[:super_admin]).where.not(id: owner.id).update_all(role: User.roles[:member])

    session = new_session
    sign_in(session, owner)
    set_role(session, owner, "admin")
    assert session.last_response.status >= 400 && session.last_response.status < 500,
           "last super_admin demotion answered #{session.last_response.status}"
    assert owner.reload.super_admin?, "the last super_admin was demoted"

    operator = account("last-operator@example.com", role: :admin)
    operator_session = new_session
    sign_in(operator_session, operator)
    set_state(operator_session, owner, "disable")
    assert operator_session.last_response.status == 403,
           "an admin disabling a super_admin answered #{operator_session.last_response.status}"
    assert !owner.reload.disabled?, "the last super_admin was disabled"
  end

  check "an HTML refusal shows a flash message and changes nothing" do
    operator = account("html-operator@example.com", role: :admin)
    peer = account("html-peer@example.com", role: :admin)
    session = new_session
    sign_in(session, operator)

    session.patch("/admin/users/#{peer.id}/state", { state: "disable" })
    assert session.last_response.status == 302, "expected a redirect back, got #{session.last_response.status}"
    assert session.last_response.headers["Location"].to_s.include?("/admin/users"),
           "refusal redirected to #{session.last_response.headers["Location"].inspect}"

    session.follow_redirect!
    assert session.last_response.body.include?("super administrator"),
           "the refusal flash carried no reason: #{session.last_response.body[0, 400]}"
    assert !peer.reload.disabled?, "a refused HTML mutation changed the peer admin"
  end

  check "a disabled user cannot sign in and re-enabling restores access" do
    reader = account("revoked-reader@example.com")
    reader.update!(disabled_at: Time.current)

    session = new_session
    sign_in(session, reader)
    assert !signed_in?(session), "a disabled user signed in"
    body = followed_body(session)
    assert body.match?(/not activated|not active/i),
           "the disabled sign-in did not report an inactive account: #{body[0, 400]}"

    session = new_session
    reader.update!(disabled_at: nil)
    sign_in(session, reader)
    assert signed_in?(session), "a re-enabled user could not sign in"
  end

  check "users:promote validates its role argument and rejects unknown emails" do
    reader = account("promote-reader@example.com")

    out, err, status = run_task("users:promote", reader.email, "wizard")
    assert status && status != 0, "an invalid role did not fail: out=#{out.inspect} err=#{err.inspect}"
    assert "#{out}#{err}".include?("member, admin, super_admin"), "the invalid role error did not list the roles"
    assert reader.reload.member?, "an invalid role changed the user"

    out, err, status = run_task("users:promote", "nobody@example.com", "admin")
    assert status && status != 0, "an unknown email did not fail: out=#{out.inspect} err=#{err.inspect}"
    assert "#{out}#{err}".include?("nobody@example.com"), "the unknown email was not reported"

    out, err, status = run_task("users:promote", reader.email, "admin")
    assert status.nil?, "a valid promotion failed: out=#{out.inspect} err=#{err.inspect}"
    assert reader.reload.admin?, "users:promote did not change the role"
  end

  check "users:list reports every account" do
    active = account("list-active@example.com")
    quiet = account("list-quiet@example.com")
    quiet.update!(disabled_at: Time.current)

    out, err, status = run_task("users:list")
    assert status.nil?, "users:list failed: err=#{err.inspect}"
    assert out.include?(active.email), "users:list omitted #{active.email}"
    assert out.include?(quiet.email), "users:list omitted #{quiet.email}"
    assert out.include?("disabled"), "users:list did not mark the disabled account"
  end
end
