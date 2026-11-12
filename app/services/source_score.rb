require_relative "quality_score"

# Scores a source by a decayed rolling average of the quality scores of the
# articles it contributed, and decides when that score is bad enough to stop
# paying for the source.
#
# The average is decayed by article age, not by wall-clock time: in a list of a
# source's articles ordered newest first, the newest carries weight 1.0, the
# next 0.95, the next 0.95^2, and so on. A source's score therefore follows its
# recent output - five good pieces after twenty mediocre ones lift it - instead
# of being held down by its whole history. This class is pure: it takes the
# scores and returns the numbers, so the arithmetic and the threshold can be
# checked without a database.
#
#   SourceScore.decayed_average([90, 80, 70])   # => 80.65
#   SourceScore.result(scores: [20, 20, 20, 20, 20])
#   # => #<struct score=20.0, article_count=5, pause=true, reason="auto-paused: ...">
module SourceScore
  # Each article of age discounts the one before it by this factor.
  DECAY = 0.95

  # A source is only paused once it has this many scored articles, so a new
  # source cannot be judged on one unlucky piece.
  MIN_ARTICLES = 5

  # Below this decayed average - with MIN_ARTICLES behind it - the source is
  # paused: it costs money on every run, and a score under 40 says the money is
  # not buying anything worth reading.
  THRESHOLD = 40

  # The score, the population it was computed over, and the pause verdict.
  Result = Struct.new(:score, :article_count, :pause, :reason, keyword_init: true) do
    def pause?
      pause == true
    end

    # True when there is at least one scored article: a source with no articles
    # has no score at all rather than a score of zero.
    def scored?
      article_count.positive?
    end
  end

  # The decayed rolling average of `scores`, newest article first. Returns nil
  # for an empty (or entirely non-numeric) list, so "no articles" stays distinct
  # from "every article scored one".
  def self.decayed_average(scores, decay: DECAY)
    values = scored_values(scores)
    return nil if values.empty?

    weighted = 0.0
    weights = 0.0
    values.each_with_index do |value, age|
      weight = decay**age
      weighted += weight * value
      weights += weight
    end

    (weighted / weights).round(2)
  end

  # The whole verdict for one source: the decayed average, how many scored
  # articles it covers, whether the source should be paused, and the reason to
  # record when it is.
  def self.result(scores:, override: false)
    values = scored_values(scores)
    score = decayed_average(values)
    count = values.length
    pause = pause?(score: score, article_count: count, override: override)

    Result.new(
      score: score,
      article_count: count,
      pause: pause,
      reason: pause ? pause_reason(score: score, article_count: count) : nil
    )
  end

  # The pause rule, in one place: enough articles, a score under the threshold,
  # and no registry `override: true` keeping the source on regardless.
  def self.pause?(score:, article_count:, override: false)
    return false if override
    return false unless article_count.to_i >= MIN_ARTICLES
    return false if score.nil?

    score < THRESHOLD
  end

  # The reason stored with a paused source. It names the score, the number of
  # articles behind it and the threshold, so an operator reading the admin
  # console can see why the source stopped.
  def self.pause_reason(score:, article_count:)
    "auto-paused: quality score #{format("%.1f", score)} over #{article_count} " \
      "articles is below #{THRESHOLD}"
  end

  # Numeric scores only: a missing score is not a zero, so it neither drags a
  # source's average down nor pads its article count.
  def self.scored_values(scores)
    Array(scores).filter_map { |raw| QualityScore.parse(raw) }
  end
  private_class_method :scored_values
end
