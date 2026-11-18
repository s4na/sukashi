module Sukashi
  module TestHelpers
    ASSERTIONS = %i[expect to not_to to_not eq eql be assert_equal assert_nil assert refute refute_equal].freeze
    FRAMEWORK_HELPERS = (ASSERTIONS + %i[get post put patch delete visit response]).freeze

    # Reachability traces the arguments of these framework methods. A project
    # override may execute a second branch before delegating to the framework.
    def self.overridden?(suite)
      @libraries ||= %w[actionpack rack-test capybara rspec-expectations rspec-rails minitest].filter_map do |name|
        spec = Gem.loaded_specs[name]
        spec.full_gem_path + File::SEPARATOR if spec
      end
      FRAMEWORK_HELPERS.any? do |name|
        next false unless suite.method_defined?(name) || suite.private_method_defined?(name)
        source = suite.instance_method(name).source_location&.first
        !source || !File.expand_path(source).start_with?(*@libraries)
      end
    end
  end
end
