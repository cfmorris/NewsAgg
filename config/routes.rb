Rails.application.routes.draw do
  root "dashboard#show"
  get "/articles", to: "dashboard#articles"
  get "/articles/stream", to: "dashboard#stream"
  post "/articles/pull", to: "dashboard#pull"
  get "/turbo.js", to: "dashboard#turbo"
end
