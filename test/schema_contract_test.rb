require "minitest/autorun"
require "json"
require "open3"
require_relative "../lib/sukashi/comparison"
require_relative "../lib/sukashi/configuration"

class SchemaContractTest < Minitest::Test

  def stub_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    object.define_singleton_method(name, original)
  end
  Repo = Struct.new(:changed, :sources, :clean) do
    def clean?(_); clean; end
    def changes(*); changed.map(&:dup); end
    def ruby_sources(rev); sources.fetch(rev); end
    def revision(_); "head"; end
  end
  Config = Struct.new(:jobs, :fingerprint, :ignore, :full_on, :assume) do
    def initialize(*args)
      super
      self.full_on ||= Sukashi::Configuration::DEFAULT_FULL_ON
      self.assume ||= []
    end
  end
  RUNTIME = { "status" => "verified", "fingerprints" => ["a" * 64] }.freeze
  ROWS = [
    { "id" => "T#test_gift", "file" => "test/fee_test.rb", "line" => 2, "status" => "passed" },
    { "id" => "T#test_regular", "file" => "test/fee_test.rb", "line" => 3, "status" => "passed" }
  ].freeze

  def config
    Config.new({ "tests" => { "runner" => "minitest", "command" => ["ruby"] } }, "fingerprint", [])
  end

  def repo(changed = [["lib/fee.rb", "lib/fee.rb"]])
    tests = "class T\n def test_gift; Fee.fee(true); end\n def test_regular; Fee.fee(false); end\nend"
    old = { "lib/fee.rb" => "class Fee; def self.fee(gift); if gift; 500; else; 100; end; end; end",
            "test/fee_test.rb" => tests }
    Repo.new(changed, { "base" => old, "head" => old.merge("lib/fee.rb" => old["lib/fee.rb"].sub("500", "700")) }, true)
  end

  def plan(repository, base: "base", rows: ROWS)
    result = Sukashi::Result.new(ok: true, rows: rows, runtime_identity: RUNTIME)
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| result }
    stub_method(Sukashi::Runner, :new, runner) { Sukashi::Planner.new(repository, config, "head", base, 1).plan }
  end

  def validate(kind, document, valid: true)
    schema = JSON.parse(File.read(File.expand_path("../schema/#{kind}.v1.json", __dir__)))
    script = <<~PYTHON
      import json, sys
      from jsonschema import Draft202012Validator
      payload = json.load(sys.stdin)
      Draft202012Validator.check_schema(payload["schema"])
      errors = list(Draft202012Validator(payload["schema"]).iter_errors(payload["document"]))
      for error in errors:
          print(error.message)
      sys.exit(1 if errors else 0)
    PYTHON
    out, err, status = Open3.capture3("python3", "-c", script,
      stdin_data: JSON.generate("schema" => schema, "document" => document))
    assert_equal valid, status.success?, "#{kind}: #{out}\n#{err}"
  end

  def test_real_subset_has_codes_without_changing_legacy_strings
    result = plan(repo)
    validate("plan", result)
    job = result.fetch("jobs").fetch("tests")
    assert_equal "subset", job.fetch("mode")
    assert_equal "reaches changed arm", job.fetch("selected").fetch("T#test_gift")
    assert_equal "changed_arm", job.fetch("selected_details").fetch("T#test_gift").fetch("code")
    assert_equal "unchanged_arm", job.fetch("excluded_details").fetch("T#test_regular").fetch("code")
  end

  def test_skip_shared_history_inventory_and_parse_fallbacks
    examples = [
      [plan(repo([])), "no_executable_changes"],
      [plan(repo([["config/routes.rb", "config/routes.rb"]])), "shared_dependency"],
      [plan(repo, base: nil), "merge_base_unavailable"],
      [plan(repo, rows: []), "inventory_unavailable"]
    ]
    invalid = repo
    invalid.sources["head"]["lib/fee.rb"] = "class"
    examples << [plan(invalid), "parse_failed"]
    examples.each do |document, code|
      validate("plan", document)
      assert_equal code, document.dig("jobs", "tests", "reason_detail", "code")
    end
    assert_equal "config/routes.rb", examples[1][0].dig("jobs", "tests", "reason_detail", "path")
  end

  def test_report_and_legacy_plan_reason
    document = plan(repo([]))
    document.delete("schema_minor")
    document["jobs"]["tests"].delete("reason_detail")
    validate("plan", document)
    result = Sukashi::Result.new(ok: true, rows: ROWS, seconds: 0.01, runtime_identity: RUNTIME, status: "passed")
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| result }
    report = stub_method(Sukashi::Runner, :new, runner) { Sukashi::Comparison.new(repo, config, document).run }
    validate("report", report)
    assert_equal 1, report.fetch("version")
    assert_equal "legacy_reason", report.dig("jobs", "tests", "reason_detail", "code")
    assert_equal "no executable changes", report.dig("jobs", "tests", "reason")
  end

  def test_invalid_plan_with_opaque_command_report
    cfg = Config.new({ "custom" => { "runner" => "command", "command" => ["ruby"] } }, "f", [])
    result = Sukashi::Result.new(ok: false, rows: nil)
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| result }
    report = stub_method(Sukashi::Runner, :new, runner) { Sukashi::Comparison.new(repo, cfg, {}).run }
    validate("report", report)
    assert_equal "invalid_plan", report.dig("jobs", "custom", "reason_detail", "code")
    refute report.fetch("ok")
  end

  def test_schema_rejects_wrong_version_mode_and_ids
    document = plan(repo)
    document["version"] = 2
    validate("plan", document, valid: false)
    document["version"] = 1
    document["jobs"]["tests"]["mode"] = "unsafe"
    validate("plan", document, valid: false)
    document["jobs"]["tests"]["mode"] = "subset"
    document["jobs"]["tests"]["inventory"] = [123]
    validate("plan", document, valid: false)
  end

  def test_runtime_identity_fallbacks_have_codes
    result = Sukashi::Result.new(ok: true, rows: ROWS)
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| result }
    document = stub_method(Sukashi::Runner, :new, runner) { Sukashi::Planner.new(repo, config, "head", "base", 1).plan }
    validate("plan", document)
    assert_equal "runtime_identity_unavailable", document.dig("jobs", "tests", "reason_detail", "code")

    saved = plan(repo)
    changed = Sukashi::Result.new(ok: true, rows: ROWS, seconds: 0.01, status: "passed",
                                  runtime_identity: { "status" => "verified", "fingerprints" => ["b" * 64] })
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| changed }
    report = stub_method(Sukashi::Runner, :new, runner) { Sukashi::Comparison.new(repo, config, saved).run }
    validate("report", report)
    assert_equal "runtime_identity_changed", report.dig("jobs", "tests", "reason_detail", "code")
    assert_equal "strict", report.fetch("failure_policy")
    assert_equal "passed", report.dig("jobs", "tests", "full_status")
  end

  def test_all_codes_are_documented_and_schema_valid
    Sukashi::Reasons::MESSAGES.each_key do |code|
      assert_includes File.read(File.expand_path("../docs/json-contract.md", __dir__)), code
    end
  end

  def test_minor_versions_accept_unknown_reason_codes
    document = plan(repo)
    document["schema_minor"] = 2
    document["jobs"]["tests"]["selected_details"].each_value { |detail| detail["code"] = "future_selected_reason" }
    document["jobs"]["tests"]["excluded_details"].each_value { |detail| detail["code"] = "future_excluded_reason" }
    validate("plan", document)
    document = plan(repo([]))
    document["schema_minor"] = 2
    document["jobs"]["tests"]["reason_detail"]["code"] = "future_full_reason"
    validate("plan", document)
    result = Sukashi::Result.new(ok: true, rows: ROWS, seconds: 0.01, runtime_identity: RUNTIME, status: "passed")
    runner = Object.new
    runner.define_singleton_method(:invoke) { |**_| result }
    report = stub_method(Sukashi::Runner, :new, runner) { Sukashi::Comparison.new(repo, config, document).run }
    report["schema_minor"] = 2
    validate("report", report)
    assert_equal "future_full_reason", report.dig("jobs", "tests", "reason_detail", "code")
  end
end
