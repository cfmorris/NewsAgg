require "json"
require "uri"

require_relative "article_extractor"
require_relative "archive"
require_relative "auto_pull_policy"
require_relative "deepseek_summarizer"
require_relative "hacker_news_client"
require_relative "import_records"
require_relative "ingest_batch"
require_relative "lobsters_client"
require_relative "retry_store"
require_relative "safe_fetcher"
require_relative "source_gate"
require_relative "source_registry"

# Coordinates one or many ingestion passes for the background worker.
#
# Adapters are built from the source allowlist, one per enabled registry entry,
# and the gate they hand candidates to is the same allowlist. Nothing is
# fetched for a candidate the gate refuses, and there is no built-in source: an
# empty or source-less allowlist runs nothing.
class IngestionRunner
  DEFAULT_RETRY_PATH = File.expand_path("../../tmp/hn-retry.json", __dir__)

  # Facts about the last run, for the Auto-pull supervisor: how much it
  # summarized and spent, and how it failed if it did.
  attr_reader :last_result

  def initialize(archive: Archive.new, retry_path: DEFAULT_RETRY_PATH, http: HttpClient.new,
    fetcher: SafeFetcher.new, now: -> { Time.now.utc }, out: $stdout, err: $stderr,
    env: ENV, summarizer: nil, importer: nil, batch: nil, meter: nil,
    registry: nil, adapters: nil)
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
    @registry = registry
    @adapters = adapters
    @last_result = nil
  end

  def run(feed: "new", limit: 10, dry_run: false)
    archive_rows = @archive.articles
    retry_entries = @retry_store.read
    secrets = [@env["DEEPSEEK_API_KEY"], @env["NEO4J_PASSWORD"]]
    registry = @registry || SourceRegistry.current
    gate = SourceGate.new(registry: registry)
    adapters = @adapters || adapters_for(registry)

    batch = @batch || IngestBatch.new(
      adapters: adapters, gate: gate, fetcher: @fetcher,
      summarizer: @summarizer || summarizer_for(adapters),
      now: @now, secrets: secrets, meter: @meter
    )
    result = batch.run(feed: feed, limit: limit, archive_rows: archive_rows, retry_entries: retry_entries)
    report = result[:source_gate] || SourceGate::Report.new
    report.lines.each { |line| @err.puts line }
    @err.puts report.summary
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
      skipped_no_article: result[:skipped_no_article].to_i,
      dropped: report.size,
      drop_reasons: report.counts.transform_keys(&:to_s),
      stopped: result[:budget_stopped] ? :budget : nil,
      failure: import_failure
    }
    @out.puts JSON.pretty_generate(result[:records])
    @err.puts "Ingestion batch: #{result[:records].length} record(s), " \
      "#{result[:skipped_archived]} already archived, " \
      "#{result[:skipped_no_article].to_i} discussion-only skipped, " \
      "#{failures.length} kept for retry, #{report.size} dropped by the source gate."
    failures.empty? ? 0 : 1
  end

  # One adapter per enabled allowlist entry. A source with no adapter yet is
  # reported, never silently replaced by a built-in one.
  def adapters_for(registry)
    registry.enabled.each_with_object({}) do |source, adapters|
      adapter = adapter_for(source)
      if adapter
        adapters[source.name] = adapter
      else
        @err.puts "source gate: enabled source #{source.name.inspect} (kind=#{source.kind}) " \
          "has no adapter and contributes no candidates"
      end
    end
  end

  private

  # An empty allowlist runs nothing, so it must not need an LLM provider just
  # to discover there is nothing to do. Any real source still requires one.
  def summarizer_for(adapters)
    return nil if adapters.empty?

    DeepseekSummarizer.new(env: @env, http: @http)
  end

  def adapter_for(source)
    return nil unless source.api?

    if hacker_news_api?(source.url)
      HackerNewsClient.new(name: source.name, http: @http, api: source.url.to_s.chomp("/"))
    elsif lobsters_api?(source.url)
      LobstersClient.new(name: source.name, http: @http, feed_url: source.url.to_s)
    end
  end

  def hacker_news_api?(url)
    url.to_s.start_with?(HackerNewsClient::API)
  end

  def lobsters_api?(url)
    URI.parse(url.to_s).host.to_s.downcase == URI.parse(LobstersClient::FEED_URL).host
  rescue URI::InvalidURIError
    false
  end

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
