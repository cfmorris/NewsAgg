require "fileutils"

class DashboardController < ActionController::Base
  skip_forgery_protection only: :update_auto_pull

  def auto_pull
    render json: { enabled: auto_pull_flag.file? }
  end

  def update_auto_pull
    return head :forbidden unless request.origin == request.base_url
    return head :unsupported_media_type unless request.media_type == "application/json"

    enabled = params[:enabled]
    return head :bad_request unless enabled == true || enabled == false

    if enabled
      FileUtils.mkdir_p(auto_pull_flag.dirname)
      FileUtils.touch(auto_pull_flag)
    else
      FileUtils.rm_f(auto_pull_flag)
    end
    auto_pull
  end
  def show
    render file: Rails.root.join("news-dashboard.html"), layout: false, content_type: "text/html"
  end

  def articles
    render json: Archive.new.articles
  rescue Archive::Unavailable
    render json: { error: "The archive is unavailable. Check the Neo4j connection." },
      status: :service_unavailable
  end

  def stream
    snapshot = Archive.new.articles.to_json
    return unless stale?(etag: snapshot, public: false)

    stream = helpers.tag.turbo_stream(action: "replace", target: "archive-snapshot") {
      helpers.tag.template { helpers.tag.div(snapshot, id: "archive-snapshot", hidden: true) }
    }
    render body: stream, content_type: "text/vnd.turbo-stream.html"
  rescue Archive::Unavailable
    head :service_unavailable
  end

  def turbo
    send_file Rails.root.join("public/turbo.js"), type: "application/javascript", disposition: "inline"
  end

  private

  def auto_pull_flag
    Rails.root.join("tmp/auto-pull.enabled")
  end

end
