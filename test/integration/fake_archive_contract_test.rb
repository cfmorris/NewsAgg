require_relative "../support/assertions"
require_relative "../support/fake_archive"

# Guards the fake used by the server-free suites. A test double that drifts from
# the real archive turns a passing suite into a lie, so the two behaviours callers
# rely on are pinned here: MERGE-by-url idempotency and per-source cost sums.
# The real Cypher contract stays with test/support/neo4j-test.sh.
include TestReport

def article(url:, title: "Title", source: "hn", cost: 0.25, topics: [])
  { url: url, title: title, source: source, summary_cost_usd: cost, topics: topics }
end

TestReport.run do
  check "a fresh import is visible to readers" do
    archive = FakeArchive.new
    archive.import([article(url: "https://example.test/a", title: "First")])

    urls = archive.articles.map { |row| row["url"] }
    assert urls == ["https://example.test/a"], "expected one article, got #{urls.inspect}"
    assert archive.articles.first["title"] == "First", "title was not carried through"
  end

  check "re-importing the same url does not duplicate it" do
    archive = FakeArchive.new
    record = article(url: "https://example.test/a")
    2.times { archive.import([record]) }

    assert archive.articles.length == 1,
           "expected the MERGE to keep one article, got #{archive.articles.length}"
  end

  check "a re-import does not overwrite fields set on create" do
    archive = FakeArchive.new
    archive.import([article(url: "https://example.test/a", title: "Original")])
    archive.import([article(url: "https://example.test/a", title: "Rewritten")])

    assert archive.articles.first["title"] == "Original",
           "expected the ON CREATE title to survive, got #{archive.articles.first['title'].inspect}"
  end

  check "topics merge without duplicates" do
    archive = FakeArchive.new
    archive.import([article(url: "https://example.test/a", topics: %w[ruby rails])])
    archive.import([article(url: "https://example.test/a", topics: %w[rails news])])

    topics = archive.topics_for("https://example.test/a")
    assert topics == %w[ruby rails news], "expected merged topics, got #{topics.inspect}"
  end

  check "an empty or url-less record is ignored rather than stored" do
    archive = FakeArchive.new
    archive.import([{ url: nil, title: "no url" }, article(url: "")])

    assert archive.articles.empty?, "url-less records must not become articles"
  end

  check "cost is summed per source, and the same article is counted once" do
    archive = FakeArchive.new
    archive.import([
      article(url: "https://example.test/a", source: "hn", cost: 0.25),
      article(url: "https://example.test/b", source: "hn", cost: 0.75),
      article(url: "https://example.test/c", source: "rss", cost: 1.5)
    ])
    archive.import([article(url: "https://example.test/a", source: "hn", cost: 0.25)])

    archive.recompute_source_costs
    costs = archive.source_nodes.each_with_object({}) { |row, acc| acc[row["name"]] = row["cost_usd"] }
    assert costs["hn"] == 1.0, "expected hn=1.0 (0.25+0.75, counted once), got #{costs['hn'].inspect}"
    assert costs["rss"] == 1.5, "expected rss=1.5, got #{costs['rss'].inspect}"
  end

  check "pause and resume round-trip" do
    archive = FakeArchive.new
    archive.pause_sources([{ id: "hn" }, { id: "rss" }])
    assert archive.paused_source_ids == %w[hn rss], "pause did not record both sources"

    archive.resume_source("hn")
    assert archive.paused_source_ids == ["rss"], "resume did not clear the source"
  end

  check "Cypher is not silently faked" do
    archive = FakeArchive.new
    begin
      archive.query("MATCH (n) RETURN n")
      raise "FakeArchive#query answered a Cypher statement"
    rescue FakeArchive::NotModelled => error
      assert error.message.include?("graph lane"),
             "the refusal must name the lane that can run real queries: #{error.message}"
    end
  end
end
