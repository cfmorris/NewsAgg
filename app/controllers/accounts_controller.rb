# The signed-in account's own profile. Reading is one screen; writing happens
# through two narrow forms, both of which go through Devise's
# update_with_password so the current password is required either way.
class AccountsController < ApplicationController
  # The only attributes either form may write. role and disabled_at are absent
  # on purpose: no posted parameter can reach them, so an account cannot grant
  # itself a privilege or lift its own ban by adding a field to the form.
  EMAIL_FIELDS = %w[email current_password].freeze
  PASSWORD_FIELDS = %w[password password_confirmation current_password].freeze

  def show
    @account = fresh_account
    @email_value = @account.email
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

  # Re-render the page with Devise's messages on the form that failed, keeping
  # the address the reader typed in the email field.
  def reject(form)
    @errors = @account.errors
    @email_value = params.dig(:user, :email).presence || @account.email
    @account = fresh_account
    @failed_form = form
    render :show, status: :unprocessable_entity
  end
end
