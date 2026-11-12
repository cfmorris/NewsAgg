require "bundler/setup"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module NewsArchive
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = Rails.env.production?
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }
  end
end
