# Test double for the Neo4j-backed archive used by dashboard integration tests.
class FakeArchive
  def initialize(rows)
    @rows = rows
  end

  def articles
    @rows
  end

  def prepare; end

  def seed_taxonomy; end

  def map_fast_subjects(_mappings); end

  def import(_records); end
end

class UnavailableArchive
  def articles
    raise Archive::Unavailable, "Neo4j is not reachable"
  end
end
