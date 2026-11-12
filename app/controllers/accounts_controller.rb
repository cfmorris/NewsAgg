# The signed-in account's own profile. Reading is one screen; writing happens
# through a handful of narrow forms, and every one of them requires the current
# password or a code only the account holder can produce.
class AccountsController < ApplicationController
  # The only attributes either form may write. role and disabled_at are absent
  # on purpose: no posted parameter can reach them, so an account cannot grant
  # itself a privilege or lift its own ban by adding a field to the form.
  EMAIL_FIELDS = %w[email current_password].freeze
  PASSWORD_FIELDS = %w[password password_confirmation current_password].freeze

  # The name an authenticator app shows beside the account, and the window a
  # code is accepted in. The window matches the gem's own drift default: a phone
  # whose clock is a few seconds off still enrols instead of looking broken.
  MFA_ISSUER = "NewsAgg".freeze
  MFA_DRIFT_SECONDS = 30

  def show
    @account = fresh_account
    prepare_page
  end

  # Begin enrolment. A secret is minted but held only for this session: nothing
  # is written to the account until a code generated from it comes back, so an
  # abandoned or mis-scanned setup leaves MFA exactly where it was.
  def setup_two_factor
    @account = fresh_account

    if @account.otp_required_for_login?
      redirect_to account_path, alert: "Two-factor authentication is already on."
    else
      session[:pending_otp_secret] = User.generate_otp_secret
      redirect_to account_path,
                  notice: "Add the key below to your authenticator app, then confirm with a code."
    end
  end

  # Finish enrolment. otp_required_for_login flips only for a code that matches
  # the pending secret; a wrong one leaves MFA off and re-renders the key so the
  # reader can try again.
  def confirm_two_factor
    @account = fresh_account
    pending_secret = session[:pending_otp_secret]

    if @account.otp_required_for_login?
      redirect_to account_path, alert: "Two-factor authentication is already on."
    elsif pending_secret.blank?
      redirect_to account_path, alert: "Start the two-factor setup before confirming a code."
    elsif totp_code_valid?(pending_secret, params.dig(:user, :otp_attempt))
      @account.update!(otp_secret: pending_secret, otp_required_for_login: true, consumed_timestep: nil)
      session.delete(:pending_otp_secret)
      redirect_to account_path, notice: "Two-factor authentication is on."
    else
      @account.errors.add(:base, "That code did not match. Check your authenticator app and try again.")
      reject(:two_factor_form)
    end
  end

  # Turn MFA off, which needs the password for the same reason the other forms
  # do: a borrowed session must not be able to strip the second factor. The
  # secret goes with it, so turning MFA back on starts from a fresh key.
  def disable_two_factor
    @account = fresh_account

    unless @account.otp_required_for_login?
      return redirect_to account_path, alert: "Two-factor authentication is already off."
    end

    if @account.valid_password?(params.dig(:user, :current_password).to_s)
      @account.update!(otp_required_for_login: false, otp_secret: nil, consumed_timestep: nil)
      session.delete(:pending_otp_secret)
      redirect_to account_path, notice: "Two-factor authentication is off."
    else
      @account.errors.add(:current_password, :invalid)
      reject(:two_factor_disable_form)
    end
  end

  def update_email
    @account = fresh_account

    if @account.update_with_password(submitted(EMAIL_FIELDS))
      redirect_to account_path, notice: "Your email address has been updated."
    else
      reject(:email_form)
    end
  end

  def update_password
    @account = fresh_account

    if @account.update_with_password(submitted(PASSWORD_FIELDS))
      # The stored salt changes with the password, so the cookie minted before
      # the change no longer authenticates. Re-signing in keeps Devise's
      # sign_in_after_change_password promise: the reader stays signed in.
      bypass_sign_in(@account)
      redirect_to account_path, notice: "Your password has been changed."
    else
      reject(:password_form)
    end
  end

  private

  # A copy of the signed-in row, so a refused change leaves the summary showing
  # what is actually stored rather than an attempted-but-rejected value.
  def fresh_account
    User.find(current_user.id)
  end

  def submitted(fields)
    # Symbol keys: update_with_password deletes :current_password before it
    # hands the rest to the model, and a string key would slip past that.
    fields.index_with { |field| params.dig(:user, field) }.symbolize_keys
  end

  # What the page needs beyond the record itself: the address the reader typed
  # into a refused email form and, only while an enrolment is in flight and MFA
  # is still off, the key to add to their authenticator app. The pending secret
  # never comes from the request, only from this session, so one account cannot
  # see or confirm another's enrolment.
  def prepare_page
    @email_value = params.dig(:user, :email).presence || @account.email
    @pending_otp_secret = nil
    @otp_provisioning_uri = nil
    return if @account.otp_required_for_login?

    @pending_otp_secret = session[:pending_otp_secret]
    return if @pending_otp_secret.blank?

    @otp_provisioning_uri = @account.otp_provisioning_uri(
      @account.email, otp_secret: @pending_otp_secret, issuer: MFA_ISSUER
    )
  end

  # A six-digit code checked against the pending secret only. Nothing is
  # consumed: that secret is not stored yet, so the reader's first code stays
  # usable at their next sign-in.
  def totp_code_valid?(secret, code)
    digits = code.to_s.gsub(/\s+/, "")
    return false unless digits.match?(/\A\d{6}\z/)

    ROTP::TOTP.new(secret, issuer: MFA_ISSUER)
              .verify(digits, drift_behind: MFA_DRIFT_SECONDS, drift_ahead: MFA_DRIFT_SECONDS)
              .present?
  end

  # Re-render the page with Devise's messages on the form that failed, keeping
  # the address the reader typed in the email field.
  def reject(form)
    @errors = @account.errors
    @account = fresh_account
    @failed_form = form
    prepare_page
    render :show, status: :unprocessable_entity
  end
end
