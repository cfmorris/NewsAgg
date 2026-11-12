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
    "CREATE CONSTRAINT news_discovery_id IF NOT EXISTS FOR (n:NewsDiscovery) REQUIRE (n.source, n.external_id) IS UNIQUE"
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

  private

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
