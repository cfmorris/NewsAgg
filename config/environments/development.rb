# Mail for the accounts work goes to the log: no SMTP server is required to
# sign up or reset a password in development.
Rails.application.configure do
  config.action_mailer.delivery_method = :log
  config.action_mailer.perform_deliveries = true
end
