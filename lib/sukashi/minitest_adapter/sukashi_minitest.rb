# Loaded by Minitest only in instrumented child processes.
require "json"
require "minitest"
require_relative "../test_helpers"

module SukashiMinitest
  def self.write(rows)
    path = File.join(ENV.fetch("SUKASHI_REPORT_DIR"), "#{Process.pid}.json")
    File.write(path + ".tmp", JSON.generate(rows))
    File.rename(path + ".tmp", path)
  end

  # Discover wrappers on the actual loaded class. Checking the Minitest
  # protocol also catches inherited/prepended overrides and custom assertions.
  def self.custom_protocol?(suite)
    return true unless suite <= Minitest::Test
    return true if Sukashi::TestHelpers.overridden?(suite)
    base = Minitest::Test
    @protocol ||= (base.instance_methods | base.private_instance_methods).to_h { |name| [name, base.instance_method(name)] }
    if @patched_base.nil?
      root = Dir.pwd + File::SEPARATOR
      bundled = Gem.loaded_specs.values.map(&:full_gem_path).select { |p| p.start_with?(root) }
      @patched_base = @protocol.values.any? do |method|
        source = method.source_location&.first
        next false unless source && File.file?(source)
        file = File.expand_path(source)
        file.start_with?(root) && bundled.none? { |p| file.start_with?(p + File::SEPARATOR) }
      end
    end
    @patched_base || @protocol.any? do |name, original|
      suite.instance_method(name).owner != original.owner
    rescue NameError
      true # the suite removed or undefined a method used by the runner
    end
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
      custom_protocol = !names.empty? && SukashiMinitest.custom_protocol?(suite)
      names.map do |name|
        file, line = suite.instance_method(name).source_location
        { "id" => "#{suite}##{name}", "file" => file, "line" => line, "custom_protocol" => custom_protocol }
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
