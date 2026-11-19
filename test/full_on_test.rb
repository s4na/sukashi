require "minitest/autorun"
require "tempfile"
require_relative "../lib/sukashi/repository"
require_relative "../lib/sukashi/configuration"
require_relative "../lib/sukashi/planner"

class FullOnTest < Minitest::Test
  # Only the early path-policy decision is under test; source analysis must not
  # run when a shared/unclassified change or an ignored-only diff decides it.
  Repository = Struct.new(:pairs) do
    def clean?(_head) = true
    def changes(_base, _head) = pairs.map(&:dup)
    def ruby_sources(_revision) = { "lib/ordinary.rb" => "class Ordinary; end" }
  end

  def config(extra = {})
    Tempfile.create(["sukashi", ".yml"]) do |file|
      data = { "jobs" => { "suite" => { "runner" => "command", "command" => ["ruby", "-v"] } } }.merge(extra)
      file.write(YAML.dump(data))
      file.flush
      Sukashi::Configuration.new(file.path)
    end
  end

  def prepare(configuration, pairs, tests: [])
    planner = Sukashi::Planner.new(Repository.new(pairs), configuration, "head", "base", 1)
    planner.instance_variable_set(:@test_paths, tests.to_set)
    planner.send(:prepare)
  end

  def assert_full(configuration, path, old_path: path)
    assert_equal "shared or unclassified dependency: #{old_path || path}",
                 prepare(configuration, [[old_path, path]])
  end

  def test_defaults_preserve_shared_paths_even_with_broad_ignore
    configuration = config("ignore" => ["**/*"], "full_on" => [])
    %w[
      config/routes.rb db/schema.rb spec/support/setup.rb test/support/setup.rb
      app/views/page.erb app/assets/site.css app/javascript/main.js .github/ISSUE_TEMPLATE/bug.md
      Gemfile Gemfile.lock .rspec .sukashi.yml spec_helper.rb rails_helper.rb test_helper.rb sample.gemspec
      packages/sample/Gemfile packages/sample/Gemfile.lock packages/sample/sample.gemspec
      packages/sample/.rspec packages/sample/spec_helper.rb
    ].each { |path| assert_full(configuration, path) }
  end

  def test_additions_apply_to_ruby_and_take_precedence_over_ignore
    configuration = config("full_on" => ["lib/shared/**/*.rb", "templates/**/*", "lib/tasks/*.rake"],
                           "ignore" => ["**/*"])
    %w[lib/shared/policy.rb lib/shared/nested/policy.rb templates/.hidden/page.html lib/tasks/build.rake].each do |path|
      assert_full(configuration, path)
    end
    assert_full(configuration, "config/routes.rb")
  end

  def test_rename_and_delete_check_old_full_on_path
    configuration = config("full_on" => ["templates/**/*"], "ignore" => ["**/*"])
    assert_full(configuration, "docs/page.md", old_path: "templates/page.md")
    assert_equal "shared or unclassified dependency: templates/page.md",
                 prepare(configuration, [["templates/page.md", nil]])
  end

  def test_ignore_only_applies_to_non_ruby_non_test_non_shared_files
    configuration = config("ignore" => ["**/*"])
    assert_equal :skip, prepare(configuration, [["docs/note.md", "docs/note.md"]])
    assert_equal "shared or unclassified dependency: spec/example.feature",
                 prepare(configuration, [[nil, "spec/example.feature"]], tests: ["spec/example.feature"])
    assert_equal "no known test dependency: lib/ordinary.rb",
                 prepare(configuration, [["lib/ordinary.rb", "lib/ordinary.rb"]])
    planner = Sukashi::Planner.new(nil, configuration, nil, nil, 1)
    refute planner.send(:shared?, "lib/ordinary.rb")
    refute planner.send(:shared?, "packages/sample/config/settings.rb")
  end

  def test_non_ruby_changes_still_require_explicit_ignore
    assert_full(config, "templates/page.html")
  end

  def test_invalid_full_on_is_rejected
    [nil, "lib/**", {}, [123], [""]].each do |value|
      error = assert_raises(Sukashi::Error) { config("full_on" => value) }
      assert_equal "full_on must contain nonempty path patterns", error.message
    end
  end

  def test_effective_policy_is_fingerprinted
    original = config
    assert_equal original.fingerprint, config("full_on" => []).fingerprint
    refute_equal original.fingerprint, config("full_on" => ["lib/shared/**"]).fingerprint
    legacy = Digest::SHA256.hexdigest(JSON.generate([original.jobs, original.ignore]))
    refute_equal legacy, original.fingerprint
  end
end
