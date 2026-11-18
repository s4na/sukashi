require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"

class RuntimeIdentityTest < Minitest::Test
  CLI = File.expand_path("../exe/sukashi", __dir__)
  GEM_ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("runtime-identity")
    @root = File.join(@tmp, "project")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    FileUtils.mkdir_p(File.join(@root, "test"))
    File.write(File.join(@root, "lib/fee.rb"), <<~RUBY)
      class Fee
        def self.fee(gift)
          if gift
            500
          else
            100
          end
        end
      end
    RUBY
    File.write(File.join(@root, "test/fee_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/fee"
      class FeeTest < Minitest::Test
        def test_gift
          assert_equal 500, Fee.fee(true)
        end
        def test_regular
          assert_equal 100, Fee.fee(false)
        end
      end
    RUBY
    File.write(File.join(@root, ".sukashi.yml"), <<~YAML)
      jobs:
        unit:
          runner: minitest
          command: [ruby, test/fee_test.rb]
    YAML
    @gemfile = File.join(@tmp, "Gemfile")
    File.write(@gemfile, <<~RUBY)
      source "https://rubygems.org"
      gem "sukashi", path: #{GEM_ROOT.inspect}
      gem "minitest"
    RUBY
    @env = { "BUNDLE_GEMFILE" => @gemfile, "BUNDLE_LOCKFILE" => nil }
    command(RbConfig.ruby, "-S", "bundle", "lock", "--local")
    command("git", "init", "-q")
    command("git", "config", "user.name", "Test")
    command("git", "config", "user.email", "test@example.invalid")
    commit
    @base = command("git", "rev-parse", "HEAD").strip
    path = File.join(@root, "lib/fee.rb")
    File.write(path, File.read(path).sub("500", "5_00"))
    commit
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp
  end

  def command(*args)
    out, err, status = Open3.capture3(@env || {}, *args, chdir: @root)
    assert status.success?, "#{args.inspect}: #{out}\n#{err}"
    out
  end

  def commit
    command("git", "add", ".")
    command("git", "commit", "-qm", "fixture")
  end

  def cli(*args)
    JSON.parse(command(RbConfig.ruby, CLI, *args))
  end

  def plan
    cli("plan", "--base", @base)
  end

  def run_plan(value)
    path = File.join(@tmp, "saved-plan.json")
    File.write(path, JSON.generate(value))
    cli("run", "--plan", path).fetch("jobs").fetch("unit")
  end

  def test_unchanged_locked_environment_reuses_selection_without_exposing_paths
    value = plan
    assert_equal "verified", value.dig("runtime", "unit", "status")
    assert_equal "subset", value.dig("jobs", "unit", "mode")
    identity = JSON.generate(value.fetch("runtime"))
    refute_includes identity, @tmp
    refute_includes identity, GEM_ROOT
    refute_includes identity, "BUNDLE_GEMFILE"
    report = run_plan(value)
    assert_equal "subset", report.fetch("mode")
    assert_equal ["FeeTest#test_gift"], report.fetch("selected_ids")
    assert report.fetch("ok")
  end

  def test_changed_external_gemfile_and_runtime_options_invalidate_the_plan
    value = plan
    File.open(@gemfile, "a") { |file| file.puts "# changed outside the Git tree" }
    report = run_plan(value)
    assert_equal "full", report.fetch("mode")
    assert_match(/runtime identity/, report.fetch("reason"))
    fresh = plan
    @env["RUBYOPT"] = [ENV["RUBYOPT"], "-W0"].compact.join(" ")
    assert_equal "full", run_plan(fresh).fetch("mode")
  end

  def test_switching_gemfile_with_the_same_contents_invalidates_the_plan
    value = plan
    other = File.join(@tmp, "OtherGemfile")
    FileUtils.cp(@gemfile, other)
    FileUtils.cp(@gemfile + ".lock", other + ".lock")
    @env["BUNDLE_GEMFILE"] = other
    assert_equal "full", run_plan(value).fetch("mode")
  end

  def test_external_path_gem_is_opaque_before_and_after_an_untracked_edit
    gem_root = File.join(@tmp, "outside")
    FileUtils.mkdir_p(File.join(gem_root, "lib"))
    File.write(File.join(gem_root, "outside_example.gemspec"), <<~RUBY)
      Gem::Specification.new do |s|
        s.name = "outside_example"
        s.version = "0.1.0"
        s.summary = "Fixture"
        s.authors = ["Example"]
        s.files = ["lib/outside_example.rb"]
      end
    RUBY
    source = File.join(gem_root, "lib/outside_example.rb")
    File.write(source, "module OutsideExample; end\n")
    File.open(@gemfile, "a") { |file| file.puts "gem 'outside_example', path: #{gem_root.inspect}" }
    command(RbConfig.ruby, "-S", "bundle", "lock", "--local")
    value = plan
    assert_equal "full", value.dig("jobs", "unit", "mode")
    assert_equal "mutable_dependency", value.dig("runtime", "unit", "reason")
    File.write(source, "module OutsideExample; VALUE = 1; end\n")
    assert_equal "full", run_plan(value).fetch("mode")
    assert_equal "full", plan.dig("jobs", "unit", "mode")
  end

  def test_changed_discovery_inventory_cannot_reuse_a_subset
    value = plan
    value.fetch("jobs").fetch("unit")["inventory"] = ["FeeTest#test_gift"]
    assert_equal "full", run_plan(value).fetch("mode")
  end

  def test_missing_old_or_opaque_runtime_identity_cannot_reuse_a_subset
    value = plan
    [nil, {}, { "unit" => { "status" => "opaque", "reason" => "unavailable" } },
     { "unit" => { "status" => "verified", "fingerprints" => [] } }].each do |runtime|
      report = run_plan(value.merge("runtime" => runtime))
      assert_equal "full", report.fetch("mode")
      assert_match(/runtime identity/, report.fetch("reason"))
    end
  end
end
