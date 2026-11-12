require "bundler/setup"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)
# Teaches ActiveRecord::Base the `devise` class macro. Devise does not pull the
# ORM adapter in by itself when the app loads it explicitly.
require "devise/orm/active_record"

module NewsArchive
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = Rails.env.production?

    # The three public assets (dashboard.css, dashboard.js, turbo.js) are served
    # by DashboardController so they are reachable before a session exists. The
    # static file middleware would otherwise answer those paths first from
    # public/ and drop the charset, so it must stay out of the way.
    config.public_file_server.enabled = false
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }

    # Action Mailer points at nothing external by default: development logs the
    # mail and test keeps it in memory. Devise's mailer still needs a host to
    # build links from.
    config.action_mailer.default_url_options = {
      host: ENV.fetch("NEWSAGG_MAILER_HOST", "localhost"), port: 3000
    }
    config.action_mailer.raise_delivery_errors = false

    # OTP secrets are stored as a Rails encrypted attribute, so these keys must
    # be set before the User model touches the database. Production reads them
    # from the environment only; development and test fall back to clearly
    # labelled local values so the suite runs with no manual setup.
    if Rails.env.production?
      config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
      config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
      config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
    else
      config.active_record.encryption.primary_key =
        ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY") { "newsagg-local-primary-key-not-for-production" }
      config.active_record.encryption.deterministic_key =
        ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY") { "newsagg-local-deterministic-key-not-for-production" }
      config.active_record.encryption.key_derivation_salt =
        ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT") { "newsagg-local-key-derivation-salt-not-for-production" }
    end
  end
end
