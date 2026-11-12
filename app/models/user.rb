# Accounts. two_factor_authenticatable replaces database_authenticatable (it
# includes it), so the model lists exactly one password strategy. MFA stays off
# until a user's otp_required_for_login is flipped on.
class User < ApplicationRecord
  # Ordered so the stored integer stays stable; the enum validates the value so
  # an unknown role cannot be written.
  ROLES = %w[member admin super_admin].freeze

  devise :two_factor_authenticatable,
         :registerable,
         :recoverable,
         :rememberable,
         :validatable,
         :trackable,
         :lockable

  enum :role, { member: 0, admin: 1, super_admin: 2 }, default: :member, validate: true

  validates :provider, presence: true, if: -> { uid.present? }
  validates :uid, presence: true, if: -> { provider.present? }

  # The first account on a fresh install is the one that can hand out roles;
  # everyone who registers after it starts as a member.
  before_create :become_first_super_admin

  # Guests are anonymous visitors with no row; these predicates let callers treat
  # a User and a GuestUser alike.
  def guest?
    false
  end

  def registered?
    true
  end

  def disabled?
    disabled_at.present?
  end

  # Every number the admin console shows, from one grouped query: the total per
  # role and, alongside it, how many of those accounts are disabled. Adding a
  # role to ROLES adds its count to the page without touching this method.
  def self.console_summary
    counts = ROLES.index_with(0)
    disabled = 0

    group(:role)
      .pluck(:role, Arel.sql("COUNT(*)"),
             Arel.sql("SUM(CASE WHEN disabled_at IS NOT NULL THEN 1 ELSE 0 END)"))
      .each do |role, total, off|
        counts[role.to_s] = total
        disabled += off.to_i
      end

    { counts: counts, disabled: disabled }
  end

  # Devise consults this on every sign-in; a disabled account is refused with
  # the standard "not active" message while its password stays untouched.
  def active_for_authentication?
    super && !disabled?
  end

  def inactive_message
    disabled? ? :inactive : super
  end

  # Devise 5 reports every failed authentication as :invalid unless the model
  # says otherwise, so a disabled account would be told its password is wrong.
  # Lockable uses the same hook to surface its own message.
  def unauthenticated_message
    disabled? ? inactive_message : super
  end

  private

  def become_first_super_admin
    self.role = :super_admin if self.class.count.zero?
  end
end
