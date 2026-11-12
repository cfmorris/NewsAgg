module Admin
  # The source list. Read-only apart from Resume: a source the score paused is
  # turned back on here, which is the whole point of recording the pause instead
  # of deleting anything.
  class SourcesController < BaseController
    def index
      @listing = listing
      respond_to do |format|
        format.html
        format.json { render json: { sources: @listing.rows, error: @listing.error } }
      end
    end

    def resume
      resumed = archive.resume_source(params[:id])

      respond_to do |format|
        format.html do
          if resumed.nil?
            redirect_to admin_sources_path, alert: "No source with id #{params[:id].inspect}."
          else
            redirect_to admin_sources_path, notice: resume_message(resumed)
          end
        end
        format.json do
          if resumed.nil?
            render json: { error: "No source with id #{params[:id].inspect}." }, status: :not_found
          else
            render json: resumed
          end
        end
      end
    end

    private

    def archive
      Archive.new
    end

    def listing
      SourceListing.new(archive: archive)
    end

    # Resuming clears the pause and restores what config/sources.yml says. A
    # source the operator also disabled in config stays off, and the message
    # says so instead of implying it is fetching again.
    def resume_message(resumed)
      if resumed["enabled"]
        "#{resumed["id"]} is fetching again."
      else
        "#{resumed["id"]} is no longer paused, but it is disabled in config/sources.yml, " \
          "so it stays off."
      end
    end
  end
end
