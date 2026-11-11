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
    Rails.root.join("tmp/auto-pull.enabled").file?
  end
end
