require "time"
require "uri"

require_relative "article_extractor"
require_relative "deepseek_summarizer"
require_relative "quality_score"
require_relative "safe_fetcher"
require_relative "source_gate"
require_relative "url_key"

# Runs one ingestion pass across the injected source adapters.
#
# Adapters and the gate are required, never defaulted: there is no built-in
# source, no implicit Hacker News fallback, and no discovery of a source from a
# URL. Every candidate — from an adapter, from an embedded link inside a feed,
# or replayed from the retry file — must be admitted by the SourceGate before
# any fetch happens for it.
class IngestBatch
  MAX_REASON = 300

  def initialize(adapters:, gate:, fetcher: SafeFetcher.new, summarizer:,
    extractor: ArticleExtractor.new, now: -> { Time.now.utc }, secrets: [], meter: nil)
    @adapters = adapters
    @gate = gate
    @fetcher = fetcher
    @summarizer = summarizer
    @extractor = extractor
    @now = now
    @secrets = secrets
    @meter = meter
  end

  def run(feed: "new", limit: 10, archive_rows: [], retry_entries: [])
    if @summarizer.nil? && !@adapters.empty?
      raise ArgumentError, "A summarizer is required when a source adapter is present"
    end

    report = SourceGate::Report.new
    archive_urls, archived_discussions = archive_keys(archive_rows)
    candidates = {}
    skipped = 0

    Array(retry_entries).each do |entry|
      retry_entry = normalize_retry(entry)
      next unless retry_entry

      story = retry_entry[:story]
      resolved = @gate.admit(story)
      if resolved.dropped?
        report.add(source: story["source"], url: story["url"], reason: resolved.reason)
        next
      end

      key = UrlKey.call(story["url"])
      external_id = story["external_id"]&.to_s
      if archive_urls.include?(key) || (external_id && archived_discussions.include?(external_id))
        skipped += 1
        next
      end
      candidates[key] ||= retry_entry.merge(story: gated_story(story, resolved))
    end

    each_admitted_source(report) do |source, adapter|
      per_source_limit = [limit, source.max_items].min
      adapter.collect_candidates(feed: feed, limit: per_source_limit, archive_rows: archive_rows)
        .each do |story|
          next unless story.is_a?(Hash)

          resolved = @gate.admit(story)
          if resolved.dropped?
            report.add(source: story["source"], url: story["url"], reason: resolved.reason)
            next
          end

          story = gated_story(story, resolved)
          key = UrlKey.call(story["url"])
          next unless key

          existing = candidates[key]
          candidates[key] = if existing
            { story: existing[:story].merge(story), record: existing[:record], attempts: existing[:attempts] }
          else
            { story: story, record: nil, attempts: 0 }
          end
        end
    end

    records = []
    failures = []
    produced = []
    model_calls = 0
    budget_stopped = false

    candidates.each_value do |candidate|
      story = candidate[:story]
      key = UrlKey.call(story["url"])

      # Ask before each story that needs a summary, so a run stops cleanly at
      # the cap and leaves the rest of the list for the next day.
      if candidate[:record].nil? && @meter&.exhausted?
        budget_stopped = true
        break
      end

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
        @meter&.record(summaries: 1, cost_usd: summary["cost_usd"].to_f)
        usage = summary["usage"].is_a?(Hash) ? summary["usage"] : {}
        record = valid_record(
          "url" => final_url,
          "title" => title,
          "summary" => summary["summary"],
          "depth" => summary["depth"],
          "publisher" => publisher,
          "topics" => summary["topics"],
          # The gate decided the source; nothing is defaulted here.
          "source" => story["source"],
          "external_id" => story["external_id"].to_s,
          "discovery_url" => story["discovery_url"],
          "published_date" => extracted[:published_date],
          "quality_score" => summary["quality_score"],
          "quality_status" => summary["quality_status"],
          "summary_cost_usd" => summary["cost_usd"].to_f,
          "summary_input_tokens" => usage["prompt_tokens"].to_i,
          "summary_output_tokens" => usage["completion_tokens"].to_i,
          "summary_cache_read_tokens" => usage["prompt_cache_hit_tokens"].to_i
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

    { records: records, failures: failures, skipped_archived: skipped,
      model_calls: model_calls, budget_stopped: budget_stopped, source_gate: report }
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

    record.merge("url" => url).merge(quality_attributes(record))
  end

  # A record replayed from the retry file may predate quality scoring, so the
  # score is normalized here too: the archive always receives an integer on the
  # 1-100 scale and a status that says whether the model produced it.
  def quality_attributes(record)
    quality = QualityScore.normalize(record["quality_score"])
    status = record["quality_status"].to_s
    status = quality.status unless QualityScore::STATUSES.include?(status)

    { "quality_score" => quality.value, "quality_status" => status }
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

  # Polls only sources the gate admits. A disabled or unregistered adapter in
  # the map is never called; the refusal is reported instead.
  def each_admitted_source(report)
    @adapters.each do |name, adapter|
      resolved = @gate.admit_source(name)
      if resolved.dropped?
        report.add(source: name, url: nil, reason: resolved.reason)
        next
      end

      yield resolved.source, adapter
    end
  end

  def archive_keys(archive_rows)
    urls = []
    discussions = []
    @adapters.each_value do |adapter|
      known_urls, known_discussions = adapter.archive_keys(archive_rows)
      urls |= Array(known_urls)
      discussions |= Array(known_discussions)
    end
    [urls, discussions]
  end

  # Carry the allowlist's spelling of the source onto the story, so a record
  # names the registered source even when the adapter used different casing.
  def gated_story(story, resolved)
    story.merge("source" => resolved.source.name)
  end

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
