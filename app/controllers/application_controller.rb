class ApplicationController < ActionController::Base
  layout "application"

  helper_method :current_actor

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
