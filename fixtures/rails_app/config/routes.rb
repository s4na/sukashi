Rails.application.routes.draw do
  get "/gift", to: "orders#gift"
  get "/regular", to: "orders#regular"
  get "/receipt", to: "orders#receipt", as: :receipt
end
