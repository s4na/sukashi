require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "../lib/sukashi/cli"

class DiagnosticsTest < Minitest::Test

  def stub_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    object.define_singleton_method(name, original)
  end
  def test_user_error_is_exit_two_without_backtrace
    code = nil
    out, err = capture_io { code = Sukashi::CLI.call(["not-a-command"]) }
    assert_equal 2, code
    assert_empty out
    assert_includes err, "Usage:"
    refute_includes err, "cli.rb:"
  end

  def test_verbose_and_environment_debug_show_user_backtraces
    previous = ENV["SUKASHI_DEBUG"]
    [["not-a-command", "--verbose"], ["not-a-command"]].each_with_index do |argv, index|
      ENV["SUKASHI_DEBUG"] = index == 1 ? "1" : nil
      _, err = capture_io { assert_equal 2, Sukashi::CLI.call(argv) }
      assert_includes err, "cli.rb:"
    end
  ensure
    ENV["SUKASHI_DEBUG"] = previous
  end

  def test_internal_argument_error_is_exit_three_with_backtrace
    stub_method(Sukashi::Repository, :new, -> { raise ArgumentError, "broken invariant" }) do
      out, err = capture_io { assert_equal 3, Sukashi::CLI.call(["plan", "--base", "HEAD"]) }
      assert_empty out
      assert_includes err, "internal error"
      assert_includes err, "ArgumentError"
      assert_includes err, "broken invariant"
      assert_includes err, "diagnostics_test.rb:"
    end
  end

  def test_missing_jobs_and_invalid_yaml_are_user_errors
    Dir.mktmpdir do |dir|
      file = File.join(dir, "config.yml")
      ["ignore: []\n", "jobs: [\n"].each do |content|
        File.write(file, content)
        assert_raises(Sukashi::Error) { Sukashi::Configuration.new(file) }
      end
      assert_raises(Sukashi::Error) { Sukashi::Configuration.new(File.join(dir, "missing.yml")) }
      assert_raises(Sukashi::Error) { Sukashi::CLI.read_plan(File.join(dir, "missing.json")) }
    end
  end

  def test_nul_process_arguments_are_user_errors
    Dir.mktmpdir do |dir|
      file = File.join(dir, "config.yml")
      data = { "jobs" => { "suite" => { "runner" => "command", "command" => ["ruby", "bad\0argument"] } } }
      File.write(file, YAML.dump(data))
      assert_raises(Sukashi::Error) { Sukashi::Configuration.new(file) }
    end
    assert_raises(Sukashi::Error) { Sukashi::Repository.new.revision("bad\0ref") }
    repo = Sukashi::Repository.new
    stub_method(Sukashi::Repository, :new, repo) do
      original_git = repo.method(:git)
      stub_method(repo, :git, ->(*args) { args == ["rev-parse", "--show-prefix"] ? "" : original_git.call(*args) }) do
        _, err = capture_io { assert_equal 2, Sukashi::CLI.call(["plan", "--head", "bad\0ref", "--base", "HEAD"]) }
        refute_includes err, "internal error"
        assert_includes err, "NUL"
      end
    end
  end

  def test_git_error_keeps_stderr_and_debug_command
    status = Struct.new(:exitstatus) { def success?; false; end }.new(128)
    stub_method(Open3, :capture3, ["", "fatal: bad revision\n", status]) do
      _, err = capture_io do
        Sukashi::Diagnostics.with_debug(true) do
          error = assert_raises(Sukashi::Error) { Sukashi::Repository.new.git("diff", "missing") }
          assert_includes error.message, "fatal: bad revision"
          assert_includes error.message, "exit 128"
        end
      end
      assert_includes err, "git diff missing"
    end
  end

  def test_debug_scope_is_restored
    Sukashi::Diagnostics.with_debug(false) do
      Sukashi::Diagnostics.with_debug(true) { assert Sukashi::Diagnostics.debug? }
      refute Sukashi::Diagnostics.debug? unless ENV["SUKASHI_DEBUG"] == "1"
    end
  end

  def test_launch_failure_is_not_a_test_failure
    missing = Sukashi::Runner.new({ "runner" => "command", "command" => ["sukashi-nonexistent-test-command"] }, 1)
    result = nil
    capture_io { result = missing.invoke(plain: true) }
    refute result.ok
    assert_equal "failed_to_start", result.status
    failing = Sukashi::Runner.new({ "runner" => "command", "command" => [RbConfig.ruby, "-e", "exit 1"] }, 1).invoke(plain: true)
    refute failing.ok
    assert_equal "failed", failing.status
    passing = Sukashi::Runner.new({ "runner" => "command", "command" => [RbConfig.ruby, "-e", "exit 0"] }, 1).invoke(plain: true)
    assert_equal "passed", passing.status
  end

  def test_minitest_failure_survives_a_successful_wrapper
    Dir.mktmpdir do |dir|
      suite = File.join(dir, "wrapper_test.rb")
      File.write(suite, <<~RUBY)
        require "minitest/autorun"
        class WrapperTest < Minitest::Test
          def test_value
            flunk "recorded failure"
          end
        end
      RUBY
      wrapper = 'system(RbConfig.ruby, ARGV.fetch(0)); exit 0'
      job = { "runner" => "minitest", "command" => [RbConfig.ruby, "-e", wrapper, suite] }
      report = Sukashi::Comparison.new(nil, nil, {}).send(:compare, Sukashi::Runner.new(job, 1), { "mode" => "full" }, "minitest")
      assert_equal ["WrapperTest#test_value"], report.fetch("full_failures")
      assert_equal "failed", report.fetch("full_status")
      refute report.fetch("ok")
    end
  end

  def test_incomplete_minitest_worker_cannot_be_hidden_by_its_wrapper
    Dir.mktmpdir do |dir|
      suite = File.join(dir, "interrupted_test.rb")
      File.write(suite, <<~RUBY)
        require "minitest/autorun"
        class InterruptedTest < Minitest::Test
          def test_shutdown
            exit! 17
          end
        end
      RUBY
      wrapper = 'system(RbConfig.ruby, ARGV.fetch(0)); exit 0'
      job = { "runner" => "minitest", "command" => [RbConfig.ruby, "-e", wrapper, suite] }
      runner = Sukashi::Runner.new(job, 1)
      report = Sukashi::Comparison.new(nil, nil, {}).send(:compare, runner, { "mode" => "full" }, "minitest")
      assert_equal "failed", report.fetch("full_status")
      refute report.fetch("ok")
    end
  end

  def test_minitest_signal_before_reporter_startup_is_not_retried_as_plain
    # A plain retry would exit successfully and mask the signal.
    command = [RbConfig.ruby, "-e", 'Process.kill("KILL", Process.pid) if ENV["SUKASHI_REPORT_DIR"]']
    runner = Sukashi::Runner.new({ "runner" => "minitest", "command" => command }, 1)
    report = Sukashi::Comparison.new(nil, nil, {}).send(:compare, runner, { "mode" => "full" }, "minitest")
    assert_equal "failed", report.fetch("full_status")
    refute report.fetch("ok")
  end

  def test_comparison_serializes_launch_status
    config = Struct.new(:jobs, :fingerprint).new(
      { "custom" => { "runner" => "command", "command" => ["sukashi-nonexistent-test-command"] } }, "config")
    repo = Object.new
    def repo.revision(_); "head"; end
    report = nil
    capture_io { report = Sukashi::Comparison.new(repo, config, {}).run }
    refute report.fetch("ok")
    assert_equal "failed_to_start", report.dig("jobs", "custom", "full_status")
    assert_nil report.dig("jobs", "custom", "selected_status")
  end
end
