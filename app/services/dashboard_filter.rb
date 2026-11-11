require "time"

# Applies the dashboard's search, date, facet and topic filters and counts.
class DashboardFilter
  DATE_PRESETS = {
    "3" => 3, "12" => 12, "24" => 24, "72" => 72,
    "168" => 168, "336" => 336, "720" => 720
  }.freeze

  DATE_PRESET_LABELS = {
    "3" => "Last 3 hours", "12" => "Last 12 hours", "24" => "Last 24 hours",
    "72" => "Last 3 days", "168" => "Last week", "336" => "Last 2 weeks",
    "720" => "Last month"
  }.freeze

  FIELDS = %w[publisher source depth].freeze

  attr_reader :selected_topic, :selected_heading

  def initialize(articles, params, now: -> { Time.now.utc })
    @articles = Array(articles)
    @params = params
    @now = now
    @selected_topic = params[:topic].to_s.strip
    @selected_heading = params[:heading].to_s.strip
  end

  def matching
    @matching ||= @articles.select do |article|
      matches_search?(article) &&
        FIELDS.all? { |field| !value(field).empty? ? filter_values(article, field).include?(value(field)) : true } &&
        matches_date_preset?(article) &&
        matches_date?(article, params_value(:date_from), params_value(:date_through)) &&
        matches_date?(article, params_value(:published_from), params_value(:published_through), key: "published_date")
    end
  end

  def visible
    matching.select do |article|
      if !selected_topic.empty?
        Array(article["topics"]).include?(selected_topic)
      else
        selected_heading.empty? || matches_heading?(article, selected_heading)
      end
    end
  end

  def count_text
    count = visible.length
    label = "#{count} #{count == 1 ? "article" : "articles"}"
    suffix = selected_topic.empty? ? selected_heading : selected_topic
    suffix.empty? ? label : "#{label} · #{suffix}"
  end

  def all_count
    matching.length
  end

  def topic_tree
    @topic_tree ||= begin
      groups.filter_map do |heading, topics|
        total = matching.count { |article| matches_heading?(article, heading) }
        next if total.zero? && selected_heading != heading

        {
          heading: heading,
          count: total,
          selected: selected_heading == heading && selected_topic.empty?,
          expanded: selected_heading == heading,
          topics: topics.filter_map do |topic|
            count = matching.count { |article| Array(article["topics"]).include?(topic) }
            next if count.zero? && selected_topic != topic

            { name: topic, count: count, selected: selected_topic == topic }
          end
        }
      end
    end
  end

  def options(field)
    values = @articles.flat_map { |article| filter_values(article, field) }.compact.reject(&:empty?).uniq.sort
    current = value(field)
    values << current if !current.empty? && !values.include?(current)
    values
  end

  def value(field)
    @params[field].to_s.strip
  end

  def params_value(key)
    @params[key].to_s.strip
  end

  private

  def matches_search?(article)
    terms = @params[:q].to_s.strip.downcase.split(/\s+/).reject(&:empty?)
    return true if terms.empty?

    searchable = [
      article["title"], article["summary"], article["publisher"], *Array(article["topics"])
    ].compact.join(" ").downcase
    terms.all? { |term| searchable.include?(term) }
  end

  def matches_date_preset?(article)
    hours = DATE_PRESETS[params_value(:date_preset)]
    return true unless hours

    timestamp = parse_time(article["archive_timestamp"])
    return false unless timestamp

    now = @now.call
    timestamp >= now - (hours * 3600) && timestamp <= now
  end

  def matches_date?(article, from, through, key: "archive_date")
    value = article[key].to_s
    return false if !from.empty? && (value.empty? || value < from)
    return false if !through.empty? && (value.empty? || value > through)

    true
  end

  def matches_heading?(article, heading)
    topics = groups[heading]
    return false unless topics

    Array(article["topics"]).any? { |topic| topics.include?(topic) }
  end

  def groups
    @groups ||= begin
      mapped = []
      found = {}
      @articles.each do |article|
        Array(article["topic_mappings"]).each do |mapping|
          heading = mapping["heading"].to_s
          topic = mapping["topic"].to_s
          next if heading.empty? || topic.empty?

          found[heading] ||= []
          found[heading] << topic unless found[heading].include?(topic)
          mapped << topic
        end
      end
      all_topics = @articles.flat_map { |article| Array(article["topics"]) }.compact.uniq
      unmapped = all_topics.reject { |topic| mapped.include?(topic) }
      found["Unmapped topics"] = unmapped unless unmapped.empty?
      found
    end
  end

  def filter_values(article, field)
    field == "source" ? Array(article["sources"]).compact : [article[field]]
  end

  def parse_time(value)
    return nil if value.to_s.empty?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
