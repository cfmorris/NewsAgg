require "digest"
require "fileutils"
require "json"

require_relative "../services/archive"
require_relative "../services/dashboard_filter"

class DashboardController < ActionController::Base
  layout "application"

  skip_forgery_protection only: :update_auto_pull

  def show
    prepare_dashboard
    render :show
  end

  def auto_pull
    render json: { enabled: auto_pull_flag.file? }
  end

  def update_auto_pull
    return head :forbidden unless request.origin == request.base_url
    return head :unsupported_media_type unless request.media_type == "application/json"

    enabled = params[:enabled]
    return head :bad_request unless [true, false, "true", "false"].include?(enabled)

    enabled = enabled == true || enabled == "true"

    if enabled
      FileUtils.mkdir_p(auto_pull_flag.dirname)
      FileUtils.touch(auto_pull_flag)
    else
      FileUtils.rm_f(auto_pull_flag)
    end
    auto_pull
  end

  def articles
    render json: archive.articles
  rescue Archive::Unavailable
    render json: { error: "The archive is unavailable. Check the Neo4j connection." },
      status: :service_unavailable
  end

  def stream
    version = archive_version(archive.articles)
    return unless stale?(etag: version, public: false)

    response.etag = version
    body = helpers.tag.turbo_stream(action: "replace", target: "archive-version") do
      helpers.tag.template do
        helpers.tag.div(version, id: "archive-version", data: { version: version }, hidden: true)
      end
    end
    render body: body, content_type: "text/vnd.turbo-stream.html"
  rescue Archive::Unavailable
    head :service_unavailable
  end

  def turbo
    send_file Rails.root.join("public/turbo.js"), type: "application/javascript", disposition: "inline"
  end

  def dashboard_js
    send_file Rails.root.join("public/dashboard.js"), type: "application/javascript", disposition: "inline"
  end

  def dashboard_css
    send_file Rails.root.join("public/dashboard.css"), type: "text/css", disposition: "inline"
  end

  private

  def prepare_dashboard
    @articles = archive.articles
  rescue Archive::Unavailable
    @articles = []
    @archive_error = "Could not load Neo4j. Check the connection and reload the dashboard."
  ensure
    @filter = DashboardFilter.new(@articles || [], params)
    @version = archive_version(@articles || [])
  end

  def archive_version(articles)
    Digest::SHA256.hexdigest(JSON.generate(articles))[0, 32]
  end

  def archive
    factory = Rails.application.config.x.archive_factory
    factory&.call || Archive.new
  end

  def auto_pull_flag
    Rails.root.join("tmp/auto-pull.enabled")
  end
end
