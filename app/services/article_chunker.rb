require_relative "article_extractor"

# Splits extracted article text into provider-sized chunks.
#
# Chunking is deterministic: the same text always yields the same chunks, so a
# re-run can be compared call for call and the strategy recorded with the
# article stays true. A document whose extracted text carries headings (the
# extractor writes them as "## Heading" lines) is split on those headings; a
# document without any falls back to fixed windows that end on a paragraph,
# sentence or word boundary when one falls late enough in the window. A hard
# chunk cap keeps one enormous document from spending without bound.
class ArticleChunker
  # The most text one provider request may carry: the window the summarizer has
  # always used.
  WINDOW = ArticleExtractor::MAX_TEXT

  # A document longer than one window is summarized in parts, so nothing is
  # silently truncated. The long-form tag has its own, higher threshold
  # (LongForm::THRESHOLD); being chunked is not the same as being long form.
  THRESHOLD = WINDOW

  # The most chunks one document may cost. ArticleExtractor::MAX_EXTRACTED_TEXT
  # is exactly this many windows, so the cap can never drop extracted text.
  MAX_CHUNKS = 10

  STRATEGIES = %w[single headings windows].freeze

  # Written by ArticleExtractor for every <h1>-<h6>: "## Heading" on its own line.
  HEADING_LINE = /\A\#{1,6}\s+\S/

  # How late in a window a natural break must sit to be used. An earlier break
  # would waste too much of the window, so the hard cut wins instead.
  MIN_BREAK_SHARE = 0.6

  Plan = Struct.new(:strategy, :chunks) do
    def single? = strategy == "single"
    def chunk_count = chunks.length
  end

  def call(text)
    body = text.to_s
    return Plan.new("single", [body]) if body.length <= THRESHOLD

    strategy = headings?(body) ? "headings" : "windows"
    Plan.new(strategy, pieces(body, heading_breaks: strategy == "headings").first(MAX_CHUNKS))
  end

  # The marker stored on the article: which strategy produced the summary and
  # how many parts it was read in. Normalized here so a record replayed from an
  # older retry file still carries a known strategy and a positive count.
  def self.metadata(strategy, chunk_count)
    name = STRATEGIES.include?(strategy.to_s) ? strategy.to_s : "single"
    count = chunk_count.to_i
    count = 1 if name == "single" || count < 1
    { "summary_strategy" => name, "summary_chunk_count" => count }
  end

  private

  def headings?(body)
    body.each_line.any? { |line| HEADING_LINE.match?(line) }
  end

  # Splits text into windows no longer than WINDOW, cutting at the last natural
  # break that still fills enough of the window.
  def pieces(text, heading_breaks: false)
    rest = text.to_s.strip
    out = []
    while rest.length > WINDOW
      cut = break_point(rest, heading_breaks: heading_breaks)
      out << rest[0, cut].strip
      rest = rest[cut..].to_s.lstrip
    end
    out << rest unless rest.empty?
    out.reject(&:empty?)
  end

  def break_point(text, heading_breaks: false)
    window = text[0, WINDOW]
    floor = (WINDOW * MIN_BREAK_SHARE).to_i

    [heading_start(window, heading_breaks: heading_breaks), line_start(window),
     sentence_end(window), word_end(window)].each do |candidate|
      return candidate if candidate && candidate >= floor && candidate <= WINDOW
    end

    WINDOW
  end

  # The start of the last heading line in the window, so the next chunk opens
  # with a heading instead of in the middle of a section.
  def heading_start(window, heading_breaks:)
    return nil unless heading_breaks

    offset = 0
    last = nil
    window.each_line do |line|
      last = offset if HEADING_LINE.match?(line)
      offset += line.length
    end
    last&.positive? ? last : nil
  end

  def line_start(window)
    index = window.rindex("\n")
    index ? index + 1 : nil
  end

  def sentence_end(window)
    found = nil
    window.scan(/[.!?]["')\]]?\s/) { found = Regexp.last_match.end(0) }
    found
  end

  def word_end(window)
    index = window.rindex(/\s/)
    index ? index + 1 : nil
  end
end
