Rails.application.routes.draw do
  # Sessions are Devise's, with one addition: an account that signs in with MFA
  # on posts its password to /users/sign_in and its six-digit code to the step
  # below, which is why the sign-in controller is the app's own.
  devise_for :users, controllers: { sessions: "users/sessions", registrations: "users/registrations" }

  # Step two of an MFA sign-in. It lives under /users/sign_in so the landing
  # page's overlay can frame it like the rest of the Devise screens, and it is
  # declared inside devise_scope so Devise's controller knows its mapping.
  devise_scope :user do
    post "/users/sign_in/two_factor", to: "users/sessions#two_factor", as: :user_two_factor
  end

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

    # The source list, plus the one write it offers: resuming a source the
    # quality score paused. Everything else about a source lives in
    # config/sources.yml, so it is changed there, not here.
    resources :sources, only: [:index] do
      member do
        patch :resume
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

  # Your own account: one screen, three narrow writes, all gated by the session
  # the rest of the app already requires. The two-factor path is one resource
  # with three verbs: begin enrolment, confirm the code, turn it off.
  get "/account", to: "accounts#show", as: :account
  patch "/account/email", to: "accounts#update_email", as: :account_email
  patch "/account/password", to: "accounts#update_password", as: :account_password
  post "/account/two_factor", to: "accounts#setup_two_factor", as: :account_two_factor
  patch "/account/two_factor", to: "accounts#confirm_two_factor"
  delete "/account/two_factor", to: "accounts#disable_two_factor"

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
