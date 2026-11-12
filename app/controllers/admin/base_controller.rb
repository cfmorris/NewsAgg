module Admin
  # Every /admin screen sits behind require_admin!; individual actions tighten it
  # to super_admin where the matrix says so.
  class BaseController < ApplicationController
    before_action :require_admin!

    rescue_from UserAdministration::Denied, with: :mutation_denied

    private

    # A refused mutation still has to be visible: flash + redirect for HTML, the
    # message and a non-2xx status for JSON.
    def mutation_denied(error)
      respond_to do |format|
        format.html { redirect_to admin_users_path, alert: error.message }
        format.json { render json: { error: error.message }, status: error.status }
        format.any { head error.status }
      end
    end
  end
end
