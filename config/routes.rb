Rails.application.routes.draw do
  root "dashboard#show"
  get "/articles", to: "dashboard#articles"
  get "/dashboard/stream", to: "dashboard#stream"
  get "/infographic", to: "infographic#show"
  get "/auto-pull", to: "dashboard#auto_pull"
  put "/auto-pull", to: "dashboard#update_auto_pull"
  get "/turbo.js", to: "dashboard#turbo"
  get "/dashboard.js", to: "dashboard#dashboard_js"
  get "/dashboard.css", to: "dashboard#dashboard_css"
end
