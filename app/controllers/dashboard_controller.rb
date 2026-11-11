require "open3"

class DashboardController < ActionController::Base
  skip_forgery_protection only: :pull
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

  def pull
    return head :forbidden unless request.origin == request.base_url
    return head :unsupported_media_type unless request.media_type == "application/json"

    stdout, stderr, status = Open3.capture3(
      node_executable, Rails.root.join("bin/fetch-hn.mjs").to_s, "--archive", "-",
      stdin_data: Archive.new.articles.to_json, binmode: true
    )
    unless status.success?
      Rails.logger.warn("Hacker News pull failed: #{stderr.strip}")
      return render json: { error: "Hacker News fetch failed. Try again." }, status: :bad_gateway
    end

    render json: { pulled_at: Time.now.utc.iso8601, candidates: JSON.parse(stdout) }
  rescue Archive::Unavailable
    render json: { error: "Connect the archive before pulling articles." }, status: :service_unavailable
  rescue Errno::ENOENT
    render json: { error: "Set NEWSAGG_NODE to the Node.js executable or add Node.js to PATH." }, status: :service_unavailable
  end

  private

  def node_executable
    ENV["NEWSAGG_NODE"].presence || Rails.root.join("tmp/node-path").read.strip.presence || "node"
  rescue Errno::ENOENT
    "node"
  end
end
