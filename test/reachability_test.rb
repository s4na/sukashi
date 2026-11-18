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
