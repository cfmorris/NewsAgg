require "time"

# Turns the archive's article rows into every figure the broadsheet prints.
# Pure Ruby: no database access, no view helpers, no state beyond the rows given.
class InfographicDigest
  DEFAULT_TOPIC_COLUMNS = 5

  Article = Struct.new(:title, :publisher, :year, :published_date, :archive_date,
    :archive_timestamp, :depth, :topics, :sources, :url, keyword_init: true)
  Topic = Struct.new(:name, :count, :articles, keyword_init: true)
  DepthRow = Struct.new(:name, :count, :percent, keyword_init: true)
  PublisherRow = Struct.new(:name, :count, keyword_init: true)

  # Stored text can arrive as binary bytes (one publisher renders as "Ya??z Aksoy").
  # Repair it for display only; the archive itself is left untouched.
  def self.text(value)
    return "" if value.nil?

    string = value.to_s.dup
    string.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::ASCII_8BIT
    string = string.scrub("?") unless string.valid_encoding?
    string.delete("\u0000").strip
  end

  def initialize(articles, topic_columns: DEFAULT_TOPIC_COLUMNS)
    @topic_columns = topic_columns
    @articles = Array(articles).map { |row| normalize(row) }
  end

  def empty?
    article_count.zero?
  end

  def article_count
    @articles.length
  end

  def topic_count
    topics.length
  end

  def publisher_count
    publisher_rows.length
  end

  def source_count
    source_names.length
  end

  def source_names
    @source_names ||= @articles.flat_map(&:sources)
      .map { |name| self.class.text(name) }
      .reject(&:empty?)
      .uniq
      .sort
  end

  # Topics with their articles, most headlines first (ties by name).
  def topics
    @topics ||= begin
      grouped = Hash.new { |hash, key| hash[key] = [] }
      @articles.each do |article|
        article.topics.each { |topic| grouped[topic] << article }
      end
      grouped.map do |name, articles|
        Topic.new(name: name, count: articles.length, articles: sort_articles(articles))
      end.sort_by { |topic| [-topic.count, topic.name.downcase, topic.name] }
    end
  end

  def top_topics
    topics.first(@topic_columns)
  end

  def brief_topics
    topics.drop(@topic_columns)
  end

  def untagged_articles
    @untagged_articles ||= sort_articles(@articles.select { |article| article.topics.empty? })
  end

  def depth_rows
    @depth_rows ||= begin
      grouped = Hash.new(0)
      @articles.each { |article| grouped[article.depth.empty? ? "Unrated" : article.depth] += 1 }
      grouped.map { |name, count| DepthRow.new(name: name, count: count, percent: percent(count)) }
        .sort_by { |row| [-row.count, row.name.downcase] }
    end
  end

  # Publishers with more than one article, most prolific first.
  def named_publishers
    publisher_rows.select { |publisher| publisher.count > 1 }
  end

  # The long tail: publishers that appear exactly once.
  def single_publishers
    publisher_rows.select { |publisher| publisher.count == 1 }
  end

  def tail_size
    single_publishers.length
  end

  def publisher_rows
    @publisher_rows ||= begin
      grouped = Hash.new(0)
      @articles.each { |article| grouped[article.publisher] += 1 unless article.publisher.empty? }
      grouped.map { |name, count| PublisherRow.new(name: name, count: count) }
        .sort_by { |row| [-row.count, row.name.downcase, row.name] }
    end
  end

  def oldest_article
    dated = @articles.reject { |article| article.published_date.empty? }
    dated.min_by { |article| [article.published_date, article.title] }
  end

  def newest_article
    dated = @articles.reject { |article| article.published_date.empty? }
    dated.max_by { |article| [article.published_date, article.title] }
  end

  def oldest_published_date
    oldest_article&.published_date
  end

  def newest_published_date
    newest_article&.published_date
  end

  def first_imported_at
    @articles.filter_map(&:archive_timestamp).min
  end

  def last_imported_at
    @articles.filter_map(&:archive_timestamp).max
  end

  # The edition belongs to the day the newest batch landed.
  def edition_date
    @articles.filter_map(&:archive_date).reject(&:empty?).max
  end

  def percent(count)
    return 0 if article_count.zero?

    (100.0 * count / article_count).round
  end

  private

  def sort_articles(articles)
    articles.sort_by { |article| [article.published_date.empty? ? "0000-00-00" : article.published_date, article.title] }
      .reverse
  end

  def normalize(row)
    row = row.to_h
    published_date = self.class.text(row["published_date"])
    Article.new(
      title: self.class.text(row["title"]),
      publisher: self.class.text(row["publisher"]),
      published_date: published_date,
      archive_date: self.class.text(row["archive_date"]),
      archive_timestamp: parse_time(row["archive_timestamp"]),
      depth: self.class.text(row["depth"]),
      topics: Array(row["topics"]).map { |topic| self.class.text(topic) }.reject(&:empty?).uniq,
      sources: sources_for(row),
      url: self.class.text(row["url"]),
      year: published_date[0, 4]
    )
  end

  # Discovery sources live in `sources`, with `discoveries` as the richer shape.
  def sources_for(row)
    names = Array(row["sources"])
    names += Array(row["discoveries"]).map { |discovery| discovery["source"] || discovery[:source] }
    names.map { |name| self.class.text(name) }.reject(&:empty?).uniq
  end

  def parse_time(value)
    return value if value.is_a?(Time)

    string = self.class.text(value)
    return nil if string.empty?

    Time.iso8601(string)
  rescue ArgumentError
    nil
  end
end
