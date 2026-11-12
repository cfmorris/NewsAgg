require_relative "application"

Rails.application.initialize!

# Auto-pull settings live under tmp/; tests override these paths.
Rails.application.config.x.auto_pull_flag_path = Rails.root.join("tmp", "auto-pull.enabled")
Rails.application.config.x.auto_pull_lock_path = Rails.root.join("tmp", "auto-pull-worker.lock")
Rails.application.config.x.auto_pull_state_path = Rails.root.join("tmp", "auto-pull.state.json")
