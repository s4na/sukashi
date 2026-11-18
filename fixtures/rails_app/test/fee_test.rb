require "minitest/autorun"
require_relative "../app/models/order_fee"
class GiftTest < Minitest::Test
  def test_fee
    assert_equal 500, OrderFee.fee(true)
  end
end
class RegularTest < Minitest::Test
  def test_fee
    assert_equal 100, OrderFee.fee(false)
  end
end
