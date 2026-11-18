require_relative "../rails_helper"

RSpec.describe "receipt", type: :request do
  it "renders the gift fee from a partial" do
    get receipt_path
    expect(response.body).to include("Gift fee: 500")
  end
end
