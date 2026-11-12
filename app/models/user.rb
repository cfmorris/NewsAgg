# Accounts. two_factor_authenticatable replaces database_authenticatable (it
# includes it), so the model lists exactly one password strategy. MFA stays off
# until a user's otp_required_for_login is flipped on.
class User < ApplicationRecord
  devise :two_factor_authenticatable,
         :registerable,
         :recoverable,
         :rememberable,
         :validatable,
         :trackable,
         :lockable

  validates :provider, presence: true, if: -> { uid.present? }
  validates :uid, presence: true, if: -> { provider.present? }
end
