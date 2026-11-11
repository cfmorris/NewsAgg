Rails.application.routes.draw do
  root "dashboard#show"
  get "/articles", to: "dashboard#articles"
  get "/articles/stream", to: "dashboard#stream"
  get "/auto-pull", to: "dashboard#auto_pull"
  put "/auto-pull", to: "dashboard#update_auto_pull"
  get "/turbo.js", to: "dashboard#turbo"
end
