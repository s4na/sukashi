require "yaml"
require "digest"
require "json"
require "rbconfig"

module Sukashi
  class Configuration
    attr_reader :jobs, :ignore

    def initialize(path)
      raw = path && YAML.safe_load_file(path)
      raise Error, "configuration must contain jobs" if path && !raw.is_a?(Hash)
      @jobs = raw ? raw.fetch("jobs") : defaults
      @ignore = raw ? raw.fetch("ignore", []) : []
      raise Error, "ignore must contain path patterns" unless strings?(@ignore)
      raise Error, "configure at least one test job" unless jobs.is_a?(Hash) && !jobs.empty?
      jobs.each do |name, job|
        unless name.is_a?(String) && job.is_a?(Hash) && %w[rspec minitest command].include?(job["runner"]) &&
               strings?(job["command"]) && !job["command"].empty? && !job["command"].first.empty?
          raise Error, "invalid test job #{name.inspect}"
        end
      end
    end

    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate([jobs, ignore]))
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
