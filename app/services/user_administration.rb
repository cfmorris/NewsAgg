# Applies the role and account-state capability matrix and the invariants that
# outlive any single screen:
#
#   * only a super_admin changes roles at all;
#   * an admin may disable/enable members, but only a super_admin may touch
#     another admin or a super_admin;
#   * nobody changes their own role or disables themselves;
#   * the last super_admin cannot be demoted or disabled.
#
# Refusals raise Denied with the HTTP status the caller should report, so the
# controller never has to guess whether a mutation happened.
class UserAdministration
  class Denied < StandardError
    attr_reader :status

    def initialize(message, status: :forbidden)
      super(message)
      @status = status
    end
  end

  def initialize(actor)
    @actor = actor.is_a?(User) ? actor : GuestUser.new
  end

  def change_role(target, role)
    role = role.to_s
    unless User::ROLES.include?(role)
      raise Denied.new("Unknown role #{role.inspect}. Use member, admin or super_admin.",
                       status: :unprocessable_entity)
    end
    require_super_admin!
    raise Denied.new("You cannot change your own role.", status: :unprocessable_entity) if self?(target)

    if target.super_admin? && role != "super_admin" && last_super_admin?(target)
      raise Denied.new("The last super administrator cannot be demoted.", status: :unprocessable_entity)
    end

    if target.role == role
      raise Denied.new("#{target.email} is already #{role.tr("_", " ")}.", status: :unprocessable_entity)
    end

    target.update!(role: role)
    target
  end

  def disable(target)
    require_admin!
    raise Denied.new("You cannot disable your own account.", status: :unprocessable_entity) if self?(target)

    require_super_admin_for_admin_target!(target)
    raise Denied.new("#{target.email} is already disabled.", status: :unprocessable_entity) if target.disabled?

    if target.super_admin? && last_super_admin?(target)
      raise Denied.new("The last super administrator cannot be disabled.", status: :unprocessable_entity)
    end

    target.update!(disabled_at: Time.current)
    target
  end

  def enable(target)
    require_admin!
    require_super_admin_for_admin_target!(target)
    raise Denied.new("#{target.email} is already active.", status: :unprocessable_entity) unless target.disabled?

    target.update!(disabled_at: nil)
    target
  end

  private

  attr_reader :actor

  def self?(target)
    actor.registered? && target.id.present? && target.id == actor.id
  end

  def require_admin!
    return if actor.admin? || actor.super_admin?

    raise Denied.new("Your account is not permitted to do that.", status: :forbidden)
  end

  def require_super_admin!
    return if actor.super_admin?

    raise Denied.new("Only a super administrator can change roles.", status: :forbidden)
  end

  def require_super_admin_for_admin_target!(target)
    return unless target.admin? || target.super_admin?
    return if actor.super_admin?

    raise Denied.new("Only a super administrator can act on another administrator.", status: :forbidden)
  end

  def last_super_admin?(target)
    target.super_admin? && User.where(role: User.roles[:super_admin]).count <= 1
  end
end
