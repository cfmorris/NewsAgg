# Sign-in for an account with MFA on is two steps: the password, then a
# six-digit code from the reader's authenticator app. Both steps post through
# Devise's session controller; the second one only exists for this challenge.
#
# The code is checked here rather than by letting two_factor_authenticatable
# take the whole sign-in: that strategy answers a password-only POST from an
# MFA account with the generic "Invalid Email or password" (so there is no
# second step to render), and Lockable charges the account a failed attempt for
# the missing code - enough wrong guesses at a prompt would lock it out. Here a
# wrong code only re-renders the challenge, and the account's counters are
# untouched. Single-factor sign-in, bad passwords, locked and disabled accounts
# all still go through Devise exactly as before.
module Users
  class SessionsController < Devise::SessionsController
    include QuietWelcomeFlashes
    # What the password step leaves for the code step: which account is mid
    # sign-in, whether it asked to be remembered, and when it started. The
    # password itself is never kept.
    CHALLENGE_KEY = :two_factor_challenge
    CHALLENGE_TTL = 5.minutes

    before_action :redirect_if_signed_in, only: :two_factor

    # Step one. An MFA account that got the password right is sent to the code
    # step; everyone else falls through to Devise's own create.
    def create
      account = challenge_account

      if account
        stash_challenge(account)
        # The challenge is rendered by this same request and its layout asks
        # user_signed_in?. Warden answers that by running the sign-in
        # strategies again against the posted password, which now fails for the
        # missing code and charges the account a failed attempt. Turning params
        # authentication off for the rest of this request keeps the password
        # step free of that charge.
        request.env["devise.allow_params_authentication"] = false
        @error = nil
        render "devise/sessions/two_factor"
      else
        super
      end
    end

    # Step two. validate_and_consume_otp! is devise-two-factor's check: it
    # compares the code to the stored otp_secret within the allowed drift and
    # records the timestep, so the same code cannot be replayed. A wrong code
    # renders this step again with a message and nothing else changes - no
    # Warden call, no failed-attempt charge, no lockout.
    def two_factor
      challenge = pending_challenge
      account = challenge && pending_account(challenge)

      if account.nil?
        session.delete(CHALLENGE_KEY)
        redirect_to new_user_session_path(auth_path_options),
                    alert: "Your sign-in attempt expired. Please sign in again."
        return
      end

      if account.validate_and_consume_otp!(params.dig(:user, :otp_attempt))
        complete_sign_in(account, challenge)
      else
        @error = "That code is not valid. Enter the current six-digit code from your authenticator app."
        render "devise/sessions/two_factor", status: :unprocessable_entity
      end
    end

    private

    # The account this POST may hand to the code step, or nil to let Devise
    # answer. A locked or disabled account never gets here, so Devise keeps
    # reporting it with the message it already reports.
    def challenge_account
      password = params.dig(:user, :password)
      return nil if password.blank?

      account = resource_class.find_for_database_authentication(email: params.dig(:user, :email))
      return nil unless account&.otp_required_for_login?
      return nil unless account.active_for_authentication?
      return nil unless account.valid_password?(password)

      account
    end

    def stash_challenge(account)
      session[CHALLENGE_KEY] = {
        "user_id" => account.id,
        "remember_me" => params.dig(:user, :remember_me).to_s == "1",
        "started_at" => Time.current.to_i
      }
    end

    def pending_challenge
      data = session[CHALLENGE_KEY]
      return nil unless data.is_a?(Hash)

      started_at = data["started_at"].to_i
      return nil if started_at.zero? || Time.current.to_i - started_at > CHALLENGE_TTL.to_i

      data
    end

    # The row may have changed since step one, so MFA and the account's ability
    # to authenticate are checked again against the database, not the session.
    def pending_account(data)
      account = resource_class.find_by(id: data["user_id"])
      return nil unless account&.otp_required_for_login? && account.active_for_authentication?

      account
    end

    def complete_sign_in(account, challenge)
      session.delete(CHALLENGE_KEY)

      # The remember-me checkbox was on step one; the Warden hook only sets the
      # cookie when the record carries the flag into sign_in.
      account.remember_me = challenge["remember_me"] if account.respond_to?(:remember_me=)
      sign_in(resource_name, account)
      # No notice: the dashboard itself is the confirmation. QuietWelcomeFlashes
      # covers Devise's own sign-in and sign-out messages the same way.
      redirect_to after_sign_in_path_for(account)
    end

    def redirect_if_signed_in
      redirect_to after_sign_in_path_for(current_user) if user_signed_in?
    end
  end
end
