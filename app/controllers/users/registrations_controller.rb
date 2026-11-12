# Sign-up otherwise runs entirely through Devise; this subclass exists so the
# "Welcome! You have signed up successfully." notice can be dropped. See
# QuietWelcomeFlashes for why, and for what is deliberately still shown.
module Users
  class RegistrationsController < Devise::RegistrationsController
    include QuietWelcomeFlashes
  end
end
