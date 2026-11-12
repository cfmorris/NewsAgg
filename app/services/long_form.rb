# Decides the deterministic "Long form" topic from the length of the text that
# was actually extracted.
#
# The tag is never model output. It is not offered to the model as a topic, the
# model's own topics are stripped of it, and it is added only from the extracted
# length - so it stays a filterable fact about how much there was to read
# rather than a judgement the summarizer made about the piece.
#
#   LongForm.tag_for(19_999)  # => nil
#   LongForm.tag_for(20_000)  # => "Long form"
#   LongForm.topics(["Software Engineering"], 25_000)
#   # => ["Software Engineering", "Long form"]
module LongForm
  # Characters of extracted text from which a piece counts as long form. It is
  # deliberately above the summarizer's single-request window, so a tagged
  # article is always one that had to be read in parts.
  THRESHOLD = 20_000

  TAG = "Long form"

  # The tag for a length of extracted text, or nil when the text is not long
  # enough to earn it.
  def self.tag_for(length)
    length.to_i >= THRESHOLD ? TAG : nil
  end

  # The article's topics with the long-form tag decided here, never by the
  # model: any copy the model produced is dropped first, and the tag is added
  # last so it does not displace a subject topic.
  def self.topics(topics, length)
    kept = Array(topics).compact.map { |topic| topic.to_s.strip }
      .reject { |topic| topic.empty? || topic == TAG }
    tag = tag_for(length)
    tag ? kept + [tag] : kept
  end
end
