require "minitest/autorun"
require_relative "../lib/sukashi/selection"

class ReachabilityTest < Minitest::Test
  def index(then_fee, else_fee = "100", predicate: "gift", body: nil)
    code = body || "def self.fee(gift); if #{predicate}; #{then_fee}; else; #{else_fee}; end; end"
    Sukashi::SourceIndex.new("lib/fee.rb" => "class Fee; #{code}; end")
  end

  def test_same_line_changes_are_assigned_to_individual_arms
    old = index("500")
    assert_equal [["Fee", true, :fee, true]], Sukashi::BranchDiff.between(old, index("700"), "lib/fee.rb")
    assert_equal [["Fee", true, :fee, false]], Sukashi::BranchDiff.between(old, index("500", "300"), "lib/fee.rb")
    assert_nil Sukashi::BranchDiff.between(old, index("500", predicate: "!gift"), "lib/fee.rb")
  end

  def test_teardown_lifecycle_keeps_tests_in_derived_classes
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    paths = Set["test/base_test.rb", "test/derived_test.rb"]
    %w[before_teardown after_teardown].each do |hook|
      sources = index("500").sources.merge(
        "test/base_test.rb" => "class BaseTest; def #{hook}; Fee.fee(true); end; end",
        "test/derived_test.rb" => "class DerivedTest < BaseTest; def test_other; Fee.fee(false); end; end"
      )
      reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, paths, Set.new)
      assert_equal :unknown, reach.inspect_test("test/derived_test.rb", 1), hook
    end
  end

  def test_controller_hook_is_scoped_to_the_controller_and_its_descendants
    sources = index("500").sources.merge(
      "base.rb" => "class BaseController; before_action :charge; end",
      "orders.rb" => "class OrdersController < BaseController; def show; Fee.fee(false); end; end",
      "config/routes.rb" => 'Rails.application.routes.draw { get "/orders", to: "orders#show" }',
      "test/example_test.rb" => "class ExampleTest; def test_unit; Fee.fee(false); end\n def test_http; get '/orders'; end; end"
    )
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    path = "test/example_test.rb"
    reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
    assert_equal :other_arm, reach.inspect_test(path, 1)
    assert_equal :unknown, reach.inspect_test(path, 2)
  end

  def test_unknown_input_and_multiple_calls
    source = index("500").sources.merge("test/fee_test.rb" => <<~RUBY)
      class FeeTest
        def test_both; Fee.fee(false); Fee.fee(true); end
        def test_unknown; Fee.fee(record.gift?); end
        def test_other; Fee.fee(false); end
      end
    RUBY
    idx = Sukashi::SourceIndex.new(source)
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    paths = Set["test/fee_test.rb"]
    reach = Sukashi::Reachability.new(idx, target, paths, Set.new)
    assert_equal [:affected, :unknown, :other_arm], (2..4).map { |line| reach.inspect_test(paths.first, line) }
    source["test/support.rb"] = "class Base; def setup; Fee.fee(true); end; end"
    reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(source), target, paths, Set.new)
    assert_equal :unknown, reach.inspect_test(paths.first, 4)
  end
end
