require_relative "auto_pull_supervisor"
require_relative "ingestion_runner"

# Resolves the Auto-pull flag, lock and supervisor for the running process.
module AutoPull
  FLAG_NAME = "auto-pull.enabled"
  LOCK_NAME = "auto-pull-worker.lock"
  STATE_NAME = "auto-pull.state.json"
  FEED = "new"
  LIMIT = 10

  module_function

  def config
    Rails.application.config.x
  end

  def flag_path
    config.auto_pull_flag_path || Rails.root.join("tmp", FLAG_NAME)
  end

  def lock_path
    config.auto_pull_lock_path || Rails.root.join("tmp", LOCK_NAME)
  end

  def state_path
    config.auto_pull_state_path || Rails.root.join("tmp", STATE_NAME)
  end

  def enabled?
    File.file?(flag_path)
  end

  def supervisor
    config.auto_pull_supervisor
  end

  def worker_state
    supervisor&.state || { running: false, last_run_at: nil, last_error: nil, in_flight: false }
  end

  # NEWSAGG_AUTO_PULL=0 keeps the web process from pulling at all.
  def disabled_by_env?(env = ENV)
    env["NEWSAGG_AUTO_PULL"].to_s.strip == "0"
  end

  # Boots the in-process puller from config.ru and returns it, or nil when the
  # process opted out. Rails runner and the console never load config.ru, so
  # they never start a puller.
  def boot(root: Rails.root, env: ENV, runner: nil, interval: nil, err: $stderr)
    return nil if disabled_by_env?(env)

    supervisor = AutoPullSupervisor.new(
      runner: runner || ingest_runner(root: root, env: env),
      flag_path: flag_path, lock_path: lock_path, state_path: state_path,
      budget: AutoPull::Budget.from_env(env),
      interval: interval || AutoPullSupervisor::DEFAULT_INTERVAL, err: err
    )
    supervisor.start
    supervisor
  rescue StandardError => error
    err&.puts "Auto-pull supervisor could not boot: #{error.message}"
    nil
  end

  # One pull, metered so the batch can stop mid-list at the day's cap.
  def ingest_runner(root: Rails.root, env: ENV)
    lambda do |meter|
      runner = IngestionRunner.new(
        retry_path: root.join("tmp/hn-retry.json"), env: env, meter: meter
      )
      runner.run(feed: FEED, limit: LIMIT)
      runner.last_result
    end
  end
end
