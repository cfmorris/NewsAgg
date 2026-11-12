# Formatting for the admin source list, shared by the console summary and the
# full source screen so both read the same.
module AdminSourcesHelper
  # The score is a decayed average, so it carries one decimal; a source with no
  # scored articles has no score at all and must not read as a zero.
  def source_quality_label(node)
    score = node["quality_score"]
    return "—" if score.nil? || node["article_count"].to_i.zero?

    format("%.1f", score.to_f)
  end

  # One word for the row's state: a paused source is disabled but was not
  # disabled by config, and the difference is what an operator acts on.
  def source_status_label(node)
    return "paused" if node["paused_at"].to_s.strip != ""
    return "enabled" if node["enabled"]

    "disabled in config"
  end

  def source_status_class(node)
    source_status_label(node).split.first
  end

  def source_cost_label(node)
    format("$%.4f", node["cost_usd"].to_f)
  end

  def source_paused?(node)
    node["paused_at"].to_s.strip != ""
  end
end
