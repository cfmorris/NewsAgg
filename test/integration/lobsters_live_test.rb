require "json"
require "stringio"
require "tmpdir"

require_relative "../../config/environment"
require_relative "../../app/services/import_records"
require_relative "../../app/services/ingestion_runner"
require_relative "../support/assertions"

# Live end-to-end check against the real Lobsters API and real article pages.
#
# The deterministic suite (lobsters_test.rb) runs in CI with recorded fixtures;
# this one is opt-in because it depends on a third party being reachable and
# answering. It still needs no LLM provider: the summary step is stubbed, so the
# run proves the source poll, the gate, article fetching, extraction and the
# archive import without spending tokens.
unless ENV["NEWSAGG_LIVE_LOBSTERS"] == "1"
  puts "skipped - set NEWSAGG_LIVE_LOBSTERS=1 to poll the live Lobsters API"
  exit 0
end

class LiveSummarizer
  def summarize(url:, title:, publisher:, text:)
    { "summary" => "Live adapter check: the article was fetched, extracted and summarized " \
        "through the same batch the fixture suite covers.",
      "depth" => "Overview", "topics" => ["Software Engineering"], "cost_usd" => 0.0 }
  end
end

# Records every URL the real fetcher is asked for, then delegates to it.
class LiveRecordingFetcher
  attr_reader :calls

  def initialize(inner: SafeFetcher.new)
    @inner = inner
    @calls = []
  end

  def fetch(url)
    @calls << url
    @inner.fetch(url)
  end
end

class LiveArchive
  def initialize
    @rows = []
  end

  attr_reader :rows

  def articles
    @rows
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  def sync_sources(_sources); 0; end

  def recompute_source_costs; 0; end

  def import(records)
    records.each do |record|
      @rows << record.merge(
        "sources" => [record["source"]],
        "discoveries" => [{ "source" => record["source"], "url" => record["discovery_url"] }]
      )
    end
    records.length
  end
end

TestReport.run do
  Dir.mktmpdir("newsagg-lobsters-live-") do |directory|
    allowlist_path = File.join(directory, "sources.yml")
    File.write(allowlist_path, <<~YAML)
      sources:
        - id: lobsters
          name: Lobsters
          kind: api
          url: https://lobste.rs/hottest.json
          max_items: 5
          min_words: 40
    YAML
    registry = SourceRegistry.load(path: allowlist_path)
    archive = LiveArchive.new
    fetcher = LiveRecordingFetcher.new
    err = StringIO.new

    runner = IngestionRunner.new(
      archive: archive, retry_path: File.join(directory, "retry.json"),
      summarizer: LiveSummarizer.new, fetcher: fetcher, out: StringIO.new, err: err,
      env: {}, registry: registry, http: HttpClient.new,
      importer: ImportRecords.new(archive: archive, registry: registry)
    )
    runner.run(feed: "new", limit: 5)

    check "a live Lobsters poll imports at least one article end to end" do
      imported = archive.rows.select { |row| row["source"] == "Lobsters" }
      puts "    fetches: #{fetcher.calls.inspect}"
      puts "    imported: #{imported.map { |row| row["title"] }.inspect}"
      puts "    runner: #{runner.last_result.inspect}"
      puts "    stderr: #{err.string.lines.last.to_s.strip.inspect}"
      assert(!imported.empty?, "the live run imported no articles")
      record = imported.first
      assert(record["url"].start_with?("http"), "imported URL was #{record["url"].inspect}")
      assert(!record["url"].start_with?("https://lobste.rs/s/"),
        "an article record points at a discussion page: #{record["url"].inspect}")
      assert(record["discovery_url"].start_with?("https://lobste.rs/s/"),
        "the record lost its discussion URL: #{record["discovery_url"].inspect}")
      assert(!record["summary"].to_s.empty?, "the record has no summary")
      assert(fetcher.calls.none? { |url| url.start_with?("https://lobste.rs/s/") },
        "the run fetched a discussion page: #{fetcher.calls.inspect}")
    end
  end
end
