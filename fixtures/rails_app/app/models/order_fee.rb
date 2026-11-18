class OrderFee
  def self.fee(gift)
    if gift
      500
    else
      100
    end
  end
end
