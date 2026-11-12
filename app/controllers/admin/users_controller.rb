module Admin
  class UsersController < BaseController
    # Changing any role is a super_admin action.
    before_action :require_super_admin!, only: :role

    def index
      @users = User.order(:id)
      respond_to do |format|
        format.html
        format.json { render json: @users.map { |user| user_payload(user) } }
      end
    end

    def role
      user = find_user!
      UserAdministration.new(current_actor).change_role(user, params[:role])
      respond_to do |format|
        format.html { redirect_to admin_users_path, notice: "#{user.email} is now #{user.role.tr("_", " ")}." }
        format.json { render json: user_payload(user) }
      end
    end

    def state
      user = find_user!
      administration = UserAdministration.new(current_actor)
      message =
        case params[:state].to_s
        when "disable" then administration.disable(user) && "#{user.email} is disabled."
        when "enable" then administration.enable(user) && "#{user.email} is active again."
        else
          raise UserAdministration::Denied.new("Unknown state #{params[:state].inspect}. Use disable or enable.",
                                               status: :unprocessable_entity)
        end

      respond_to do |format|
        format.html { redirect_to admin_users_path, notice: message }
        format.json { render json: user_payload(user) }
      end
    end

    private

    def find_user!
      User.find_by(id: params[:id]) ||
        raise(UserAdministration::Denied.new("No account with id #{params[:id].inspect}.", status: :not_found))
    end

    def user_payload(user)
      {
        id: user.id,
        email: user.email,
        role: user.role,
        active: !user.disabled?,
        disabled_at: user.disabled_at,
        created_at: user.created_at
      }
    end
  end
end
