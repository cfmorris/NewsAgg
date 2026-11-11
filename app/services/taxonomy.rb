require_relative "article_extractor"

# Reads the allowed topic labels from the seeded Neo4j taxonomy.
class Taxonomy
  DEFAULT_PATH = File.expand_path("../../db/seed-taxonomy.cypher", __dir__)

  def self.load(path = DEFAULT_PATH)
    source = File.read(path)
    topics = []
    source.scan(/tag\s*:\s*"([^"]+)"/) do |match|
      topic = ArticleExtractor.new.clean_text(match.first, 120)
      topics << topic if !topic.empty? && !topics.include?(topic)
    end
    raise "The taxonomy file has no topic tags." if topics.empty?

    topics
  end
end
