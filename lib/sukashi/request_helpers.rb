module Sukashi
  module RequestHelpers
    # Route tracing assumes the framework's HTTP helper actually sends the
    # request. A project helper can perform other work before calling super.
    def self.overridden?(suite)
      @request_libraries ||= %w[actionpack rack-test capybara].filter_map do |name|
        spec = Gem.loaded_specs[name]
        spec.full_gem_path + File::SEPARATOR if spec
      end
      %i[get post put patch delete visit].any? do |name|
        next false unless suite.method_defined?(name) || suite.private_method_defined?(name)
        source = suite.instance_method(name).source_location&.first
        !source || !File.expand_path(source).start_with?(*@request_libraries)
      end
    end
  end
end
