require_relative "../rails_helper"
RSpec.describe "orders", type: :request do
  it("regular") { get "/regular"; expect(response.body).to eq("100") }
  it("gift") { get "/gift"; expect(response.body).to eq("500") }
end
