require "json"
require "uri"

require_relative "article_extractor"
require_relative "archive"
require_relative "auto_pull_policy"
require_relative "deepseek_summarizer"
require_relative "hacker_news_client"
require_relative "import_records"
require_relative "ingest_batch"
require_relative "retry_store"
require_relative "safe_fetcher"

# Coordinates one or many ingestion passes for the background worker.
class IngestionRunner
  DEFAULT_RETRY_PATH = File.expand_path("../../tmp/hn-retry.json", __dir__)

  # Facts about the last run, for the Auto-pull supervisor: how much it
  # summarized and spent, and how it failed if it did.
  attr_reader :last_result

  def initialize(archive: Archive.new, retry_path: DEFAULT_RETRY_PATH, http: HttpClient.new,
    fetcher: SafeFetcher.new, now: -> { Time.now.utc }, out: $stdout, err: $stderr,
    env: ENV, summarizer: nil, importer: nil, batch: nil, meter: nil)
    @archive = archive
    @retry_store = RetryStore.new(retry_path)
    @http = http
    @fetcher = fetcher
    @now = now
    @out = out
    @err = err
    @env = env
    @summarizer = summarizer
    @importer = importer || ImportRecords.new(archive: archive)
    @batch = batch
    @meter = meter
    @last_result = nil
  end

  def run(feed: "new", limit: 10, dry_run: false)
    archive_rows = @archive.articles
    retry_entries = @retry_store.read
    secrets = [@env["DEEPSEEK_API_KEY"], @env["NEO4J_PASSWORD"]]

    batch = @batch || IngestBatch.new(
      hn: HackerNewsClient.new(http: @http), fetcher: @fetcher,
      summarizer: @summarizer || DeepseekSummarizer.new(env: @env, http: @http),
      now: @now, secrets: secrets, meter: @meter
    )
    result = batch.run(feed: feed, limit: limit, archive_rows: archive_rows, retry_entries: retry_entries)
    failures = result[:failures].dup
    import_failure = nil

    if result[:records].any? && !dry_run
      begin
        imported = @importer.call(result[:records])
        @err.puts "Imported #{imported} discovery records"
      rescue StandardError => error
        detail = redact("#{failure_reason(error, secrets)}", secrets)[0, 500]
        import_failure = {
          kind: AutoPull::Failure.classify(error).to_s,
          message: detail,
          retry_after: AutoPull::Failure.retry_after(error)
        }
        failures.concat(result[:records].map do |record|
          {
            "story" => story_for(record),
            "record" => record,
            "reason" => "import failed: #{detail}",
            "attempts" => 1,
            "failed_at" => @now.call.utc.iso8601
          }
        end)
      end
    end

    @retry_store.write(failures) unless dry_run
    @last_result = {
      summaries: result[:model_calls].to_i,
      cost_usd: @meter ? @meter.cost_usd : 0.0,
      new_stories: result[:records].length,
      stopped: result[:budget_stopped] ? :budget : nil,
      failure: import_failure
    }
    @out.puts JSON.pretty_generate(result[:records])
    @err.puts "Hacker News batch: #{result[:records].length} record(s), " \
      "#{result[:skipped_archived]} already archived, #{failures.length} kept for retry."
    failures.empty? ? 0 : 1
  end

  private

  def story_for(record)
    story = {
      "url" => record["url"], "title" => record["title"],
      "source" => record["source"], "external_id" => record["external_id"]
    }
    story["discovery_url"] = record["discovery_url"] if record["discovery_url"]
    story
  end

  def failure_reason(error, secrets)
    text = error.respond_to?(:message) ? error.message.to_s : error.to_s
    ArticleExtractor.new.clean_text(redact(text, secrets), 300)
  end

  def redact(value, secrets)
    text = String(value)
    secrets.each do |secret|
      text = text.split(secret).join("[redacted]") if secret.is_a?(String) && secret.length >= 4
    end
    text
  end
end
