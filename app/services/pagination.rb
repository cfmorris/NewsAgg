# Shared paging arithmetic for the dashboard and the /articles endpoint.
#
# Splitting rows into pages never sorts or filters them; callers hand in the set
# they already narrowed and this module only slices it and clamps the page.
module Pagination
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  # Pages needed for the given row count, never fewer than one so an empty
  # result still reports "Page 1 of 1".
  def self.page_count(total, per_page)
    [(total.to_i.to_f / per_page).ceil, 1].max
  end

  # The requested page, clamped into 1..page_count so a page below the first or
  # beyond the last renders the nearest valid page instead of nothing.
  def self.page(requested, page_count)
    [[positive(requested) || 1, 1].max, page_count].min
  end

  # The requested page size, falling back to the default and clamped to
  # MAX_PER_PAGE.
  def self.per_page(requested)
    [positive(requested) || DEFAULT_PER_PAGE, MAX_PER_PAGE].min
  end

  def self.slice(rows, page, per_page)
    rows.slice((page - 1) * per_page, per_page) || []
  end

  def self.positive(value)
    text = value.to_s.strip
    return nil unless text.match?(/\A-?\d+\z/)

    number = text.to_i
    number.positive? ? number : nil
  end

  private_class_method :positive
end
