require_relative "archive"
require_relative "source_score"

# Recomputes every NewsSource's decayed quality score and article count from the
# articles it contributed, then pauses the sources that fall below the floor.
#
# Two properties shape the implementation:
#
#   * Scores are recomputed, never incremented. The score is a function of the
#     articles attributed to the source, so running this twice - or replaying an
#     import - produces the same numbers instead of compounding them.
#   * The pause is a set of node fields (paused_at, pause_reason) plus
#     enabled=false, not a deletion. Resuming clears them and the articles were
#     never touched, so an auto-paused source keeps its history and its cost.
#
# Cost is deliberately absent here: NewsSource.cost_usd keeps accumulating in
# Archive#recompute_source_costs whether a source is enabled, paused or not.
class SourceScoring
  # What one pass did: how many sources were scored, and which of them were
  # paused (id + the reason recorded with it).
  Outcome = Struct.new(:scored, :paused, keyword_init: true) do
    def paused_ids
      paused.map { |row| row["id"] }
    end
  end

  def initialize(archive: Archive.new)
    @archive = archive
  end

  def call
    decisions = @archive.source_quality_inputs.map do |row|
      result = SourceScore.result(scores: row["scores"], override: override?(row))
      [row, result]
    end

    # Nothing materialised means nothing to score: skip both writes rather than
    # issuing a statement over an empty row set.
    return Outcome.new(scored: 0, paused: []) if decisions.empty?

    @archive.write_source_scores(decisions.map do |row, result|
      {
        "id" => row["id"],
        "quality_score" => result.score,
        "article_count" => result.article_count
      }
    end)

    pauses = decisions.select { |_row, result| result.pause? }.map do |row, result|
      { "id" => row["id"], "reason" => result.reason }
    end
    @archive.pause_sources(pauses) unless pauses.empty?

    Outcome.new(scored: decisions.length, paused: pauses)
  end

  private

  def override?(row)
    row["pause_override"] == true
  end
end
