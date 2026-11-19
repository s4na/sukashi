require "optparse"
require_relative "version"
require_relative "diagnostics"
require_relative "repository"
require_relative "configuration"
require_relative "comparison"

module Sukashi
  module CLI
    def self.call(argv)
      # Inspect before parsing so malformed options can also be diagnosed.
      Diagnostics.with_debug(argv.include?("--verbose") || ENV["SUKASHI_DEBUG"] == "1") do
        execute(argv)
      end
    end

    def self.execute(argv)
      command = argv.shift
      if command == "--version" && argv.empty?
        puts "sukashi #{VERSION} (#{SOURCE_REVISION})"
        return 0
      end
      options = { head: "HEAD", seed: 1, config: File.file?(".sukashi.yml") ? ".sukashi.yml" : nil }
      parser = OptionParser.new do |o|
        o.banner = "Usage: sukashi plan --base REF [--head REF] | run --plan FILE | check --base REF | --version"
        o.on("--verbose", "Show commands and diagnostic backtraces on stderr") {}
        o.on("--base REF") { |v| options[:base] = v }
        o.on("--head REF") { |v| options[:head] = v }
        o.on("--seed N", Integer) { |v| options[:seed] = v }
        o.on("--config FILE") { |v| options[:config] = v }
        o.on("--plan FILE") { |v| options[:plan] = v }
      end
      if %w[--help -h].include?(command)
        puts parser
        return 0
      end
      parser.parse!(argv)
      raise Error, parser.to_s unless argv.empty? && %w[plan run check].include?(command)
      repo = Repository.new
      raise Error, "run from the repository root" unless repo.git("rev-parse", "--show-prefix").strip.empty?
      config = Configuration.new(options[:config])
      if command == "run"
        raise Error, "--plan is required" unless options[:plan]
        plan = begin
          parsed = JSON.parse(read_plan(options[:plan]))
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {} # unreadable plan contents cannot suppress a full job
        end
      else
        raise Error, "--base is required" unless options[:base]
        head = repo.revision(options[:head])
        plan = Planner.new(repo, config, head, repo.merge_base(options[:base], head), options[:seed]).plan
      end
      if command == "plan"
        puts JSON.pretty_generate(plan)
        return 0
      end
      report = Comparison.new(repo, config, plan).run
      puts JSON.pretty_generate(report)
      report["ok"] ? 0 : 1
    rescue Error, OptionParser::ParseError => e
      warn(Diagnostics.debug? ? e.full_message(highlight: false) : e.message)
      2
    rescue StandardError => e
      warn "sukashi internal error:"
      warn e.full_message(highlight: false)
      3
    end

    def self.read_plan(path)
      File.read(path)
    rescue SystemCallError => e
      raise Error, "cannot read plan #{path}: #{e.message}"
    end
  end
end
