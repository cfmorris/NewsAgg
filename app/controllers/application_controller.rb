class ApplicationController < ActionController::Base
  layout "application"

  # Every screen needs a session; the landing page and the Devise screens opt
  # out of this gate themselves.
  before_action :require_session!

  helper_method :current_actor

  # A guest is sent to sign-in and brought back to where they were going. The
  # data endpoints (/articles, /auto-pull, /dashboard/stream) default to the
  # JSON format, so a fetch() caller gets 401 instead of a redirect it would
  # silently follow into the sign-in page.
  def require_session!
    return true if user_signed_in?
    # Devise's own screens manage authentication themselves: signing in and
    # registering are exactly what a guest is allowed to do.
    return true if devise_controller?

    if request.format.json?
      render json: { error: "unauthorized" }, status: :unauthorized
    else
      store_location_for(:user, request.fullpath) if request.get?
      redirect_to new_user_session_path
    end
  end

  # Devise asks these after authenticating. The landing page is never the
  # destination: signing in goes to the dashboard, or back to a stashed path.
  def after_sign_in_path_for(_resource)
    stored_location_for(:user) || dashboard_path
  end

  def after_sign_up_path_for(_resource)
    dashboard_path
  end

  protected

  # The acting principal: the signed-in User, or a null object for an anonymous
  # visitor, so callers never branch on nil.
  def current_actor
    current_user || GuestUser.new
  end

  def require_admin!
    return true if current_actor.admin? || current_actor.super_admin?

    deny_access!
  end

  def require_super_admin!
    return true if current_actor.super_admin?

    deny_access!
  end

  # Guests are sent to sign-in (HTML) or given 401 (JSON); a signed-in account
  # without the capability gets 403 in both formats.
  def deny_access!
    if current_actor.guest?
      respond_to do |format|
        format.html { redirect_to new_user_session_path, alert: "Sign in to continue." }
        format.json { render json: { error: "Sign in to continue." }, status: :unauthorized }
        format.any { head :unauthorized }
      end
    else
      message = "Your account is not permitted to do that."
      respond_to do |format|
        format.html { render plain: message, status: :forbidden }
        format.json { render json: { error: message }, status: :forbidden }
        format.any { head :forbidden }
      end
    end
  end
end
