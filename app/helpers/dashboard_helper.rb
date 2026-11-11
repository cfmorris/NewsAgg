require "time"

require_relative "../services/auto_pull"

module DashboardHelper
  # Builds a dashboard URL that keeps the current filters and applies overrides.
  def filter_link(overrides = {})
    query = request.query_parameters.merge(overrides.transform_keys(&:to_s))
    query = query.reject { |_key, value| value.nil? || value.to_s.empty? }
    query.empty? ? "/" : "/?#{query.to_query}"
  end

  def share(total)
    denominator = @filter.all_count
    denominator.zero? ? 0 : (100.0 * total / denominator).round(2)
  end

  def auto_pull_enabled?
    AutoPull.enabled?
  end

  def auto_pull_worker_state
    AutoPull.worker_state
  end

  # "2026-11-11 17:30 UTC" for the last completed pull, or nil when none ran.
  def auto_pull_last_run_text
    timestamp = auto_pull_worker_state[:last_run_at]
    return nil if timestamp.nil? || timestamp.to_s.empty?

    Time.iso8601(timestamp.to_s).getlocal.strftime("%Y-%m-%d %H:%M:%S %Z")
  rescue ArgumentError
    timestamp.to_s
  end
end
