require "minitest/autorun"
require "set"
require_relative "../lib/sukashi/constant_reachability"

class ConstantReachabilityTest < Minitest::Test
  TESTS = Set["test/coupon_test.rb", "test/other_test.rb"].freeze
  BASE = {
    "app/models/coupon.rb" => "class Coupon; def self.rate(x); x ? 1 : 0; end; end",
    "app/models/other.rb" => "class Other; def self.run; 1; end; end",
    "test/coupon_test.rb" => "class CouponTest; def test_rate; Coupon.rate(true); end; end",
    "test/other_test.rb" => "class OtherTest; def test_run; Other.run; end; end"
  }.freeze

  def analysis(extra = {}, external: Set.new, shared: ->(_) { false })
    index = Sukashi::SourceIndex.new(BASE.merge(extra))
    Sukashi::ConstantReachability.new(index, TESTS, shared: shared, external: external)
  end

  def closure(extra = {}, **options)
    analysis(extra, **options).closure(["app/models/coupon.rb"])
  end

  def assert_escapes(extra, reason, **options)
    subject = analysis(extra, **options)
    assert_nil subject.closure(["app/models/coupon.rb"])
    assert_match reason, subject.escape
  end

  def test_constant_references_bound_the_closure
    reach = closure
    assert_includes reach, "test/coupon_test.rb"
    refute_includes reach, "test/other_test.rb"
    refute_includes reach, "app/models/other.rb"
  end

  def test_name_strings_and_plural_symbols_join_the_closure
    reach = closure("app/models/other.rb" => "class Other; has_many :coupons; def self.run; 1; end; end")
    assert_includes reach, "test/other_test.rb"
    reach = closure("app/models/other.rb" => "class Other; def self.run; 'Coupon'; end; end")
    assert_includes reach, "test/other_test.rb"
  end

  def test_irregular_plural_and_multiword_names
    forms = analysis.send(:name_forms, "SalesPerson")
    assert_includes forms, "sales_people"
    assert_includes forms, "SalesPeople"
    assert_includes analysis.send(:name_forms, "Category"), "catego"
    assert_includes analysis.send(:name_forms, "Leaf"), "lea"
  end

  def test_superclass_edge_except_abstract_bases
    extra = {
      "app/models/coupon.rb" => "class Coupon < Promotion; end",
      "app/models/promotion.rb" => "class Promotion; end",
      "app/models/other.rb" => "class Other; def self.run; Promotion.first; end; end"
    }
    assert_includes closure(extra), "test/other_test.rb"
    extra["app/models/promotion.rb"] = "class Promotion; self.abstract_class = true; end"
    refute_includes closure(extra), "test/other_test.rb"
  end

  def test_reflection_with_a_computed_name_escapes
    assert_escapes({ "app/models/other.rb" => "class Other; def self.run(t); t.constantize; end; end" }, /reflective/)
    assert_escapes({ "app/models/other.rb" => "class Other; def self.run(t); Object.const_get(t); end; end" }, /reflective/)
    assert_escapes({ "app/models/other.rb" => "class Other; def self.run(m, a); send(m, a); end; end" }, /reflective/)
    assert_escapes({ "app/models/other.rb" => "class Other; def self.run; Base.descendants; end; end" }, /reflective/)
    refute_nil closure("app/models/other.rb" => "class Other; def self.run; 'Other'.constantize; send(:run); end; end")
  end

  def test_load_time_effects_in_the_closure_escape
    assert_escapes({ "app/models/coupon.rb" => "class Coupon; Registry.add(self); end" }, /load-time call on Registry/)
    assert_escapes({ "app/models/coupon.rb" => "class Coupon; def self.x; $last = 1; end; end" }, /global variable/)
    assert_escapes({ "app/models/coupon.rb" => "class String; end" }, /external namespace/)
    assert_escapes({ "app/models/coupon.rb" => "module Rails; class Coupon; end; end" }, /external namespace/,
                   external: Set["rails"])
    assert_escapes({ "app/controllers/coupons_controller.rb" => "class CouponsController; def i; Coupon; end; end" },
                   /controller/)
    assert_escapes({ "lib/setup.rb" => "Coupon.rate(true)" }, /full_on/, shared: ->(path) { path == "lib/setup.rb" })
    refute_nil closure("app/models/coupon.rb" => "class Coupon; RATES = [1].freeze; scope :x, -> { Clock.now }; end")
  end

  def test_shared_hooks_in_the_closure_escape
    hook = { "spec/spec_helper.rb" => "RSpec.configure { |c| c.before { Coupon.rate(true) } }" }
    assert_escapes(hook, /shared setup/)
  end

  def test_eval_anywhere_escapes
    assert_escapes({ "lib/script.rb" => "eval(ARGV.first)" }, /eval/)
  end
end
