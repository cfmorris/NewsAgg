# Devise configuration for the accounts work. MFA is optional: the
# two_factor_authenticatable strategy is loaded but no user requires a second
# factor until otp_required_for_login is turned on for them.
Devise.setup do |config|
  config.mailer_sender = ENV.fetch("NEWSAGG_MAILER_SENDER", "accounts@newsagg.local")

  # Random per boot is fine for signing in; production should pin a value so
  # tokens survive a restart.
  config.secret_key = ENV.fetch("DEVISE_SECRET_KEY") { SecureRandom.hex(64) }

  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.skip_session_storage = [:http_auth]
  config.stretches = Rails.env.test? ? 1 : 12
  config.reconfirmable = false
  config.expire_all_remember_me_on_sign_out = true
  config.password_length = 8..128
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/
  config.reset_password_within = 6.hours
  config.sign_out_via = :delete

  # Devise reads these to populate the OAuth-ready users.provider/uid columns
  # once a strategy exists. No strategy is configured in this card.
  config.omniauth_path_prefix = "/users/auth"
end
