require_relative "article_extractor"
require_relative "long_form"

# Reads the allowed topic labels from the seeded Neo4j taxonomy.
class Taxonomy
  DEFAULT_PATH = File.expand_path("../../db/seed-taxonomy.cypher", __dir__)

  # Tags the pipeline assigns itself from facts it already has. They are seeded
  # as topics so they group and filter like any other, but they are never
  # offered to the model: a subject topic is a judgement, "Long form" is not.
  ASSIGNED = [LongForm::TAG].freeze

  def self.load(path = DEFAULT_PATH)
    source = File.read(path)
    topics = []
    source.scan(/tag\s*:\s*"([^"]+)"/) do |match|
      topic = ArticleExtractor.new.clean_text(match.first, 120)
      next if topic.empty? || topics.include?(topic) || ASSIGNED.include?(topic)

      topics << topic
    end
    raise "The taxonomy file has no topic tags." if topics.empty?

    topics
  end
end
