require "active_support/time"
require "json"
require "net/http"
require "time"
require "uri"

class Archive
  class Unavailable < StandardError; end

  CONSTRAINTS = [
    "CREATE CONSTRAINT news_article_url IF NOT EXISTS FOR (n:NewsArticle) REQUIRE n.url IS UNIQUE",
    "CREATE CONSTRAINT news_publisher_name IF NOT EXISTS FOR (n:NewsPublisher) REQUIRE n.name IS UNIQUE",
    "CREATE CONSTRAINT news_topic_name IF NOT EXISTS FOR (n:NewsTopic) REQUIRE n.name IS UNIQUE",
    "CREATE CONSTRAINT news_discovery_id IF NOT EXISTS FOR (n:NewsDiscovery) REQUIRE (n.source, n.external_id) IS UNIQUE",
    "CREATE CONSTRAINT news_source_id IF NOT EXISTS FOR (n:NewsSource) REQUIRE n.id IS UNIQUE"
  ].freeze

  def prepare
    CONSTRAINTS.each { |statement| query(statement) }
  end

  def seed_taxonomy
    query(File.read(File.expand_path("../../db/seed-taxonomy.cypher", __dir__)))
  end

  def map_fast_subjects(mappings)
    query(<<~CYPHER, { mappings: mappings })
      UNWIND $mappings AS row
      MERGE (topic:NewsTopic {name: row.topic})
      MERGE (subject:NewsSubject {concept_id: row.uri})
      SET subject.pref_label = row.label, subject.scheme = 'OCLC FAST'
      MERGE (topic)-[mapping:BROAD_MATCH]->(subject)
      SET mapping.predicate = 'http://www.w3.org/2004/02/skos/core#broadMatch'
    CYPHER
  end

  def import(records)
    query(<<~CYPHER, { records: records })
      UNWIND $records AS row
      MERGE (article:NewsArticle {url: row.url})
      ON CREATE SET article.title = row.title, article.summary = row.summary,
                    article.depth = row.depth, article.added_at = datetime(),
                    article.quality_score = row.quality_score,
                    article.quality_status = row.quality_status,
                    article.summary_strategy = row.summary_strategy,
                    article.summary_chunk_count = row.summary_chunk_count,
                    article.summary_cost_usd = row.summary_cost_usd,
                    article.summary_input_tokens = row.summary_input_tokens,
                    article.summary_output_tokens = row.summary_output_tokens,
                    article.summary_cache_read_tokens = row.summary_cache_read_tokens,
                    article.summarized_at = datetime()
      SET article.published_date = coalesce(row.published_date, article.published_date)
      MERGE (publisher:NewsPublisher {name: row.publisher})
      MERGE (article)-[:PUBLISHED_BY]->(publisher)
      MERGE (discovery:NewsDiscovery {source: row.source, external_id: row.external_id})
      ON CREATE SET discovery.url = row.discovery_url, discovery.added_at = datetime()
      MERGE (article)-[:DISCOVERED_VIA]->(discovery)
      FOREACH (name IN row.topics |
        MERGE (topic:NewsTopic {name: name})
        MERGE (article)-[:TAGGED_WITH]->(topic))
      RETURN count(*) AS imported
    CYPHER
  end

  def articles
    query(<<~CYPHER).each do |article|
      MATCH (article:NewsArticle)
      RETURN article.title AS title, article.url AS url, article.summary AS summary,
             article.depth AS depth, toString(article.added_at) AS added_at,
             article.published_date AS published_date,
             article.quality_score AS quality_score,
             article.quality_status AS quality_status,
             article.summary_strategy AS summary_strategy,
             article.summary_chunk_count AS summary_chunk_count,
             article.summary_cost_usd AS summary_cost_usd,
             article.summary_input_tokens AS summary_input_tokens,
             article.summary_output_tokens AS summary_output_tokens,
             article.summary_cache_read_tokens AS summary_cache_read_tokens,
             toString(article.summarized_at) AS summarized_at,
             [(article)-[:PUBLISHED_BY]->(p) | p.name][0] AS publisher,
             [(article)-[:TAGGED_WITH]->(t) | t.name] AS topics,
             [(article)-[:TAGGED_WITH]->(t)-[:BROAD_MATCH]->(s:NewsSubject) |
               {topic: t.name, heading: s.pref_label, id: s.concept_id, scheme: s.scheme}] AS topic_mappings,
             [(article)-[:DISCOVERED_VIA]->(d) | d.source] AS sources,
             [(article)-[:DISCOVERED_VIA]->(d) WHERE d.url IS NOT NULL |
                {source: d.source, url: d.url}] AS discoveries
      ORDER BY article.added_at DESC, article.url
    CYPHER
      timestamp = article.delete("added_at")
      if timestamp
        added_at = Time.iso8601(timestamp.sub(/\[.*\]\z/, ""))
        article["archive_timestamp"] = added_at.iso8601
        article["archive_date"] = added_at.in_time_zone("America/New_York").to_date.iso8601
      end
    end
  end

  # Upserts one NewsSource node per allowlist entry, keyed by its stable id.
  #
  # Idempotent: MERGE on the id (backed by the news_source_id constraint)
  # means a repeated sync updates the same nodes instead of adding new ones.
  # Config-owned fields are set on every sync, so enabling or disabling a source
  # in config is reflected on the node. The derived fields - article_count,
  # cost_usd and quality_score - are only seeded on create and are deliberately
  # absent from the unconditional SET, so a re-sync never wipes them; they are
  # recomputed from the articles by #recompute_source_costs and SourceScoring.
  #
  # `enabled` is the effective fetch state, not just a copy of the config: a
  # source paused for a low score (paused_at set) stays off through a re-sync,
  # and the config's own value is kept in `configured_enabled` so resuming knows
  # what to restore. `pause_override` mirrors the registry's explicit
  # `override: true`, which exempts a source from auto-pausing; it is a separate
  # field from `override`/`override_keys`, which report config departures.
  def sync_sources(sources)
    return 0 if sources.nil? || sources.empty?

    query(<<~CYPHER, { sources: sources }).first.fetch("sources")
      UNWIND $sources AS row
      MERGE (source:NewsSource {id: row.id})
      ON CREATE SET source.article_count = 0,
                    source.cost_usd = 0.0,
                    source.quality_score = coalesce(row.quality_score, 0.0),
                    source.created_at = datetime()
      SET source.name = row.name,
          source.kind = row.kind,
          source.url = row.url,
          source.configured_enabled = row.enabled,
          source.enabled = row.enabled AND (source.paused_at IS NULL),
          source.pause_override = row.pause_override,
          source.override = row.override,
          source.override_keys = row.override_keys,
          source.max_items = row.max_items,
          source.min_words = row.min_words,
          source.domains = row.domains,
          source.exclude_domains = row.exclude_domains,
          source.synced_at = datetime()
      FOREACH (present IN CASE WHEN row.owner IS NULL THEN [] ELSE [1] END |
        SET source.owner = row.owner)
      FOREACH (absent IN CASE WHEN row.owner IS NULL THEN [1] ELSE [] END |
        REMOVE source.owner)
      RETURN count(*) AS sources
    CYPHER
  end

  # The input to a score recomputation: every materialised source with the
  # quality scores of its articles, newest first.
  #
  # Only scored articles count. A source with no scored articles comes back with
  # an empty list, so it has no score rather than a score of zero, and legacy
  # rows written before article scoring existed neither drag an average down nor
  # pad the count. An article discovered by the same source twice is counted
  # once.
  #
  # "Newest" is the import time, with the published date as the tie-break: a
  # whole batch imported in one statement shares one added_at, and only the
  # publication order says which piece in it is the later one.
  def source_quality_inputs
    scores_by_name = Hash.new { |hash, key| hash[key] = {} }
    query(<<~CYPHER).each do |row|
      MATCH (article:NewsArticle)-[:DISCOVERED_VIA]->(discovery:NewsDiscovery)
      WHERE article.quality_score IS NOT NULL
      RETURN discovery.source AS name, article.url AS url,
             article.quality_score AS score, toString(article.added_at) AS added_at
      ORDER BY added_at DESC, coalesce(article.published_date, '') DESC, url
    CYPHER
      name = row["name"]
      next if name.nil?

      scores_by_name[name][row["url"]] ||= row["score"]
    end

    query(<<~CYPHER).map do |row|
      MATCH (source:NewsSource)
      RETURN source.id AS id, source.name AS name,
             coalesce(source.pause_override, false) AS pause_override
      ORDER BY source.id
    CYPHER
      {
        "id" => row["id"],
        "name" => row["name"],
        "pause_override" => row["pause_override"],
        # Discovery rows were read newest first, and Hash preserves insertion
        # order, so this list is already ordered by article age.
        "scores" => scores_by_name[row["name"]].values
      }
    end
  end

  # Writes the computed score and article count on every source. Only these two
  # fields are touched: cost_usd is derived independently and a pause never
  # deletes an article.
  def write_source_scores(rows)
    return 0 if rows.nil? || rows.empty?

    rows = rows.map do |row|
      {
        "id" => row["id"],
        "quality_score" => row["quality_score"],
        "article_count" => row["article_count"]
      }
    end
    query(<<~CYPHER, { rows: rows }).first.fetch("sources")
      UNWIND $rows AS row
      MATCH (source:NewsSource {id: row.id})
      SET source.quality_score = row.quality_score,
          source.article_count = row.article_count,
          source.score_updated_at = datetime()
      RETURN count(*) AS sources
    CYPHER
  end

  # Pauses the sources the score says are not worth fetching: enabled=false plus
  # the recorded reason. The articles stay, so the cost of what the source
  # already contributed keeps accumulating. A node carrying pause_override stays
  # on even when it reaches this method, so an explicit registry override cannot
  # be undone by a stale decision.
  def pause_sources(rows)
    return 0 if rows.nil? || rows.empty?

    query(<<~CYPHER, { rows: rows }).first.fetch("sources")
      UNWIND $rows AS row
      MATCH (source:NewsSource {id: row.id})
      WHERE coalesce(source.pause_override, false) = false
      SET source.enabled = false,
          source.paused_at = datetime(),
          source.paused_by = 'auto',
          source.pause_reason = row.reason
      RETURN count(*) AS sources
    CYPHER
  end

  # Clears a pause, restoring the source to whatever config/sources.yml says.
  # This is the admin console's undo: it re-enables fetching for a source that
  # is still enabled in config, and leaves a source disabled in config disabled.
  # Returns the node's state, or nil when there is no such source.
  def resume_source(id)
    rows = query(<<~CYPHER, { id: id.to_s })
      MATCH (source:NewsSource {id: $id})
      SET source.enabled = coalesce(source.configured_enabled, true),
          source.resumed_at = datetime()
      REMOVE source.paused_at, source.pause_reason, source.paused_by
      RETURN source.id AS id, source.enabled AS enabled,
             coalesce(source.configured_enabled, true) AS configured_enabled
    CYPHER
    rows.first
  end

  # The ids of sources currently paused, for the pre-fetch gate.
  def paused_source_ids
    query(<<~CYPHER).map { |row| row["id"] }
      MATCH (source:NewsSource)
      WHERE source.paused_at IS NOT NULL
      RETURN source.id AS id
      ORDER BY source.id
    CYPHER
  end

  # Recomputes every NewsSource.cost_usd from the articles attributed to it.
  #
  # The total is recomputed from the articles on every call rather than
  # incremented, so calling it twice - or replaying an import - can never
  # double-count: a source's cost is exactly the sum of summary_cost_usd over
  # the articles joined to it through NewsDiscovery.source == NewsSource.name.
  #
  # A null, missing or zero article cost contributes nothing; an article that
  # carries the same source under more than one discovery is counted once; and
  # a source with no articles is set to 0.0. Sources are matched without an
  # enabled filter, so a source disabled in config keeps the historical cost of
  # the articles it already contributed instead of being reset.
  #
  # Returns the number of source nodes updated.
  def recompute_source_costs
    rows = query(<<~CYPHER)
      MATCH (source:NewsSource)
      OPTIONAL MATCH (article:NewsArticle)-[:DISCOVERED_VIA]->(discovery:NewsDiscovery)
      WHERE discovery.source = source.name
      WITH source, article, min(coalesce(article.summary_cost_usd, 0.0)) AS article_cost
      WITH source, sum(article_cost) AS total
      SET source.cost_usd = total, source.cost_updated_at = datetime()
      RETURN count(*) AS sources
    CYPHER
    rows.empty? ? 0 : rows.first.fetch("sources")
  end

  # Every materialised source, for round-trip checks and reporting.
  def source_nodes
    query(<<~CYPHER)
      MATCH (source:NewsSource)
      RETURN source.id AS id, source.name AS name, source.kind AS kind,
             source.url AS url,
             source.enabled AS enabled, source.owner AS owner,
             source.configured_enabled AS configured_enabled,
             source.quality_score AS quality_score,
             source.article_count AS article_count, source.cost_usd AS cost_usd,
             source.override AS override, source.override_keys AS override_keys,
             source.pause_override AS pause_override,
             toString(source.paused_at) AS paused_at, source.pause_reason AS pause_reason,
             source.paused_by AS paused_by,
             toString(source.score_updated_at) AS score_updated_at,
             source.max_items AS max_items, source.min_words AS min_words,
             source.domains AS domains, source.exclude_domains AS exclude_domains,
             toString(source.synced_at) AS synced_at
      ORDER BY source.id
    CYPHER
  end

  # Runs one Cypher statement against the archive. Public because the
  # integration tests need to read and seed state the typed accessors above do
  # not expose.
  def query(statement, parameters = {})
    database = ENV.fetch("NEO4J_DATABASE", "neo4j")
    endpoint = URI.join(ENV.fetch("NEO4J_HTTP_URL", "http://127.0.0.1:7474"), "/db/#{URI.encode_www_form_component(database)}/query/v2")
    request = Net::HTTP::Post.new(endpoint)
    request.basic_auth(ENV.fetch("NEO4J_USER", "neo4j"), ENV.fetch("NEO4J_PASSWORD"))
    request.content_type = "application/json"
    request.body = JSON.generate(statement: statement, parameters: parameters)
    response = Net::HTTP.start(endpoint.host, endpoint.port, use_ssl: endpoint.scheme == "https",
      open_timeout: 3, read_timeout: 30) { |http| http.request(request) }
    raise Unavailable, "Neo4j returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    result = JSON.parse(response.body)
    if result["errors"]&.any?
      raise Unavailable, result["errors"].map { |error| error["message"] }.join(", ")
    end
    data = result["data"]
    data ? data.fetch("values").map { |row| data.fetch("fields").zip(row).to_h } : []
  rescue KeyError, SystemCallError, IOError, SocketError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => error
    raise Unavailable, error.message
  end
end
