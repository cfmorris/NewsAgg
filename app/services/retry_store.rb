require "json"
require "fileutils"

# Reads and writes the ingestion retry file atomically.
class RetryStore
  class Invalid < StandardError; end

  def initialize(path)
    @path = path
  end

  def read
    raw = File.read(@path, encoding: "UTF-8")
    return [] if raw.strip.empty?

    entries = JSON.parse(raw)
    raise Invalid, "The retry file must contain an array." unless entries.is_a?(Array)

    entries
  rescue Errno::ENOENT
    []
  rescue JSON::ParserError
    raise Invalid, "The retry file is not valid JSON."
  rescue SystemCallError
    raise Invalid, "Could not read the retry file."
  end

  def write(entries)
    FileUtils.mkdir_p(File.dirname(@path))
    temporary = "#{@path}.tmp"
    File.write(temporary, "#{JSON.pretty_generate(entries)}\n", mode: "w", encoding: "UTF-8")
    File.rename(temporary, @path)
  end
end
