require "minitest/autorun"
require_relative "../lib/sukashi/comparison"

class FailureDiagnosisTest < Minitest::Test
  class FakeRunner
    attr_reader :calls
    def initialize(*results)
      @results, @calls = results, []
    end
    def invoke(**options)
      @calls << options
      raise "unexpected invocation" if @results.empty?
      @results.shift
    end
  end

  def result(statuses, ok: nil, exit_status: nil)
    rows = statuses&.map { |id, status| { "id" => id, "status" => status } }
    ok = rows && rows.none? { |row| row["status"] == "failed" } if ok.nil?
    Sukashi::Result.new(ok: ok, rows: rows, seconds: 0.2, exit_status: exit_status || (ok ? 0 : 1))
  end

  def decision
    { "mode" => "subset", "inventory" => %w[a b], "selected" => { "a" => "changed" } }
  end

  def compare(runner, policy: "strict", retry_enabled: true)
    Sukashi::Comparison.new(nil, nil, {}, retry_full_only: retry_enabled, failure_policy: policy).
      send(:compare, runner, decision, "rspec")
  end

  def scenario(retry_result, policy: "strict")
    runner = FakeRunner.new(result({ "a" => "passed" }),
      result({ "a" => "passed", "b" => "failed" }), retry_result)
    [compare(runner, policy: policy), runner]
  end

  def test_retry_failure_is_a_suspected_miss
    report, runner = scenario(result({ "b" => "failed" }), policy: "missed")
    assert_equal ["b"], report["missed_failures"]
    assert_empty report["flaky_or_order_dependent"]
    assert_equal({ ids: ["b"] }, runner.calls.last)
    refute report["ok"]
  end

  def test_retry_pass_is_classified_but_strict_remains_failing
    report, = scenario(result({ "b" => "passed" }))
    assert_equal ["b"], report["flaky_or_order_dependent"]
    assert_equal ["b"], report["full_only_failures"]
    refute report["ok"]
    relaxed, = scenario(result({ "b" => "passed" }), policy: "missed")
    assert relaxed["ok"]
  end

  def test_unknown_retry_never_relaxes_failure
    [result(nil, ok: false), result({ "b" => "skipped" }),
     result({ "other" => "passed" }), result({ "b" => "passed" }, ok: false)].each do |retry_result|
      report, = scenario(retry_result, policy: "missed")
      assert_equal ["b"], report["unclassified_full_only_failures"]
      refute report["ok"]
    end
  end

  def test_selected_only_failure_is_visible_and_failing
    runner = FakeRunner.new(result({ "a" => "failed" }), result({ "a" => "passed", "b" => "passed" }))
    report = compare(runner, policy: "missed")
    assert_equal ["a"], report["selected_only_failures"]
    assert_nil report["retry_seconds"]
    refute report["ok"]
    assert_equal 2, runner.calls.size
  end

  def test_abnormal_full_process_exit_is_not_relaxed
    runner = FakeRunner.new(result({ "a" => "passed" }),
      result({ "a" => "passed", "b" => "failed" }, exit_status: 42),
      result({ "b" => "passed" }))
    report = compare(runner, policy: "missed")
    refute report["ok"]
    assert_equal ["b"], report["flaky_or_order_dependent"]
  end

  def test_retry_is_opt_in
    runner = FakeRunner.new(result({ "a" => "passed" }), result({ "a" => "passed", "b" => "failed" }))
    report = compare(runner, retry_enabled: false)
    assert_equal ["b"], report["unclassified_full_only_failures"]
    assert_nil report["retry_ok"]
    assert_equal 2, runner.calls.size
    refute report["ok"]
  end

  def test_policy_requires_retry_and_rejects_unknown_values
    assert_raises(ArgumentError) { Sukashi::Comparison.new(nil, nil, {}, failure_policy: "missed") }
    assert_raises(ArgumentError) { Sukashi::Comparison.new(nil, nil, {}, failure_policy: "ignore") }
  end

  def test_mixed_retry_results_keep_unclassified_ids
    runner = FakeRunner.new(result({ "a" => "failed", "b" => "passed", "c" => "skipped" }))
    report = Sukashi::FailureDiagnosis.new(runner).call(%w[a b c], enabled: true)
    assert_equal ["a"], report["missed_failures"]
    assert_equal ["b"], report["flaky_or_order_dependent"]
    assert_equal ["c"], report["unclassified_full_only_failures"]
  end
end
