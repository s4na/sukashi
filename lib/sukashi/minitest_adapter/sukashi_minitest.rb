# Loaded by Minitest only in instrumented child processes.
require "json"
require "minitest"

module SukashiMinitest
  def self.write(rows)
    path = File.join(ENV.fetch("SUKASHI_REPORT_DIR"), "#{Process.pid}.json")
    File.write(path + ".tmp", JSON.generate(rows))
    File.rename(path + ".tmp", path)
  end

  class Reporter < Minitest::AbstractReporter
    def initialize
      super
      @rows = []
    end

    def record(result)
      status = if result.skipped?
        "skipped"
      elsif result.passed?
        "passed"
      else
        "failed"
      end
      synchronize { @rows << { "id" => "#{result.klass}##{result.name}", "status" => status } }
    end

    def report
      SukashiMinitest.write(@rows)
    end
  end
end

def SukashiMinitest.install(options)
  return unless ENV["SUKASHI_REPORT_DIR"]
  if ENV["SUKASHI_DISCOVER"] == "1"
    rows = Minitest::Runnable.runnables.flat_map do |suite|
      if suite.respond_to?(:filter_runnable_methods)
        names = suite.filter_runnable_methods(options)
      else
        # Older Minitest versions expose only the unfiltered inventory. Jobs
        # with custom filters can still use their original full command.
        exit 2 if options[:exclude] || (options[:filter] && options[:filter] != "/./")
        names = suite.runnable_methods
      end
      names.map do |name|
        file, line = suite.instance_method(name).source_location
        { "id" => "#{suite}##{name}", "file" => file, "line" => line }
      end
    end
    SukashiMinitest.write(rows)
    Minitest::Runnable.runnables.each { |suite| suite.define_singleton_method(:runnable_methods) { [] } }
    options.delete(:include)
    return
  end
  if (file = ENV["SUKASHI_SELECT"])
    # The plan's IDs already include this job's discovery filters. Use the
    # native filter so inherited runnable_methods keeps its receiver.
    ids = JSON.parse(File.read(file))
    pattern = Regexp.union(ids)
    filter = /\A(?:#{pattern})\z/
    options[:include] = options[:filter] = filter
  end
  Minitest.reporter << SukashiMinitest::Reporter.new
end

# A configured job can use minitest/autorun, Rails, or a Rake wrapper.
# Attach after its own plugins have installed their reporters and filters.
module SukashiMinitestPlugins
  def init_plugins(options)
    super
    SukashiMinitest.install(options)
  end
end
Minitest.singleton_class.prepend(SukashiMinitestPlugins)
