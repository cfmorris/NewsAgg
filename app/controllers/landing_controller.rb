# The public front door. It renders before anyone signs in and must not depend
# on any store: no Neo4j, no queries, nothing that can fail when the archive is
# down. It only asks Devise whether a session already exists.
class LandingController < ApplicationController
  skip_before_action :require_session!

  def show
  end
end
