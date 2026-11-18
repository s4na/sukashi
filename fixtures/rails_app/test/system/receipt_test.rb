require_relative "../../config/environment"
require "rails/test_help"

class ReceiptTest < ActionDispatch::SystemTestCase
  driven_by :rack_test

  def test_receipt_flow
    visit "/receipt"
    assert_text "Gift fee: 500"
    click_link "Regular fee"
    assert_text "100"
  end
end
