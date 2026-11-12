require_relative "archive"

# The admin console's view of the source registry: one row per materialised
# NewsSource, or none plus the reason when the graph cannot be read.
#
# The console must keep working when Neo4j is down - it is also the screen that
# tells an operator something is wrong - so an unavailable archive is reported
# as state, never raised into a 500.
class SourceListing
  attr_reader :error

  def initialize(archive: Archive.new)
    @archive = archive
  end

  def rows
    load_rows unless @loaded
    @rows
  end

  def unavailable?
    rows
    !error.nil?
  end

  def find(id)
    rows.find { |row| row["id"] == id.to_s }
  end

  private

  def load_rows
    @loaded = true
    @rows = @archive.source_nodes
  rescue Archive::Unavailable => error
    @error = error.message
    @rows = []
  end
end
