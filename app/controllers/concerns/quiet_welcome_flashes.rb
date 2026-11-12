# The account screens say nothing when a reader signs up, signs in or signs
# out. Landing on the archive is the confirmation, and a banner above the
# articles reads as chrome rather than news.
#
# Only the three welcome notices are dropped. Every other flash - hide/unhide,
# admin refusals, source resume, the MFA error and expiry messages - is set by
# its own code path and is untouched.
module QuietWelcomeFlashes
  extend ActiveSupport::Concern

  QUIET_KINDS = %i[signed_up signed_in signed_out].freeze

  private

  # Both entry points are overridden because Devise sets some messages through
  # the bang (navigation formats only) and some through the plain setter.
  def set_flash_message(key, kind, options = {})
    return if quiet_flash?(kind)

    super
  end

  def set_flash_message!(key, kind, options = {})
    return if quiet_flash?(kind)

    super
  end

  def quiet_flash?(kind)
    QUIET_KINDS.include?(kind.to_s.to_sym)
  end
end
