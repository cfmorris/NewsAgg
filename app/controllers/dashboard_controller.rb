class DashboardController < ActionController::Base
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
end
