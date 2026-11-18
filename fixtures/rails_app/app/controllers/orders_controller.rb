class OrdersController < ActionController::Base
  def gift
    render plain: OrderFee.fee(true)
  end

  def regular
    render plain: OrderFee.fee(false)
  end

  def receipt
    # Rails renders orders/receipt.html.erb implicitly.
  end
end
