# Production mail goes out over SMTP; the host, port and credentials come from
# the environment. Encryption keys are read from the environment in
# config/application.rb.
Rails.application.configure do
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.smtp_settings = {
    address: ENV.fetch("SMTP_ADDRESS", "localhost"),
    port: Integer(ENV.fetch("SMTP_PORT", "587")),
    user_name: ENV["SMTP_USER_NAME"],
    password: ENV["SMTP_PASSWORD"],
    authentication: ENV["SMTP_USER_NAME"] ? :plain : nil,
    enable_starttls_auto: true
  }
end
