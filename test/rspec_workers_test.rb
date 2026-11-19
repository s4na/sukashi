require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/sukashi/comparison"

class RSpecWorkersTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("sukashi-workers")
    @previous = Dir.pwd
    Dir.chdir(@root)
    FileUtils.mkdir_p("spec")
    %w[first second].each do |name|
      File.write("spec/#{name}_spec.rb", "RSpec.describe('#{name}') { it('passes') { expect(true).to eq(true) } }")
    end
    File.write("workers.rb", <<~'RUBY')
      require "rbconfig"
      mode = ARGV.shift
      options = ARGV
      paths = Dir["spec/*_spec.rb"].sort
      paths = paths.first(1) if mode == "omit" && !options.include?("--dry-run")
      paths = [paths.first, paths.first] if mode == "duplicate"
      pids = paths.map { |path| Process.spawn(RbConfig.ruby, "-S", "rspec", path, *options) }
      statuses = pids.map { |pid| Process.wait2(pid).last }
      dir = ENV["SUKASHI_REPORT_DIR"]
      if dir && mode == "missing"
        File.unlink(File.join(dir, "rspec-#{pids.last}.json"))
      elsif dir && mode == "malformed"
        File.write(File.join(dir, "rspec-#{pids.last}.json"), "{")
      end
      exit(statuses.all?(&:success?) ? 0 : 1)
    RUBY
  end

  def teardown
    Dir.chdir(@previous)
    FileUtils.remove_entry(@root)
  end

  def runner(mode = "normal")
    Sukashi::Runner.new({ "runner" => "rspec", "command" => [RbConfig.ruby, "workers.rb", mode] }, 123)
  end

  def test_serial_inventory_and_execution
    serial = Sukashi::Runner.new({ "runner" => "rspec", "command" => [RbConfig.ruby, "-S", "rspec", "spec"] }, 123)
    inventory = serial.invoke(discover: true)
    assert inventory.ok
    assert_equal 2, inventory.ids.size
    full = serial.invoke
    assert full.ok
    assert_equal inventory.ids, full.ids
    selected = serial.invoke(ids: [inventory.ids.first])
    assert selected.ok
    assert_equal [inventory.ids.first], selected.ids
  end

  def test_two_workers_discover_select_and_report
    inventory = runner.invoke(discover: true)
    assert inventory.ok
    assert_equal 2, inventory.ids.size
    full = runner.invoke
    assert full.ok
    assert_equal inventory.ids, full.ids
    selected = runner.invoke(ids: [inventory.ids.first])
    assert selected.ok
    assert_equal [inventory.ids.first], selected.ids
  end

  def test_missing_duplicate_and_malformed_reports_fail_closed
    %w[missing duplicate malformed].each do |mode|
      result = runner(mode).invoke
      refute result.ok, mode
      assert_equal [], result.rows, mode
      discovery = runner(mode).invoke(discover: true)
      refute discovery.ok, mode
    end
  end

  def test_selected_run_preserves_history_for_only_failures
    File.write("history_config.rb", <<~RUBY)
      RSpec.configure { |config| config.example_status_persistence_file_path = "example_status.txt" }
    RUBY
    command = [RbConfig.ruby, "-S", "rspec", "--require", "./history_config.rb", "spec"]
    job = { "runner" => "rspec", "command" => command }
    paths = Dir["spec/*_spec.rb"]
    paths.each { |path| File.write(path, File.read(path).sub("eq(true)", "eq(false)")) }
    failures = Sukashi::Runner.new(job, 123).invoke.failures
    assert_equal 2, failures.size
    paths.each { |path| File.write(path, File.read(path).sub("eq(false)", "eq(true)")) }

    runner = Sukashi::Runner.new(job.merge("command" => command + ["--only-failures"]), 123)
    history = File.read("example_status.txt")
    assert_equal failures, runner.invoke(discover: true).ids
    selected = runner.invoke(ids: [failures.first])
    assert selected.ok
    assert_equal [failures.first], selected.ids
    assert_equal history, File.read("example_status.txt")

    full = runner.invoke
    assert full.ok
    assert_equal failures, full.ids
    assert_empty runner.invoke(discover: true).ids
  end

  def test_abnormal_worker_exit_is_not_success
    File.write("spec/second_spec.rb", "RSpec.describe('second') { it('exits') { exit! 3 } }")
    result = runner.invoke
    refute result.ok
    assert_equal [], result.rows
  end

  def test_missing_entire_worker_is_rejected_against_known_inventory
    inventory = runner("omit").invoke(discover: true)
    assert inventory.ok
    assert_equal 2, inventory.ids.size
    decision = { "mode" => "full", "inventory" => inventory.ids }
    report = Sukashi::Comparison.new(nil, nil, nil).send(:compare, runner("omit"), decision, "rspec")
    assert report["inventory_drift"]
    refute report["ok"]
  end

  def test_failed_worker_is_preserved
    File.write("spec/second_spec.rb", "RSpec.describe('second') { it('fails') { expect(false).to eq(true) } }")
    result = runner.invoke
    refute result.ok
    assert_equal 2, result.ids.size
    assert_equal 1, result.failures.size
  end

  def test_uninstrumented_wrapper_is_opaque_not_an_empty_inventory
    job = { "runner" => "rspec", "command" => [RbConfig.ruby, "-e", "exit 0", "--"] }
    uninstrumented = Sukashi::Runner.new(job, 123)
    result = uninstrumented.invoke
    assert result.ok
    assert_nil result.rows
    report = Sukashi::Comparison.new(nil, nil, nil).send(:compare, uninstrumented, { "mode" => "full" }, "rspec")
    assert report["full_only_job"]
    assert report["ok"]
  end
  def test_report_summary_and_rows_are_validated
    Dir.mktmpdir do |dir|
      file = File.join(dir, "rspec-123.json")
      File.write(file + ".started", "")
      [
        { "summary" => { "example_count" => 1, "errors_outside_of_examples_count" => 0 }, "examples" => [] },
        { "summary" => { "example_count" => 0, "errors_outside_of_examples_count" => 1 }, "examples" => [] },
        { "summary" => { "example_count" => 1, "errors_outside_of_examples_count" => 0 }, "examples" => [{ "id" => "missing metadata" }] }
      ].each do |report|
        File.write(file, JSON.generate(report))
        assert_raises(Sukashi::Runner::InvalidReport) { runner.send(:read_reports, dir) }
      end
    end
  end
end
