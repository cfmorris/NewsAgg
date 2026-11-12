# Two narrow writes over the account's hidden set. The session gate is the
# application's own require_session!, so a guest is turned away before either
# action runs: 401 to a JSON caller, a redirect to sign-in for a browser form.
class HiddenArticlesController < ApplicationController
  # Hiding an article the reader already hid is fine, and unhiding an article
  # that was never hidden succeeds too - the hidden set is state, not a stack.
  def create
    write(hidden: true)
  end

  def destroy
    write(hidden: false)
  end

  private

  def write(hidden:)
    url = HiddenArticle.key_for(params[:url])
    return reject_blank_url if url.nil?

    if hidden
      HiddenArticle.hide!(current_user, url)
    else
      HiddenArticle.unhide!(current_user, url)
    end

    respond_to do |format|
      # Back to the view the reader was on, so a hide from the Hidden topic
      # stays on the Hidden topic.
      format.html do
        redirect_back_or_to dashboard_path,
          notice: hidden ? "Article hidden." : "Article restored."
      end
      format.json { render json: { url: url, hidden: hidden } }
    end
  end

  def reject_blank_url
    respond_to do |format|
      format.html { redirect_back_or_to dashboard_path, alert: "Pick an article to hide." }
      format.json do
        render json: { error: "an article url is required" }, status: :unprocessable_entity
      end
    end
  end
end
