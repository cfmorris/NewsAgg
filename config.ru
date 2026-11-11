require_relative "config/environment"
require_relative "app/services/auto_pull"

# Auto-pull runs inside the web process. Rails runner and the console load only
# config/environment, so they never start a puller. NEWSAGG_AUTO_PULL=0 opts out.
Rails.application.config.x.auto_pull_supervisor = AutoPull.boot

run Rails.application
