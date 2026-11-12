require "time"

require_relative "../services/auto_pull"

module DashboardHelper
  # Builds a dashboard URL that keeps the current filters and applies overrides.
  def filter_link(overrides = {})
    query = request.query_parameters.merge(overrides.transform_keys(&:to_s))
    query = query.reject { |_key, value| value.nil? || value.to_s.empty? }
    query.empty? ? dashboard_path : "#{dashboard_path}?#{query.to_query}"
  end

  def share(total)
    denominator = @filter.all_count
    denominator.zero? ? 0 : (100.0 * total / denominator).round(2)
  end

  # The article's 1-100 quality score as a card label, or nil for an article
  # written before scores existed. A clamped or defaulted score says so, so a
  # substituted number never reads as the model's own judgement.
  def quality_label(article)
    score = article["quality_score"]
    return nil if score.nil? || score.to_s.empty?

    label = "Quality #{score.to_i}"
    case article["quality_status"].to_s
    when "clamped" then "#{label} (clamped)"
    when "default" then "#{label} (default)"
    else label
    end
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

  # Why the next pull is on hold, in the dashboard's own words, or nil when the
  # puller is free to run.
  def auto_pull_pause_text(state = auto_pull_worker_state)
    case state[:reason].to_s
    when "budget"
      "Paused: daily budget reached"
    when "backoff"
      retry_at = state[:retry_at]
      return "Paused: Neo4j unreachable, retrying" if retry_at.nil? || retry_at.to_s.empty?

      "Paused: Neo4j unreachable, retrying #{Time.iso8601(retry_at.to_s).getlocal.strftime("%H:%M")}"
    when "config"
      "Paused: check the Neo4j configuration"
    end
  rescue ArgumentError
    "Paused: Neo4j unreachable, retrying soon"
  end
end
