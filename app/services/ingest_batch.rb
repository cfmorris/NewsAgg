require "time"

require_relative "article_extractor"
require_relative "deepseek_summarizer"
require_relative "hacker_news_client"
require_relative "safe_fetcher"
require_relative "url_key"

# Runs one Hacker News ingestion pass with retries kept for the next batch.
class IngestBatch
  MAX_REASON = 300

  def initialize(hn: HackerNewsClient.new, fetcher: SafeFetcher.new, summarizer:,
    extractor: ArticleExtractor.new, now: -> { Time.now.utc }, secrets: [])
    @hn = hn
    @fetcher = fetcher
    @summarizer = summarizer
    @extractor = extractor
    @now = now
    @secrets = secrets
  end

  def run(feed: "new", limit: 10, archive_rows: [], retry_entries: [])
    archive_urls, archived_discussions = @hn.archive_keys(archive_rows)
    candidates = {}
    skipped = 0

    Array(retry_entries).each do |entry|
      retry_entry = normalize_retry(entry)
      next unless retry_entry

      key = UrlKey.call(retry_entry[:story]["url"])
      external_id = retry_entry[:story]["external_id"]&.to_s
      if archive_urls.include?(key) || (external_id && archived_discussions.include?(external_id))
        skipped += 1
        next
      end
      candidates[key] ||= retry_entry
    end

    @hn.collect_candidates(feed: feed, limit: limit, archive_rows: archive_rows).each do |story|
      key = UrlKey.call(story["url"])
      next unless key

      existing = candidates[key]
      candidates[key] = if existing
        { story: existing[:story].merge(story), record: existing[:record], attempts: existing[:attempts] }
      else
        { story: story, record: nil, attempts: 0 }
      end
    end

    records = []
    failures = []
    produced = []
    model_calls = 0

    candidates.each_value do |candidate|
      story = candidate[:story]
      key = UrlKey.call(story["url"])

      if candidate[:record]
        if archive_urls.include?(key) || produced.include?(key)
          skipped += 1
          next
        end
        produced << key
        records << candidate[:record]
        next
      end

      begin
        if archive_urls.include?(key)
          skipped += 1
          next
        end

        page = @fetcher.fetch(story["url"])
        final_url = UrlKey.call(page[:url]) || key
        raise "Article has no usable canonical URL" unless final_url
        if archive_urls.include?(final_url) || produced.include?(final_url)
          skipped += 1
          next
        end

        extracted = @extractor.extract(page[:body], URI.parse(final_url), content_type: page[:content_type])
        title = @extractor.sanitize_title(story["title"])
        raise "Story has no usable title" if title.empty?

        publisher = @extractor.sanitize_publisher(extracted[:publisher], URI.parse(final_url).hostname.to_s.sub(/\Awww\./i, ""))
        raise "Article has no usable publisher" if publisher.empty?
        raise "Article text is too short" if extracted[:text].to_s.length < 40

        model_calls += 1
        summary = @summarizer.summarize(
          url: final_url, title: title, publisher: publisher, text: extracted[:text]
        )
        record = valid_record(
          "url" => final_url,
          "title" => title,
          "summary" => summary["summary"],
          "depth" => summary["depth"],
          "publisher" => publisher,
          "topics" => summary["topics"],
          "source" => story["source"] || "Hacker News",
          "external_id" => story["external_id"].to_s,
          "discovery_url" => story["discovery_url"],
          "published_date" => extracted[:published_date]
        )
        raise "Summary did not match the importer contract" unless record

        produced << final_url
        records << record
      rescue StandardError => error
        failures << {
          "story" => story_for_record(story),
          "record" => nil,
          "reason" => failure_reason(error),
          "attempts" => candidate[:attempts] + 1,
          "failed_at" => @now.call.utc.iso8601
        }
      end
    end

    { records: records, failures: failures, skipped_archived: skipped, model_calls: model_calls }
  end

  def valid_record(record)
    return nil unless record.is_a?(Hash)

    url = UrlKey.call(record["url"])
    required = %w[title summary depth publisher source external_id]
    return nil unless url
    return nil unless required.all? { |key| record[key].is_a?(String) && !record[key].strip.empty? }
    return nil unless DeepseekSummarizer::DEPTHS.include?(record["depth"])
    return nil unless record["topics"].is_a?(Array) && !record["topics"].empty?
    return nil unless record["topics"].all? { |topic| topic.is_a?(String) && !topic.strip.empty? }

    record.merge("url" => url)
  end

  def failure_reason(error)
    text = clean_text(redact(error.respond_to?(:message) ? error.message : error.to_s), MAX_REASON)
    text.empty? ? "Unknown ingestion failure" : text
  end

  def story_for_record(record)
    story = {
      "url" => record["url"], "title" => record["title"],
      "source" => record["source"], "external_id" => record["external_id"]
    }
    story["discovery_url"] = record["discovery_url"] if record["discovery_url"]
    story
  end

  def redact(value)
    text = String(value)
    @secrets.each do |secret|
      text = text.split(secret).join("[redacted]") if secret.is_a?(String) && secret.length >= 4
    end
    text
  end

  private

  def normalize_retry(entry)
    return nil unless entry.is_a?(Hash)

    story = entry["story"].is_a?(Hash) ? entry["story"] : entry
    return nil unless story.is_a?(Hash) && UrlKey.call(story["url"])

    {
      story: story,
      record: entry["record"].is_a?(Hash) ? valid_record(entry["record"]) : nil,
      attempts: entry["attempts"].is_a?(Integer) && entry["attempts"].positive? ? entry["attempts"] : 0
    }
  end

  def clean_text(value, limit)
    ArticleExtractor.new.clean_text(value, limit)
  end
end
