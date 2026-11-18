require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Exercise the installed command boundary, real Rails routing, RSpec and Minitest.
class SelectionTest < Minitest::Test
  CLI = File.expand_path("../exe/sukashi", __dir__)

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), text)
  end

  def cmd(*args)
    out, err, status = Open3.capture3(*args, chdir: @root)
    assert status.success?, "#{args.inspect}: #{out}\n#{err}"
    out.strip
  end

  def cli(*args, code: 0)
    out, err, status = Open3.capture3(CLI, *args, chdir: @root)
    assert_equal code, status.exitstatus, "#{out}\n#{err}"
    JSON.parse(out)
  end

  def setup
    @root = Dir.mktmpdir
    cmd("git", "init", "-q")
    cmd("git", "config", "user.name", "Test")
    cmd("git", "config", "user.email", "test@example.invalid")
    write("app/models/order_fee.rb", <<~RUBY)
      class OrderFee
        def self.fee(gift)
          if gift
            500
          else
            100
          end
        end
      end
    RUBY
    write("config/routes.rb", <<~RUBY)
      Rails.application.routes.draw do
        get "/gift", to: "orders#gift"
        get "/regular", to: "orders#regular"
      end
    RUBY
    write("app/controllers/orders_controller.rb", <<~RUBY)
      class OrdersController < ActionController::Base
        def gift
          render plain: OrderFee.fee(true)
        end
        def regular
          render plain: OrderFee.fee(false)
        end
      end
    RUBY
    write("config/environment.rb", <<~RUBY)
      ENV["RAILS_ENV"] = "test"
      require "rails"
      require "action_controller/railtie"
      class ExampleApp < Rails::Application
        config.root = File.expand_path("..", __dir__)
        config.eager_load = false
        config.secret_key_base = "a" * 64
        config.hosts.clear
        config.logger = Logger.new(File::NULL)
      end
      Rails.application.initialize!
    RUBY
    write("spec/rails_helper.rb", <<~RUBY)
      require_relative "../config/environment"
      require "rspec/rails"
      require "capybara/rspec"
      RSpec.configure { |config| config.include Rails.application.routes.url_helpers }
    RUBY
    write("spec/requests/orders_spec.rb", <<~RUBY)
      require_relative "../rails_helper"
      RSpec.describe "orders", type: :request do
        it("regular") { get "/regular"; expect(response.body).to eq("100") }
        it("gift") { get "/gift"; expect(response.body).to eq("500") }
      end
    RUBY
    write("spec/system/order_spec.rb", <<~RUBY)
      require_relative "../rails_helper"
      RSpec.describe "ordering", type: :system do
        it "shows the gift fee" do
          driven_by :rack_test
          visit "/gift"
          expect(page).to have_text("500")
        end
      end
    RUBY
    write("test/fee_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../app/models/order_fee"
      class GiftTest < Minitest::Test
        def test_fee
          assert_equal 500, OrderFee.fee(true)
        end
      end
      class RegularTest < Minitest::Test
        def test_fee
          assert_equal 100, OrderFee.fee(false)
        end
      end
    RUBY
    commit("base")
    @base = cmd("git", "rev-parse", "HEAD")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def commit(message)
    cmd("git", "add", ".")
    cmd("git", "commit", "-qm", message)
  end

  def change_fee(from, to)
    path = "app/models/order_fee.rb"
    write(path, File.read(File.join(@root, path)).sub(from, to))
    commit("fee change")
  end

  def test_branch_selection_and_comparison
    change_fee("500", "700")
    plan = cli("plan", "--base", @base)
    jobs = plan.fetch("jobs")
    assert_equal ["GiftTest#test_fee"], jobs.fetch("minitest").fetch("selected").keys
    ids = ["./spec/requests/orders_spec.rb[1:2]", "./spec/system/order_spec.rb[1:1]"]
    assert_equal ids, jobs.fetch("rspec").fetch("selected").keys
    write("plan.json", plan.to_json)
    report = cli("run", "--plan", "plan.json", code: 1)
    report.fetch("jobs").each_value do |job|
      refute job.fetch("inventory_drift")
      assert_equal job.fetch("selected_ids"), job.fetch("executed_ids")
      assert_equal job.fetch("selected_failures"), job.fetch("full_failures")
      refute_empty job.fetch("full_failures")
      assert_empty job.fetch("full_only_failures")
    end
    jobs.fetch("rspec").fetch("selected").delete(ids.last)
    write("plan.json", plan.to_json)
    missed = cli("run", "--plan", "plan.json", code: 1)
    assert_equal [ids.last], missed.dig("jobs", "rspec", "full_only_failures")
  end

  def test_custom_job_preserves_directory_and_selects_individual_examples
    write(".sukashi.yml", <<~YAML)
      jobs:
        requests:
          runner: rspec
          command: [rspec, spec/requests]
    YAML
    commit("custom job")
    base = cmd("git", "rev-parse", "HEAD")
    change_fee("500", "700")
    report = cli("check", "--base", base, code: 1)
    request = report.fetch("jobs").fetch("requests")
    assert_equal ["./spec/requests/orders_spec.rb[1:2]"], request.fetch("executed_ids")
    assert_equal 2, request.fetch("full_count")
    refute request.fetch("inventory_drift")
  end

  def test_full_command_runs_on_stale_plan_and_missing_history
    write(".sukashi.yml", <<~YAML)
      jobs:
        custom:
          runner: command
          command: [ruby, -e, "puts 'full'"]
    YAML
    commit("full command")
    plan = cli("plan", "--base", "unknown-revision")
    assert_equal "full", plan.dig("jobs", "custom", "mode")
    plan["head"] = @base
    write("plan.json", plan.to_json)
    report = cli("run", "--plan", "plan.json")
    assert report.dig("jobs", "custom", "full_only_job")
    assert_match(/stale/, report.dig("jobs", "custom", "reason"))
  end

  def test_rename_mixed_with_a_new_test_keeps_the_new_test
    File.rename(File.join(@root, "test/fee_test.rb"), File.join(@root, "test/pricing_test.rb"))
    write("test/extra_test.rb", <<~RUBY)
      require "minitest/autorun"
      class SmokeTest < Minitest::Test
        def test_new; assert true; end
      end
    RUBY
    commit("move and add tests")
    report = cli("check", "--base", @base)
    assert report.fetch("ok")
    assert_equal 3, report.dig("jobs", "minitest", "full_count")
  end

  def test_predicate_change_runs_all_tests
    change_fee("if gift", "unless gift")
    report = cli("check", "--base", @base, code: 1)
    assert_equal [3, 2], report.fetch("jobs").values_at("rspec", "minitest").map { |j| j["full_count"] }
    assert report.fetch("jobs").values.all? { |job| job["mode"] == "full" }
  end
end
