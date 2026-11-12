module AccountMenuHelper
  # The account menu's name for each role; super_admin reads as two words.
  ROLE_LABELS = { "member" => "member", "admin" => "admin", "super_admin" => "super admin" }.freeze

  def role_label(role)
    ROLE_LABELS.fetch(role.to_s, "member")
  end

  # The Profile screen and the admin console root are separate cards, so their
  # routes may not exist yet. The menu renders each link only once its route
  # helper does, and picks it up automatically when that card lands.
  def route_helper_defined?(name)
    Rails.application.routes.url_helpers.respond_to?(name)
  end
end
