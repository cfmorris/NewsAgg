# Test double for the Neo4j-backed archive used by the integration tests.
#
# This is a *method-level* seam, not a Cypher stub: it models the shapes and the
# two behaviours callers actually depend on — MERGE-by-url idempotency and
# per-source cost aggregation — so logic around the archive can be tested without
# a server. Anything it does not model raises loudly, naming the graph lane, so a
# test can never quietly pass against a fake that silently did nothing.
#
# The real query contract stays with the disposable-Neo4j suites
# (test/support/neo4j-test.sh). If you need a new method here, add it with the
# same semantics as Archive and cover it in
# test/integration/fake_archive_contract_test.rb.
class FakeArchive
  class NotModelled < NotImplementedError; end

  attr_reader :imported, :scores

  def initialize(rows = [], sources: [])
    @articles = Array(rows).dup            # seeded rows, returned untouched
    @imported = []                         # records passed to #import, in order
    @by_url = {}                           # url => imported article row
    @topics = Hash.new { |hash, url| hash[url] = [] }
    @source_rows = Array(sources).dup
    @scores = []
    @paused = []
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  # Mirrors Archive#import: MERGE on url (a re-import never overwrites fields set
  # on create), topics merge without duplicates, and a replayed import cannot
  # inflate anything.
  def import(records)
    Array(records).each do |record|
      row = stringify(record)
      url = row["url"].to_s
      next if url.empty?

      @imported << row
      @by_url[url] ||= {
        "url" => url,
        "title" => row["title"],
        "summary" => row["summary"],
        "quality_score" => row["quality_score"],
        "source" => row["source"],
        "publisher" => row["publisher"],
        "summary_cost_usd" => row["summary_cost_usd"]
      }
      Array(row["topics"]).each { |topic| @topics[url] << topic unless @topics[url].include?(topic) }
    end
    nil
  end

  def articles
    @articles + @by_url.values
  end

  def sync_sources(sources)
    @source_rows.concat(Array(sources))
  end

  def source_quality_inputs
    @source_rows
  end

  def source_nodes
    # Sources already represented (explicit or written by recompute) win — a bare
    # id/name row appended after them would otherwise clobber their attributes.
    known = @source_rows.map { |row| stringify(row)["name"] }.compact
    derived = @by_url.values.map { |row| row["source"] }.compact.uniq - known
    @source_rows + derived.map { |name| { "id" => name, "name" => name } }
  end

  def write_source_scores(rows)
    @scores.concat(Array(rows))
    nil
  end

  # Sums summary_cost_usd per source, counting each article once — the same rule
  # Archive#recompute_source_costs documents.
  def recompute_source_costs
    per_source = Hash.new(0.0)
    @by_url.each_value do |row|
      source = row["source"]
      next if source.nil? || source.to_s.empty?

      per_source[source] += row["summary_cost_usd"].to_f
    end
    per_source.each { |name, total| @source_rows << { "id" => name, "name" => name, "cost_usd" => total } }
    per_source.size
  end

  def pause_sources(rows)
    Array(rows).each do |row|
      row = stringify(row)
      @paused << (row["id"] || row["name"])
    end
    nil
  end

  def resume_source(id)
    @paused.delete(id)
    nil
  end

  def paused_source_ids
    @paused.compact.uniq.sort
  end

  def topics_for(url)
    @topics[url].dup
  end

  def query(_statement, _parameters = {})
    raise NotModelled,
          "FakeArchive does not speak Cypher. Run this suite on the graph lane " \
          "(sbx-<slug>-graph) or via test/support/neo4j-test.sh, which stands up a " \
          "disposable server."
  end

  private

  def stringify(record)
    record.to_h.transform_keys(&:to_s)
  end
end

class UnavailableArchive
  def articles
    raise Archive::Unavailable, "Neo4j is not reachable"
  end
end
