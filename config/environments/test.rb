# Tests never send mail: Devise's reset instructions land in
# ActionMailer::Base.deliveries instead of an SMTP server.
Rails.application.configure do
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  config.action_controller.allow_forgery_protection = false
end
