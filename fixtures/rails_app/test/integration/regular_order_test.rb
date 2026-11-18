require_relative "../../config/environment"
require "rails/test_help"
require "rack/test"

class RegularOrderTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def test_regular_response
    get "/regular"
    assert last_response.ok?
    assert_equal "100", last_response.body
  end

  private

  def app
    Rails.application
  end
end
