require "yaml"
require "digest"
require "json"
require "rbconfig"

module Sukashi
  class Configuration
    DEFAULT_FULL_ON = %w[
      config/**/* db/**/* spec/support/**/* test/support/**/* app/views/**/*
      app/assets/**/* app/javascript/**/* .github/**/*
      **/Gemfile **/Gemfile.lock **/.rspec **/.sukashi.yml
      **/spec_helper.rb **/rails_helper.rb **/test_helper.rb **/*.gemspec
    ].freeze

    ASSUMPTIONS = %w[constant_reachability].freeze

    attr_reader :jobs, :ignore, :full_on, :assume

    def initialize(path)
      raw = begin
        path && YAML.safe_load_file(path)
      rescue Psych::Exception, SystemCallError => e
        raise Error, "cannot read configuration #{path}: #{e.message}"
      end
      raise Error, "configuration must contain jobs" if path && !raw.is_a?(Hash)
      @jobs = raw ? raw["jobs"] : defaults
      @ignore = raw ? raw.fetch("ignore", []) : []
      raise Error, "ignore must contain path patterns" unless strings?(@ignore)
      additions = raw ? raw.fetch("full_on", []) : []
      unless strings?(additions) && additions.none?(&:empty?)
        raise Error, "full_on must contain nonempty path patterns"
      end
      @full_on = (DEFAULT_FULL_ON + additions).uniq.freeze
      @assume = raw ? raw.fetch("assume", []) : []
      unless strings?(@assume) && (@assume - ASSUMPTIONS).empty?
        raise Error, "assume must list known assumptions: #{ASSUMPTIONS.join(', ')}"
      end
      @assume = @assume.uniq.sort.freeze
      raise Error, "configure at least one test job" unless jobs.is_a?(Hash) && !jobs.empty?
      jobs.each do |name, job|
        unless name.is_a?(String) && job.is_a?(Hash) && %w[rspec minitest command].include?(job["runner"]) &&
               strings?(job["command"]) && job["command"].none? { |arg| arg.include?("\0") } && !job["command"].empty? && !job["command"].first.empty?
          raise Error, "invalid test job #{name.inspect}"
        end
      end
    end

    def fingerprint
      # Plans made without assumptions keep their previous fingerprint.
      Digest::SHA256.hexdigest(JSON.generate([jobs, ignore, full_on, *([assume] unless assume.empty?)]))
    end

    private

    def strings?(values)
      values.is_a?(Array) && values.all? { |v| v.is_a?(String) }
    end

    def defaults
      jobs = {}
      jobs["rspec"] = { "runner" => "rspec", "command" => ["rspec"] } if Dir.exist?("spec")
      if File.exist?("bin/rails") && Dir.exist?("test")
        jobs["minitest"] = { "runner" => "minitest", "command" => ["bin/rails", "test:all"] }
      elsif Dir.exist?("test")
        loader = 'Dir["test/**/{test_*,*_test}.rb"].uniq.sort.each { |path| require File.expand_path(path) }'
        jobs["minitest"] = { "runner" => "minitest", "command" => [RbConfig.ruby, "-Itest", "-Ilib", "-e", loader] }
      end
      jobs
    end
  end
end
