require "rspec/core/formatters/json_formatter"

module Sukashi
  # Each RSpec process owns a report. Wrappers must forward the formatter
  # options/environment, wait for all workers and propagate their exit status.
  class RSpecReport < RSpec::Core::Formatters::JsonFormatter
    RSpec::Core::Formatters.register self, :dump_summary, :stop, :close

    def initialize(output)
      super
      @report_path = File.join(ENV.fetch("SUKASHI_REPORT_DIR"), "rspec-#{Process.pid}.json")
      File.write(@report_path + ".started", "")
    end

    def close(_notification)
      File.write(@report_path + ".tmp", JSON.generate(output_hash))
      File.rename(@report_path + ".tmp", @report_path)
    end
  end
end
