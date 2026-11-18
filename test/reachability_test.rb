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
      "orders.rb" => "class OrdersController < BaseController; def show; render plain: Fee.fee(false); end; end",
      "config/routes.rb" => 'Rails.application.routes.draw { get "/orders", to: "orders#show" }',
      "test/example_test.rb" => "class ExampleTest; def test_unit; Fee.fee(false); end\n def test_http; get '/orders'; end; end"
    )
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    path = "test/example_test.rb"
    prefixes = ["", "prepend_", "append_"]
    registrations = prefixes.product(%w[before_action around_action after_action]).map { |prefix, name| "#{prefix}#{name} :charge" }
    registrations << "set_callback :process_action, :after, :charge"
    registrations << "def render(...); Fee.fee(true); super; end"
    registrations << "def charge; Fee.fee(true); end; alias render charge"
    registrations.each do |registration|
      sources["base.rb"] = "class BaseController; #{registration}; end"
      reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
      assert_equal :other_arm, reach.inspect_test(path, 1), registration
      assert_equal :unknown, reach.inspect_test(path, 2), registration
    end
  end

  def test_aliased_controller_action_keeps_the_request
    path = "test/orders_test.rb"
    sources = index("500").sources.merge(
      "orders.rb" => "class OrdersController; def regular; render plain: Fee.fee(false); end; def gift; render plain: Fee.fee(true); end; alias regular gift; end",
      "config/routes.rb" => 'Rails.application.routes.draw { get "/orders", to: "orders#regular" }',
      path => "class T; def test_fee; get '/orders'; end; end"
    )
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
    assert_equal :unknown, reach.inspect_test(path, 1)
  end

  def test_request_using_a_named_route_helper_can_execute_either_arm
    path = "test/orders_test.rb"
    sources = index("500").sources.merge(
      "config/routes.rb" => 'Rails.application.routes.draw { resources :orders }',
      "orders.rb" => "class OrdersController; def index; render plain: Fee.fee(false); end; end",
      path => "class T; def orders_path; Fee.fee(true); '/orders'; end\n  def test_named; get orders_path; end\n  def test_literal; get '/orders'; end; end"
    )
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
    assert_equal :unknown, reach.inspect_test(path, 2)
    assert_equal :other_arm, reach.inspect_test(path, 3)
  end

  def test_rack_middleware_keeps_http_paths_without_widening_unit_tests
    sources = index("500").sources.merge(
      "orders.rb" => "class OrdersController; def show; render plain: Fee.fee(false); end; end",
      "config/routes.rb" => 'Rails.application.routes.draw { get "/orders", to: "orders#show" }',
      "test/fees.rb" => "class T; def test_unit; Fee.fee(false); end\n def test_http; get '/orders'; end; end"
    )
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    path = "test/fees.rb"
    [
      ["config/initializers/billing.rb", "config.middleware.use BillingMiddleware", :unknown],
      ["config.ru", "use BillingMiddleware; run Rails.application", :unknown],
      ["config.ru", "run Rails.application", :other_arm]
    ].each do |file, config, expected|
      idx = Sukashi::SourceIndex.new(sources.merge(file => config))
      reach = Sukashi::Reachability.new(idx, target, Set[path], Set.new)
      assert_equal :other_arm, reach.inspect_test(path, 1)
      assert_equal expected, reach.inspect_test(path, 2)
    end
  end

  def test_unindexed_views_keep_requests_even_if_the_action_calls_the_other_arm
    ["render :regular", "render partial: 'fee'", "render plain: 'fee', layout: true", "nil"].each do |response|
      sources = index("500").sources.merge(
        "orders.rb" => "class OrdersController; def show; Fee.fee(false); #{response}; end; end",
        "config/routes.rb" => 'Rails.application.routes.draw { get "/orders", to: "orders#show" }',
        "test/request_test.rb" => "class RequestTest; def test_fee; get '/orders'; end; end"
      )
      target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
      path = "test/request_test.rb"
      reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
      assert_equal :unknown, reach.inspect_test(path, 1), response
    end
  end

  def test_explicit_receiver_redefinition_outside_class_body
    path = "test/fee_test.rb"
    reopened = index("500").sources.merge(
      "override.rb" => "def Fee.fee(gift); saved_fee(true); end",
      path => "class T; def test_fee; Fee.fee(false); end; end"
    )
    idx = Sukashi::SourceIndex.new(reopened)
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    assert_equal 2, idx.methods.fetch(["Fee", true, :fee]).size
    assert_equal :unknown, Sukashi::Reachability.new(idx, target, Set[path], Set.new).inspect_test(path, 1)
  end

  def test_lexical_receiver_can_be_a_constant_alias
    path = "test/fee_test.rb"
    ["module Shop; Fee = ::OtherFee; end", "Shop::Fee = OtherFee", "Shop.const_set(:Fee, OtherFee)"].each do |definition|
      idx = Sukashi::SourceIndex.new(index("500").sources.merge(
        "aliases.rb" => definition, path => "module Shop; class T; def test_fee; Fee.fee(false); end; end; end"
      ))
      target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
      assert_equal :unknown, Sukashi::Reachability.new(idx, target, Set[path], Set.new).inspect_test(path, 1)
    end
  end

  def test_group_registration_dsl_and_alternate_configuration_hooks
    path = "spec/fee_spec.rb"
    ["prepend_before", "append_after", "install_project_hooks"].each do |registration|
      src = "RSpec.describe(Fee) do\n #{registration} { Fee.fee(true) }\n it('regular') { Fee.fee(false) }\nend"
      idx = Sukashi::SourceIndex.new(index("500").sources.merge(path => src))
      assert_includes idx.hooks, path
      refute_includes idx.unscoped_hooks, path
    end
    idx = Sukashi::SourceIndex.new(path => "RSpec.configure { |c| c.prepend_before { Fee.fee(true) } }")
    assert_includes idx.unscoped_hooks, path
  end

  def test_refinements_keep_calls_with_lexically_changed_dispatch
    path = "test/fee_test.rb"
    src = "class T; def test_fee; Fee.fee(false); end; end"
    target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
    [
      { path => "using ExternalOverrides; #{src}" },
      { path => src, "override.rb" => "module Alternate; refine(Fee.singleton_class) { def fee(arg); super(true); end }; end" }
    ].each do |extra|
      idx = Sukashi::SourceIndex.new(index("500").sources.merge(extra))
      assert_equal :unknown, Sukashi::Reachability.new(idx, target, Set[path], Set.new).inspect_test(path, 1)
    end
  end

  def test_wrapped_class_method_is_not_a_proven_branch
    ["Fee.singleton_class.prepend(Override)", "Fee.extend(Override)", "class Fee; class << self; prepend Override; end; end"].each do |wrapper|
      path = "test/fee_test.rb"
      sources = index("500").sources.merge("overrides.rb" => wrapper, path => "class T; def test_fee; Fee.fee(false); end; end")
      target = { ["Fee", true, :fee] => { paths: ["lib/fee.rb"], arms: [true] } }
      reach = Sukashi::Reachability.new(Sukashi::SourceIndex.new(sources), target, Set[path], Set.new)
      assert_equal :unknown, reach.inspect_test(path, 1), wrapper
    end
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
