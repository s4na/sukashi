require "rspec/core/formatters/json_formatter"
require_relative "test_helpers"

module Sukashi
  class RSpecInventory < RSpec::Core::Formatters::JsonFormatter
    RSpec::Core::Formatters.register self, :dump_summary, :stop, :close

    private

    def format_example(example)
      @wrapped_groups ||= {}
      group = example.example_group
      unless @wrapped_groups.key?(group)
        @wrapped_groups[group] = TestHelpers.overridden?(group)
      end
      super.merge(custom_protocol: @wrapped_groups[group])
    end
  end
end
