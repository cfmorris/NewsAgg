# The shape of a retry entry, shared by the batch that fails a story and the
# runner that fails to import one. Both write the same file through
# RetryStore, so the projection and the redaction live here rather than in
# each class.
module IngestFailures
  # The story a retry entry replays: the fields the next batch needs to admit
  # it through the gate again, and the discussion URL when it has one.
  def self.story(record)
    story = {
      "url" => record["url"], "title" => record["title"],
      "source" => record["source"], "external_id" => record["external_id"]
    }
    story["discovery_url"] = record["discovery_url"] if record["discovery_url"]
    story
  end

  # Provider credentials end up in fetch and import errors. Anything shorter
  # than four characters is too short to redact without mangling the text.
  def self.redact(value, secrets)
    text = String(value)
    secrets.each do |secret|
      text = text.split(secret).join("[redacted]") if secret.is_a?(String) && secret.length >= 4
    end
    text
  end
end
