require_relative "../services/archive"
require_relative "../services/infographic_digest"

class InfographicController < ApplicationController
  layout "application"

  def show
    @digest = InfographicDigest.new(archive.articles)
  rescue Archive::Unavailable
    @digest = InfographicDigest.new([])
    @archive_error = "Could not load Neo4j. The broadsheet is printing its empty edition."
  end

  private

  def archive
    factory = Rails.application.config.x.archive_factory
    factory&.call || Archive.new
  end
end
