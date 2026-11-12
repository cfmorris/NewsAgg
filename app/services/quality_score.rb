# Normalizes an article's 1-100 quality score.
#
# The score is model output, so it is untrusted: a value off the scale, a
# string, or no value at all must never abort an import. A number outside the
# scale is clamped into it; anything that is not a number falls back to DEFAULT.
# Every normalized value carries a status and the caller stores it next to the
# score, so a substituted value stays visible in the article's metadata instead
# of looking like the model's own judgement.
#
#   QualityScore.normalize(87)   # => #<struct value=87, status="ok">
#   QualityScore.normalize(101)  # => #<struct value=100, status="clamped">
#   QualityScore.normalize(nil)  # => #<struct value=50, status="default">
module QualityScore
  MIN = 1
  MAX = 100

  # The documented fallback: the midpoint of the scale, so a missing score is
  # neither promoted nor buried when the dashboard sorts by quality.
  DEFAULT = 50

  STATUSES = %w[ok clamped default].freeze

  Normalized = Struct.new(:value, :status) do
    def ok? = status == "ok"
    def clamped? = status == "clamped"
    def default? = status == "default"
  end

  # A number from the provider - 87, 87.0 or "87" - becomes a score; anything
  # else is nil.
  def self.parse(raw)
    number = case raw
    when Integer, Float then raw.to_f
    when String
      text = raw.strip
      text.match?(/\A[+-]?\d+(?:\.\d+)?\z/) ? text.to_f : nil
    end
    return nil unless number&.finite?

    number
  end

  def self.normalize(raw)
    number = parse(raw)
    return Normalized.new(DEFAULT, "default") if number.nil?

    rounded = number.round
    value = rounded.clamp(MIN, MAX)
    Normalized.new(value, value == rounded ? "ok" : "clamped")
  end
end
