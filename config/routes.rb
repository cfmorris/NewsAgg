Rails.application.routes.draw do
  devise_for :users

  namespace :admin do
    # The console's front door. It is the namespace root, so /admin/users and
    # its members keep their own paths untouched.
    root to: "console#show"

    resources :users, only: [:index] do
      member do
        patch :role
        patch :state
      end
    end
  end

  # The public front door: no session, no store.
  root "landing#show"

  # Static assets served by controllers; the landing and sign-in pages need them
  # before a session exists. They are declared before /dashboard because
  # "/dashboard" also matches "/dashboard.css" and "/dashboard.js" as a format
  # suffix, and would otherwise swallow them into the HTML dashboard action.
  get "/turbo.js", to: "dashboard#turbo"
  get "/dashboard.js", to: "dashboard#dashboard_js"
  get "/dashboard.css", to: "dashboard#dashboard_css"

  # The dashboard is a signed-in screen now.
  get "/dashboard", to: "dashboard#show"

  # Your own account: one screen, two narrow writes, both gated by the session
  # the rest of the app already requires.
  get "/account", to: "accounts#show", as: :account
  patch "/account/email", to: "accounts#update_email", as: :account_email
  patch "/account/password", to: "accounts#update_password", as: :account_password

  # The data endpoints default to JSON so an expired session answers 401 to a
  # fetch() caller instead of redirecting it into the sign-in page.
  get "/articles", to: "dashboard#articles", defaults: { format: :json }

  # Per-account dismissal of an article, keyed by its url. Both verbs land on
  # the same path: the resource is the reader's hidden set, not an article row.
  post "/articles/hide", to: "hidden_articles#create", as: :hide_article
  delete "/articles/hide", to: "hidden_articles#destroy", as: :unhide_article

  get "/dashboard/stream", to: "dashboard#stream", defaults: { format: :json }
  get "/infographic", to: "infographic#show"
  get "/auto-pull", to: "dashboard#auto_pull", defaults: { format: :json }
  put "/auto-pull", to: "dashboard#update_auto_pull", defaults: { format: :json }
end
