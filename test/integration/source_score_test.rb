require "securerandom"
require "stringio"
require "tmpdir"

require_relative "../../app/services/ingestion_runner"
require_relative "../../app/services/source_gate"
require_relative "../../app/services/source_registry"
require_relative "../../app/services/source_score"
require_relative "../support/assertions"

# Proves the source score itself: the decayed rolling average, the article-count
# floor, the pause threshold, the registry override that keeps a source on, and
# the two places the pause has to be respected - the pre-fetch gate and the
# adapter map the ingestion runner builds.
#
# No database is involved: the score is a pure function, and the gate/runner are
# exercised with a paused-id list, which is all they take from the archive.
include TestReport

def write_config(directory, body)
  path = File.join(directory, "sources-#{SecureRandom.hex(4)}.yml")
  File.write(path, "sources:\n#{body}")
  path
end

# A stand-in for the archive that only knows which sources are paused.
class PausedArchive
  def initialize(paused: [])
    @paused = paused
  end

  def articles
    []
  end

  def paused_source_ids
    @paused
  end
end

# The expected decayed average, written out independently of SourceScore's own
# loop: weight each article by 0.95 per article of age, then average.
def expected_average(scores)
  weights = scores.each_index.map { |age| 0.95**age }
  (scores.each_with_index.sum { |score, index| score * weights[index] } / weights.sum).round(2)
end

def entry(id:, name:, url:, override: nil)
  body = +<<~YAML
    - id: #{id}
      name: #{name}
      kind: api
      url: #{url}
  YAML
  body << "  override: #{override}\n" unless override.nil?
  body
end

HN_URL = "https://hacker-news.firebaseio.com/v0"

TestReport.run do
  check "each article of age discounts it by 0.95, newest first" do
    # (90*1.0 + 80*0.95) / (1.0 + 0.95) = 166 / 1.95
    assert SourceScore.decayed_average([90, 80]) == 85.13,
           "two articles averaged #{SourceScore.decayed_average([90, 80]).inspect}, expected 85.13"
    # (100 + 50*0.95 + 50*0.9025) / (1 + 0.95 + 0.9025)
    assert SourceScore.decayed_average([100, 50, 50]) == 67.53,
           "three articles averaged #{SourceScore.decayed_average([100, 50, 50]).inspect}, expected 67.53"
    assert SourceScore.decayed_average([90, 80]) == expected_average([90, 80]),
           "the decayed average disagreed with the independent formula"
  end

  check "the score follows recent output rather than the whole history" do
    # Twenty bad articles are mostly ignored once five good ones follow them.
    recent_good = SourceScore.decayed_average([90] * 5 + [10] * 20)
    recent_bad = SourceScore.decayed_average([10] * 20 + [90] * 5)
    plain_mean = ([90] * 5 + [10] * 20).sum / 25.0

    assert recent_good == expected_average([90] * 5 + [10] * 20),
           "the decayed average was #{recent_good.inspect}"
    assert recent_good > plain_mean,
           "a recent run of good articles (#{recent_good}) did not lift the average above " \
           "the plain mean (#{plain_mean})"
    assert recent_good > recent_bad,
           "the newest article did not carry the most weight (#{recent_good} vs #{recent_bad})"
  end

  check "a source with no scored articles has no score, not a zero" do
    empty = SourceScore.result(scores: [])
    assert empty.score.nil?, "an empty source scored #{empty.score.inspect}"
    assert empty.article_count.zero?, "an empty source counted #{empty.article_count.inspect}"
    assert !empty.scored?, "an empty source reported itself as scored"
    assert !empty.pause?, "an empty source was paused"

    # Unscored rows (a legacy article, a non-numeric value) are neither a zero
    # nor a member of the population the average is taken over.
    mixed = SourceScore.result(scores: [nil, "not a number", 70])
    assert mixed.score == 70.0, "unscored rows changed the average to #{mixed.score.inspect}"
    assert mixed.article_count == 1, "unscored rows counted as articles (#{mixed.article_count})"
  end

  check "the threshold pauses on the fifth low article and not on the fourth" do
    four = SourceScore.result(scores: [30, 30, 30, 30])
    assert four.article_count == 4, "four articles counted #{four.article_count.inspect}"
    assert !four.pause?, "a source was paused on four articles"

    five = SourceScore.result(scores: [30, 30, 30, 30, 30])
    assert five.score == 30.0, "the five-article score was #{five.score.inspect}"
    assert five.pause?, "a source with five articles at 30 was not paused"
    assert five.reason == "auto-paused: quality score 30.0 over 5 articles is below 40",
           "the pause reason was #{five.reason.inspect}"
  end

  check "the threshold is a floor: 40 exactly is not below it" do
    assert !SourceScore.result(scores: [40] * 5).pause?, "a source scoring exactly 40 was paused"
    assert SourceScore.result(scores: [39] * 5).pause?, "a source scoring 39 was not paused"
  end

  check "a registry override keeps a low-scoring source on" do
    overridden = SourceScore.result(scores: [10] * 5, override: true)
    assert overridden.score == 10.0, "the overridden source scored #{overridden.score.inspect}"
    assert !overridden.pause?, "an override did not prevent the pause"
    assert overridden.reason.nil?, "an overridden source recorded a pause reason"
  end

  Dir.mktmpdir("newsagg-score-") do |directory|
    check "the registry accepts override as a boolean and defaults it to false" do
      registry = SourceRegistry.load(path: write_config(directory, entry(
        id: "pinned", name: "Pinned Feed", url: HN_URL, override: true
      ) + entry(id: "plain", name: "Plain Feed", url: HN_URL)))
      assert registry.fetch("pinned").override?, "override: true did not survive loading"
      assert !registry.fetch("plain").override?, "a source without the key was an override"
      assert registry.to_h["sources"].first["override"] == true, "to_h lost the override flag"
    end

    check "a non-boolean override refuses to load" do
      begin
        SourceRegistry.load(path: write_config(directory, entry(
          id: "bad", name: "Bad Feed", url: HN_URL, override: "\"yes\""
        )))
      rescue SourceRegistry::ConfigError => error
        assert error.message.include?("override must be true or false"),
               "the config error did not name the key: #{error.message}"
      else
        raise "a string override loaded"
      end
    end

    check "the gate drops a paused source and admits it once the pause is cleared" do
      registry = SourceRegistry.load(path: write_config(directory, entry(
        id: "paused-feed", name: "Paused Feed", url: HN_URL
      )))
      paused = SourceGate.new(registry: registry, paused: ["paused-feed"])
      decision = paused.admit_source("Paused Feed")
      assert decision.dropped?, "the gate admitted a paused source"
      assert decision.reason == SourceGate::PAUSED_SOURCE,
             "the refusal reason was #{decision.reason.inspect}"

      resumed = SourceGate.new(registry: registry, paused: [])
      assert resumed.admit_source("Paused Feed").admitted?, "the source was not admitted after resuming"
    end

    check "a paused source never reaches an adapter and so is not fetched" do
      registry = SourceRegistry.load(path: write_config(directory, entry(
        id: "paused-feed", name: "Paused Feed", url: HN_URL
      )))
      err = StringIO.new
      runner = IngestionRunner.new(archive: PausedArchive.new(paused: ["paused-feed"]),
        registry: registry, err: err)
      adapters = runner.adapters_for(registry, paused: ["paused-feed"])
      assert adapters.empty?, "a paused source still got an adapter: #{adapters.keys.inspect}"
      assert err.string.include?("is paused"), "the run did not report the pause: #{err.string.inspect}"

      resumed = runner.adapters_for(registry, paused: [])
      assert resumed.key?("Paused Feed"), "resuming did not rebuild the adapter: #{resumed.keys.inspect}"
    end
  end
end
