require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Exercise the installed command boundary, real Rails routing, RSpec and Minitest.
class SelectionTest < Minitest::Test
  CLI = File.expand_path("../exe/sukashi", __dir__)
  DUMMY_APP = File.expand_path("../fixtures/rails_app", __dir__)

  REGULAR_REQUEST = "./spec/requests/orders_spec.rb[1:1]"
  GIFT_REQUEST = "./spec/requests/orders_spec.rb[1:2]"
  RECEIPT_REQUEST = "./spec/requests/receipt_spec.rb[1:1]"
  GIFT_SYSTEM = "./spec/system/order_spec.rb[1:1]"
  GIFT_UNIT = "GiftTest#test_fee"
  REGULAR_UNIT = "RegularTest#test_fee"
  RACK_REQUEST = "RegularOrderTest#test_regular_response"
  RECEIPT_SYSTEM = "ReceiptTest#test_receipt_flow"

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
    (Dir.children(DUMMY_APP) - %w[log tmp]).each { |entry| FileUtils.cp_r(File.join(DUMMY_APP, entry), @root) }
    cmd("git", "init", "-q")
    cmd("git", "config", "user.name", "Test")
    cmd("git", "config", "user.email", "test@example.invalid")
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

  def replace(path, from, to)
    text = File.read(File.join(@root, path))
    assert_includes text, from, "mutation missing in #{path}"
    write(path, text.sub(from, to))
  end

  def change_fee(from, to)
    replace("app/models/order_fee.rb", from, to)
    commit("fee change")
  end

  def assert_subset(job, selected:, failures:)
    assert_equal "subset", job.fetch("mode")
    assert_equal selected.sort, job.fetch("selected_ids")
    assert_equal selected.sort, job.fetch("executed_ids")
    assert_equal failures.sort, job.fetch("selected_failures")
    assert_equal failures.sort, job.fetch("full_failures")
    assert_empty job.fetch("full_only_failures")
    refute job.fetch("inventory_drift")
    assert_equal 4, job.fetch("full_count")
  end

  def test_unmodified_app_passes_all_eight_tests
    report = cli("check", "--base", @base)
    assert_equal %w[minitest rspec], report.fetch("jobs").keys.sort
    report.fetch("jobs").each_value do |job|
      assert_equal "skip", job.fetch("mode")
      assert_equal 4, job.fetch("full_count")
      assert_empty job.fetch("full_failures")
    end
  end

  def test_branch_selection_and_comparison
    change_fee("500", "700")
    plan = cli("plan", "--base", @base)
    write("plan.json", plan.to_json)
    report = cli("run", "--plan", "plan.json", code: 1)
    gift_specs = [GIFT_REQUEST, RECEIPT_REQUEST, GIFT_SYSTEM]
    assert_subset(report.dig("jobs", "rspec"), selected: gift_specs, failures: gift_specs)
    assert_subset(report.dig("jobs", "minitest"), selected: [GIFT_UNIT, RACK_REQUEST, RECEIPT_SYSTEM],
                  failures: [GIFT_UNIT, RECEIPT_SYSTEM])

    plan.fetch("jobs").fetch("rspec").fetch("selected").delete(GIFT_SYSTEM)
    plan.fetch("jobs").fetch("minitest").fetch("selected").delete(RECEIPT_SYSTEM)
    write("plan.json", plan.to_json)
    missed = cli("run", "--plan", "plan.json", code: 1)
    assert_equal [GIFT_SYSTEM], missed.dig("jobs", "rspec", "full_only_failures")
    assert_equal [RECEIPT_SYSTEM], missed.dig("jobs", "minitest", "full_only_failures")
  end

  def test_else_arm_changes_the_regular_fee
    change_fee("100", "200")
    report = cli("check", "--base", @base, code: 1)
    assert_subset(report.dig("jobs", "rspec"), selected: [REGULAR_REQUEST, RECEIPT_REQUEST, GIFT_SYSTEM],
                  failures: [REGULAR_REQUEST])
    regular_tests = [REGULAR_UNIT, RACK_REQUEST, RECEIPT_SYSTEM]
    assert_subset(report.dig("jobs", "minitest"), selected: regular_tests, failures: regular_tests)
  end

  def test_request_parameter_keeps_both_possible_paths
    replace("config/routes.rb", "routes.draw do", "routes.draw do\n  post '/quote', to: 'orders#quote'")
    replace("app/controllers/orders_controller.rb", "class OrdersController < ActionController::Base", <<~'RUBY'.rstrip)
      class OrdersController < ActionController::Base
        def quote
          render plain: OrderFee.fee(params[:gift] == "yes")
        end
    RUBY
    path = "spec/requests/quote_spec.rb"
    write(path, <<~RUBY)
      require_relative "../rails_helper"
      RSpec.describe "quotes", type: :request do
        it "quotes a gift" do
          post "/quote", params: { gift: "yes" }
          expect(response.body).to eq("500")
        end
        it "quotes a regular order" do
          post "/quote", params: { gift: "no" }
          expect(response.body).to eq("100")
        end
      end
    RUBY
    commit("add parameter-dependent route")
    base = cmd("git", "rev-parse", "HEAD")
    assert cli("check", "--base", base).fetch("ok")
    change_fee("500", "700")
    specs = cli("check", "--base", base, code: 1).dig("jobs", "rspec")
    gift_quote = "./#{path}[1:1]"
    regular_quote = "./#{path}[1:2]"
    assert_equal [gift_quote, regular_quote, GIFT_REQUEST, GIFT_SYSTEM, RECEIPT_REQUEST].sort, specs.fetch("executed_ids")
    failures = [gift_quote, GIFT_REQUEST, GIFT_SYSTEM, RECEIPT_REQUEST].sort
    assert_equal failures, specs.fetch("selected_failures")
    assert_equal failures, specs.fetch("full_failures")
    assert_empty specs.fetch("full_only_failures")
  end

  def test_partial_change_reaches_request_and_browser
    replace("app/views/orders/_gift_fee.html.erb", "Gift fee:", "Fee:")
    commit("change receipt text")
    report = cli("check", "--base", @base, code: 1)
    assert_equal [RECEIPT_REQUEST], report.dig("jobs", "rspec", "full_failures")
    assert_equal [RECEIPT_SYSTEM], report.dig("jobs", "minitest", "full_failures")
    assert report.fetch("jobs").values.all? { |job| job["mode"] == "full" && job["full_count"] == 4 }
  end

  # The regular action itself only calls fee(false). Both overlays cause a
  # real second call to fee(true) before that action gets to answer.
  def assert_gift_change_reaches_regular_request
    commit("install request hook")
    base = cmd("git", "rev-parse", "HEAD")
    assert cli("check", "--base", base).fetch("ok")
    change_fee("500", "700")
    report = cli("check", "--base", base, code: 1)
    specs = report.dig("jobs", "rspec")
    assert_equal "full", specs.fetch("mode")
    assert_equal [REGULAR_REQUEST, GIFT_REQUEST, RECEIPT_REQUEST, GIFT_SYSTEM].sort, specs.fetch("full_failures")
    tests = [GIFT_UNIT, RACK_REQUEST, RECEIPT_SYSTEM]
    assert_subset(report.dig("jobs", "minitest"), selected: tests, failures: tests)
  end

  def test_callback_invokes_the_other_arm
    replace("app/controllers/orders_controller.rb", "class OrdersController < ActionController::Base", <<~'RUBY'.rstrip)
      class OrdersController < ActionController::Base
        before_action :check_gift_fee, only: :regular

        def check_gift_fee
          head :conflict if OrderFee.fee(true) != 500
        end
    RUBY
    assert_gift_change_reaches_regular_request
  end

  def test_middleware_invokes_the_other_arm
    write("config/initializers/fee_middleware.rb", <<~RUBY)
      class FeeMiddleware
        def initialize(app)
          @app = app
        end

        def call(env)
          if env["PATH_INFO"] == "/regular" && OrderFee.fee(true) != 500
            return [409, { "content-type" => "text/plain" }, ["Fee mismatch"]]
          end
          @app.call(env)
        end
      end
      Rails.application.config.middleware.use FeeMiddleware
    RUBY
    assert_gift_change_reaches_regular_request
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
    assert_equal [GIFT_REQUEST, RECEIPT_REQUEST], request.fetch("executed_ids")
    assert_equal 3, request.fetch("full_count")
    refute request.fetch("inventory_drift")
  end

  def test_plain_minitest_job_passes_on_equivalent_literal_edit
    write(".sukashi.yml", <<~YAML)
      jobs:
        unit:
          runner: minitest
          command: [ruby, test/fee_test.rb]
    YAML
    commit("unit-only job")
    base = cmd("git", "rev-parse", "HEAD")
    change_fee("500", "5_00")
    report = cli("check", "--base", base)
    job = report.fetch("jobs").fetch("unit")
    assert_equal [GIFT_UNIT], job.fetch("executed_ids")
    assert_equal 2, job.fetch("full_count")
    assert_empty job.fetch("full_failures")
    refute job.fetch("inventory_drift")
  end

  def test_route_edit_takes_precedence_over_a_narrow_branch_edit
    replace("config/routes.rb", '"/regular", to: "orders#regular"', '"/regular", to: "orders#gift"')
    change_fee("500", "700")
    report = cli("check", "--base", @base, code: 1)
    report.fetch("jobs").each_value do |job|
      assert_equal "full", job.fetch("mode")
      assert_equal 4, job.fetch("full_count")
      assert_includes job.fetch("reason"), "config/routes.rb"
    end
    assert_includes report.dig("jobs", "rspec", "full_failures"), REGULAR_REQUEST
    assert_includes report.dig("jobs", "minitest", "full_failures"), RACK_REQUEST
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
    assert_equal 5, report.dig("jobs", "minitest", "full_count")
  end

  def test_edit_to_group_local_let_selects_only_that_spec_file
    path = "spec/requests/orders_spec.rb"
    spec = File.read(File.join(@root, path))
    spec = spec.sub('  it("regular")', '  let(:amount) { 100 }' + "\n" + '  it("regular")')
    write(path, spec)
    commit("add local let")
    base = cmd("git", "rev-parse", "HEAD")
    write(path, spec.sub("let(:amount) { 100 }", "let(:amount) { 101 }"))
    commit("edit local let")
    decision = cli("plan", "--base", base).dig("jobs", "rspec")
    assert_equal ["./spec/requests/orders_spec.rb[1:1]", "./spec/requests/orders_spec.rb[1:2]"], decision.fetch("selected").keys
  end

  def test_inherited_minitest_run_override_keeps_the_wrapped_test
    write("test/wrapped_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../app/models/order_fee"
      class WrapperTest < Minitest::Test
        def run
          OrderFee.fee(true)
          super
        end
      end
      class WrappedTest < WrapperTest
        def test_regular
          assert_equal 100, OrderFee.fee(false)
        end
      end
    RUBY
    commit("add wrapped suite")
    base = cmd("git", "rev-parse", "HEAD")
    change_fee("500", "700")
    decision = cli("plan", "--base", base).dig("jobs", "minitest")
    assert_equal [GIFT_UNIT, RECEIPT_SYSTEM, RACK_REQUEST, "WrappedTest#test_regular"].sort, decision.fetch("selected").keys
  end

  def test_inherited_http_helper_can_reach_the_other_arm
    write("test/wrapped_request_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../config/environment"
      require "rack/test"
      class RequestBase < Minitest::Test
        include Rack::Test::Methods
        def app
          Rails.application
        end
        def get(path)
          assert_equal 500, OrderFee.fee(true)
          super
        end
      end
      class WrappedRequestTest < RequestBase
        def test_regular_order
          get "/regular"
        end
      end
    RUBY
    path = "spec/rails_helper.rb"
    File.open(File.join(@root, path), "a") do |helper|
      helper.puts <<~RUBY
        module BillingRequests
          def get(path, **options)
            expect(OrderFee.fee(true)).to eq(500)
            super
          end
        end
        RSpec.configure { |config| config.include BillingRequests, type: :request }
      RUBY
    end
    commit("wrap HTTP helper")
    base = cmd("git", "rev-parse", "HEAD")
    assert cli("check", "--base", base).fetch("ok")
    change_fee("500", "700")
    report = cli("check", "--base", base, code: 1)
    specs = report.dig("jobs", "rspec")
    assert_equal "full", specs.fetch("mode")
    assert_includes specs.fetch("full_failures"), REGULAR_REQUEST
    job = report.dig("jobs", "minitest")
    id = "WrappedRequestTest#test_regular_order"
    assert_includes job.fetch("executed_ids"), id
    assert_includes job.fetch("selected_failures"), id
    assert_includes job.fetch("full_failures"), id
    assert_empty job.fetch("full_only_failures")
  end

  def test_included_matcher_can_reach_the_other_arm
    File.open(File.join(@root, "spec/rails_helper.rb"), "a") do |helper|
      helper.puts <<~RUBY
        module BillingMatchers
          def eq(value)
            raise "unexpected gift charge" unless OrderFee.fee(true) == 500
            super
          end
        end
        RSpec.configure { |config| config.include BillingMatchers, type: :request }
      RUBY
    end
    commit("wrap eq matcher")
    base = cmd("git", "rev-parse", "HEAD")
    assert cli("check", "--base", base).fetch("ok")
    change_fee("500", "700")
    job = cli("check", "--base", base, code: 1).dig("jobs", "rspec")
    assert_includes job.fetch("full_failures"), REGULAR_REQUEST
    assert_empty job.fetch("full_only_failures")
  end

  def test_predicate_change_runs_all_tests
    change_fee("if gift", "unless gift")
    report = cli("check", "--base", @base, code: 1)
    assert_equal [REGULAR_REQUEST, GIFT_REQUEST, RECEIPT_REQUEST, GIFT_SYSTEM].sort, report.dig("jobs", "rspec", "full_failures")
    assert_equal [GIFT_UNIT, REGULAR_UNIT, RACK_REQUEST, RECEIPT_SYSTEM].sort, report.dig("jobs", "minitest", "full_failures")
    assert report.fetch("jobs").values.all? { |job| job["mode"] == "full" }
  end
end
