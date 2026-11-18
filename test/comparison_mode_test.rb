require "minitest/autorun"
require "rbconfig"
require_relative "../lib/sukashi/comparison"

class ComparisonModeTest < Minitest::Test
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

  def result(ok: true, ids: ["a"], opaque: false)
    Sukashi::Result.new(ok: ok, seconds: 0.1,
      rows: opaque ? nil : ids.map { |id| { "id" => id, "status" => ok ? "passed" : "failed" } })
  end

  def compare(mode, runner, decision, kind = "rspec")
    Sukashi::Comparison.new(nil, nil, {}, mode: mode).send(:compare, runner, decision, kind)
  end

  def subset
    { "mode" => "subset", "inventory" => %w[a b], "selected" => { "a" => "changed" } }
  end

  def test_shadow_keeps_full_execution
    runner = FakeRunner.new(result, result(ids: %w[a b]))
    report = compare("shadow", runner, subset)
    assert report["ok"]
    assert_equal [{ ids: ["a"] }, { plain: false }], runner.calls
  end

  def test_shadow_keeps_plain_fallback_and_uses_its_exit_status
    [true, false].each do |ok|
      runner = FakeRunner.new(result(ok: false, opaque: true), result(ok: ok, opaque: true))
      report = compare("shadow", runner, { "mode" => "full" })
      assert_equal ok, report["ok"]
      assert report["full_only_job"]
      assert_equal [{ plain: false }, { plain: true }], runner.calls
    end
  end

  def test_enforce_subset_does_not_claim_full_comparison
    runner = FakeRunner.new(result)
    report = compare("enforce", runner, subset)
    assert report["ok"]
    assert_nil report["full_failures"]
    assert_nil report["full_only_failures"]
    refute report["comparison_performed"]
    assert_equal [{ ids: ["a"], plain: false }], runner.calls
  end

  def test_enforce_fails_on_missing_instrumentation_or_wrong_ids
    [result(opaque: true), result(ids: ["b"]), result(ok: false)].each do |value|
      runner = FakeRunner.new(value)
      refute compare("enforce", runner, subset)["ok"]
      assert_equal 1, runner.calls.size
    end
  end

  def test_enforce_skip_and_full_and_command
    runner = FakeRunner.new
    assert compare("enforce", runner, { "mode" => "skip", "inventory" => ["a"] })["ok"]
    assert_empty runner.calls
    runner = FakeRunner.new(result)
    assert compare("enforce", runner, { "mode" => "full" })["ok"]
    assert_equal 1, runner.calls.size
    runner = FakeRunner.new(result(opaque: true))
    report = compare("enforce", runner, { "mode" => "skip" }, "command")
    assert_equal "full", report["mode"]
    assert_equal [{ ids: nil, plain: true }], runner.calls
  end

  def test_enforce_skip_without_usable_inventory_runs_full
    [nil, [], ["a", "a"], [123]].each do |inventory|
      runner = FakeRunner.new(result(ok: false, opaque: true))
      report = compare("enforce", runner, { "mode" => "skip", "inventory" => inventory })
      assert_equal "full", report["mode"]
      refute report["ok"]
      assert_equal [{ ids: nil, plain: true }], runner.calls
    end
  end

  def test_enforce_full_detects_inventory_drift
    runner = FakeRunner.new(result(ids: ["a"]))
    report = compare("enforce", runner, { "mode" => "full", "inventory" => %w[a b] })
    assert report["inventory_drift"]
    refute report["ok"]
  end

  def test_shadow_full_only_and_opaque_are_not_reported_as_comparisons
    [[result], [result(opaque: true), result(opaque: true)]].each do |values|
      report = compare("shadow", FakeRunner.new(*values), { "mode" => "full" })
      refute report["comparison_performed"]
    end
  end

  def test_invalid_subset_falls_back_to_full
    runner = FakeRunner.new(result(ids: %w[a b]))
    decision = subset.merge("selected" => { "unknown" => "changed" })
    assert_equal "full", compare("enforce", runner, decision)["mode"]
    assert_equal [{ ids: nil, plain: false }], runner.calls
  end

  def test_enforce_full_without_inventory_runs_the_plain_typed_job_once
    [true, false].each do |ok|
      runner = FakeRunner.new(result(ok: ok, opaque: true))
      report = compare("enforce", runner, { "mode" => "full" })
      assert_equal ok, report["ok"]
      assert report["full_only_job"]
      assert_equal [{ ids: nil, plain: true }], runner.calls
    end
  end

  def test_enforce_subset_with_invalid_inventory_does_not_pass_ids
    [["a", "a"], ["a", 1]].each do |invalid|
      runner = FakeRunner.new(result(opaque: true))
      report = compare("enforce", runner, subset.merge("inventory" => invalid))
      assert_equal "full", report["mode"]
      assert_equal [{ ids: nil, plain: true }], runner.calls
    end
  end

  def test_enforce_full_with_known_inventory_rejects_a_missing_report
    runner = FakeRunner.new(result(opaque: true))
    report = compare("enforce", runner, { "mode" => "full", "inventory" => %w[a b] })
    assert report["inventory_drift"]
    refute report["ok"]
  end

  def test_stale_plan_runs_full_even_when_skip_was_saved
    repo = Object.new
    def repo.clean?(_head) = false
    def repo.revision(_ref) = "current"
    config = Struct.new(:jobs, :fingerprint).new({ "suite" => { "runner" => "command", "command" => [RbConfig.ruby, "-e", "exit 0"] } }, "config")
    plan = { "version" => 1, "config" => "config", "head" => "old", "jobs" => { "suite" => { "mode" => "skip" } } }
    report = Sukashi::Comparison.new(repo, config, plan, mode: "enforce").run
    assert_equal "full", report.dig("jobs", "suite", "mode")
    assert_equal "enforce", report["execution_mode"]
    assert report["ok"]
    assert_match(/stale/, report.dig("jobs", "suite", "reason"))
  end
end
