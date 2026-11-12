require "digest"
require "fileutils"
require "json"

require_relative "../services/archive"
require_relative "../services/auto_pull"
require_relative "../services/auto_pull_supervisor"
require_relative "../services/dashboard_filter"
require_relative "../services/pagination"

class DashboardController < ApplicationController
  layout "application"

  # The three asset actions serve files the landing and sign-in pages need
  # before a session exists.
  skip_before_action :require_session!, only: [:turbo, :dashboard_js, :dashboard_css]

  # The asset actions return static files for a plain GET, so they neither carry
  # a CSRF token nor need the embedded-JavaScript origin check that rejects a
  # .js response.
  skip_forgery_protection only: [:update_auto_pull, :turbo, :dashboard_js, :dashboard_css]

  def show
    prepare_dashboard
    render :show
  end

  def auto_pull
    render json: { enabled: AutoPull.enabled?, worker: AutoPull.worker_state }
  end

  def update_auto_pull
    return head :forbidden unless request.origin == request.base_url
    return head :unsupported_media_type unless request.media_type == "application/json"

    enabled = params[:enabled]
    return head :bad_request unless [true, false, "true", "false"].include?(enabled)

    enabled = enabled == true || enabled == "true"

    if enabled
      FileUtils.mkdir_p(File.dirname(AutoPull.flag_path))
      FileUtils.touch(AutoPull.flag_path)
      AutoPull.supervisor&.trigger
    else
      FileUtils.rm_f(AutoPull.flag_path)
    end
    auto_pull
  end

  def articles
    rows = archive.articles
    per_page = Pagination.per_page(params[:per_page])
    page_count = Pagination.page_count(rows.length, per_page)
    page = Pagination.page(params[:page], page_count)

    response.headers["X-Total-Count"] = rows.length.to_s
    response.headers["X-Page-Count"] = page_count.to_s
    response.headers["X-Page"] = page.to_s

    render json: Pagination.slice(rows, page, per_page)
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
    send_file Rails.root.join("public/turbo.js"),
      type: "application/javascript; charset=utf-8", disposition: "inline"
  end

  def dashboard_js
    send_file Rails.root.join("public/dashboard.js"),
      type: "application/javascript; charset=utf-8", disposition: "inline"
  end

  def dashboard_css
    send_file Rails.root.join("public/dashboard.css"),
      type: "text/css; charset=utf-8", disposition: "inline"
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
end
