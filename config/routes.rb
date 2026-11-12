Rails.application.routes.draw do
  devise_for :users

  namespace :admin do
    resources :users, only: [:index] do
      member do
        patch :role
        patch :state
      end
    end
  end

  # The public front door: no session, no store.
  root "landing#show"

  # The dashboard is a signed-in screen now.
  get "/dashboard", to: "dashboard#show"

  # The data endpoints default to JSON so an expired session answers 401 to a
  # fetch() caller instead of redirecting it into the sign-in page.
  get "/articles", to: "dashboard#articles", defaults: { format: :json }
  get "/dashboard/stream", to: "dashboard#stream", defaults: { format: :json }
  get "/infographic", to: "infographic#show"
  get "/auto-pull", to: "dashboard#auto_pull", defaults: { format: :json }
  put "/auto-pull", to: "dashboard#update_auto_pull", defaults: { format: :json }

  # Static assets served by controllers; the landing and sign-in pages need them
  # before a session exists.
  get "/turbo.js", to: "dashboard#turbo"
  get "/dashboard.js", to: "dashboard#dashboard_js"
  get "/dashboard.css", to: "dashboard#dashboard_css"
end
