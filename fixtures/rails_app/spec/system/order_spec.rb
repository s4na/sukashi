require_relative "../rails_helper"
RSpec.describe "ordering", type: :system do
  it "shows the gift fee" do
    driven_by :rack_test
    visit "/gift"
    expect(page).to have_text("500")
  end
end
