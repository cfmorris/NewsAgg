require_relative "../../config/environment"
require_relative "../support/assertions"

include TestReport
extractor = ArticleExtractor.new

# ArticleExtractor receives raw response bodies from Net::HTTP, which tags them
# ASCII-8BIT. Any byte above 0x7F used to blow up the UTF-8 regexps in clean_text
# with Encoding::CompatibilityError, so every accented article failed to import.
TestReport.run do
  check "binary body with a non-ASCII byte is cleaned as UTF-8" do
    binary = "caf\u00E9 <b>x</b>".b
    assert binary.encoding == Encoding::ASCII_8BIT, "fixture should be ASCII-8BIT"

    text = extractor.clean_text(binary)

    assert text.encoding == Encoding::UTF_8, "expected UTF-8, got #{text.encoding}"
    assert text.valid_encoding?, "scrubbed text should be valid UTF-8"
    assert text == "café x", "expected 'café x', got #{text.inspect}"
  end

  check "valid UTF-8 input keeps today's output" do
    html = "<p>Tom &amp; Jerry \u2014 don&#39;t</p>"

    assert extractor.clean_text(html) == "Tom & Jerry — don't",
      "clean_text changed output: #{extractor.clean_text(html).inspect}"
    assert extractor.clean_text(html.b) == "Tom & Jerry — don't",
      "binary copy should clean the same: #{extractor.clean_text(html.b).inspect}"
    assert extractor.sanitize_title(" A title   here ") == "A title here", "title sanitize changed"
    assert extractor.sanitize_publisher("@Example") == "Example", "publisher sanitize changed"
    assert extractor.sanitize_publisher("", "fallback.example") == "fallback.example", "fallback lost"
  end

  check "invalid UTF-8 bytes are replaced and surrounding text survives" do
    binary = "caf\xFF au lait <b>x</b>".b

    text = extractor.clean_text(binary)

    assert text.valid_encoding?, "expected valid UTF-8, got #{text.inspect}"
    assert text.start_with?("caf"), "prefix lost: #{text.inspect}"
    assert text.include?("au lait"), "surrounding words lost: #{text.inspect}"
    assert text.end_with?("x"), "trailing text lost: #{text.inspect}"
    assert text != "caf au lait x", "invalid byte was dropped silently instead of replaced"
  end

  check "sanitizers never raise for binary input" do
    binary = "\u00C9diteur <script>x</script>".b

    assert extractor.sanitize_publisher(binary) == "Éditeur x",
      "publisher: #{extractor.sanitize_publisher(binary).inspect}"
    assert extractor.sanitize_title(binary) == "Éditeur x",
      "title: #{extractor.sanitize_title(binary).inspect}"
  end

  check "extract() end to end on accented HTML from a binary body" do
    html = +"<html><head><meta property=\"og:title\" content=\"Caf\u00E9 culture \u2014 en hausse\">" \
            "<meta property=\"og:site_name\" content=\"Le Journal\"></head>" \
            "<body><article><p>" + ("Le caf\u00E9 fran\u00E7ais se porte mieux que jamais. " * 4) +
            "</p></article></body></html>"

    result = extractor.extract(html.b, "https://example.com/story")

    assert result[:title] == "Café culture — en hausse", "title: #{result[:title].inspect}"
    assert result[:publisher] == "Le Journal", "publisher: #{result[:publisher].inspect}"
    assert result[:text].encoding == Encoding::UTF_8, "text encoding: #{result[:text].encoding}"
    assert result[:text].valid_encoding?, "text not valid UTF-8"
    assert result[:text].include?("Le café français"), "body text lost: #{result[:text][0, 80].inspect}"
  end

  check "extract() survives invalid bytes in the body" do
    html = "<html><body><article><p>" + ("R\xFFsumé " * 20) + "</p></article></body></html>"

    result = extractor.extract(html.b, "https://example.com/story")

    assert result[:text].valid_encoding?, "invalid bytes leaked into text"
    assert result[:text].include?("sum"), "surrounding text lost: #{result[:text][0, 60].inspect}"
  end
end
