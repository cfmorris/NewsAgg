require_relative "../services/url_key"

# One reader's dismissal of one article. The archive payload carries no id, so
# the article is identified by its URL: the same key the archive orders by and
# the one every dashboard row carries.
class HiddenArticle < ApplicationRecord
  belongs_to :user

  validates :article_url, presence: true

  # Normalizing keeps one story from being hidden twice under two spellings of
  # one address; an unusable address yields nil so the caller can answer 422
  # instead of writing a row nothing will ever match.
  def self.key_for(url)
    value = url.to_s.strip
    return nil if value.empty?

    UrlKey.call(value) || value
  end

  # The URLs this account has hidden. Callers read it once per request and
  # filter the archive rows in memory, because the archive is not SQL.
  def self.urls_for(user)
    where(user_id: user.id).pluck(:article_url)
  end

  def self.hidden?(user, url)
    key = key_for(url)
    key.present? && exists?(user_id: user.id, article_url: key)
  end

  # Idempotent: hiding a second time is the same row, not an error. The unique
  # index is the real guard, so a concurrent insert is folded back into a find.
  def self.hide!(user, url)
    key = key_for(url)
    raise ArgumentError, "an article url is required" if key.nil?

    find_or_create_by!(user_id: user.id, article_url: key) do |row|
      row.hidden_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(user_id: user.id, article_url: key)
  end

  # Unhiding something that was never hidden is a successful no-op, not a 404.
  def self.unhide!(user, url)
    key = key_for(url)
    return 0 if key.nil?

    where(user_id: user.id, article_url: key).delete_all
  end
end
