# One definition of "does this session carry a user?" for the integration
# scripts, which drive Rack::Test::Session directly rather than inheriting from
# ActionDispatch::IntegrationTest.
#
# Devise ships Devise::Test::IntegrationHelpers for exactly this question, but
# its include hook installs Minitest `setup`/`teardown` hooks, so including it
# here raises NoMethodError; it needs a test-case base class these scripts do
# not have. Signing in stays what it already is: a POST to the real Devise
# route.
#
# The probe asks a route the app actually protects. /dashboard answers 200 to a
# session with a user and redirects a guest to sign-in, so it keeps telling the
# two apart even once the sign-in page itself starts redirecting. Never probe
# /users/sign_in: a guest reaches that page too.
module SignedInProbe
  def signed_in?(session)
    session.get(Rails.application.routes.url_helpers.dashboard_path)
    session.last_response.status == 200
  end
end
