require "bundler/setup"
require "rails"
require "action_controller/railtie"

Bundler.require

module NewsArchive
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = Rails.env.production?
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }
  end
end

Rails.application.initialize!
