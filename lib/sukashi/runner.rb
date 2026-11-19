require "json"
require "tmpdir"
require "pathname"
require_relative "diagnostics"

module Sukashi
  Result = Struct.new(:ok, :rows, :seconds, :status, :runtime_identity, :exit_status, keyword_init: true) do
    def ids
      rows&.map { |r| r.fetch("id") }&.sort
    end

    def failures
      Array(rows).filter_map { |r| r["id"] if r["status"] == "failed" }.sort
    end
  end

  class Runner
    class InvalidReport < StandardError; end

    def initialize(job, seed)
      @job, @seed = job, seed
    end

    def invoke(discover: false, ids: nil, plain: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return Result.new(ok: false, status: "unavailable") if discover && @job["runner"] == "command"
      Dir.mktmpdir("sukashi-run") do |dir|
        command = @job.fetch("command").dup
        env = { "SEED" => @seed.to_s, "SUKASHI_SELECT" => nil,
                "SUKASHI_RUNTIME_DIR" => discover ? dir : nil }
        if ids
          selection_path = File.join(dir, "selection")
          File.write(selection_path, ids.to_json)
          env["SUKASHI_SELECT"] = selection_path
        end
        case plain ? "command" : @job.fetch("runner")
        when "rspec"
          env["SUKASHI_REPORT_DIR"] = dir
          command.concat(["--require", File.expand_path("rspec_report.rb", __dir__)])
          formatter = "Sukashi::RSpecReport"
          if discover
            command.concat(["--require", File.expand_path("runtime_identity.rb", __dir__),
                            "--require", File.expand_path("rspec_inventory.rb", __dir__)])
            formatter = "Sukashi::RSpecInventory"
          end
          command.concat(["--seed", @seed.to_s, "--format", formatter])
          discover ? command << "--dry-run" : command.concat(["--format", "progress"])
          command.concat(["--require", File.expand_path("rspec_selection.rb", __dir__)]) if ids
        when "minitest"
          adapter = File.expand_path("minitest_adapter", __dir__)
          env.merge!("RUBYLIB" => [adapter, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR),
                     "RUBYOPT" => [ENV["RUBYOPT"], "-rsukashi_minitest"].compact.join(" "),
                     "SUKASHI_REPORT_DIR" => dir, "SUKASHI_DISCOVER" => discover ? "1" : "0")
        end
        Diagnostics.command(command)
        ok = system(env, [command.first, command.first], *command.drop(1), out: :err)
        exit_status = $?.exitstatus
        rows = read_reports(dir) unless plain
        ok &&= !rows.any? { |row| row["status"] == "failed" } if rows && @job["runner"] == "rspec"
        Result.new(ok: !!ok, rows: rows, status: ok.nil? ? "failed_to_start" : (ok ? "passed" : "failed"),
                   runtime_identity: discover ? read_runtime_identity(dir) : nil, exit_status: exit_status,
                   seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
      end
    rescue InvalidReport => e
      warn e.message
      Result.new(ok: false, rows: [], status: "failed", seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
    rescue Errno::E2BIG, Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
      warn e.message
      Result.new(ok: false, status: "failed_to_start", seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
    end

    private

    def read_runtime_identity(dir)
      files = Dir[File.join(dir, "*.identity")]
      return if files.empty?
      identities = files.map { |file| JSON.parse(File.read(file)) }
      return unless identities.all? { |entry| entry.is_a?(Hash) }
      return identities.find { |entry| entry["status"] != "verified" } if identities.any? { |entry| entry["status"] != "verified" }
      fingerprints = identities.map { |entry| entry["fingerprint"] }
      return unless fingerprints.all? { |value| value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/) }
      { "status" => "verified", "fingerprints" => fingerprints.uniq.sort }
    rescue JSON::ParserError, TypeError, SystemCallError
      nil
    end

    def read_reports(dir)
      return read_rspec_reports(dir) if @job["runner"] == "rspec"
      files = Dir[File.join(dir, "*.json")]
      return if files.empty?
      rows = files.flat_map do |file|
        data = JSON.parse(File.read(file))
        data
      end
      return unless rows.all? { |r| r.is_a?(Hash) && r["id"].is_a?(String) } && rows.map { |r| r["id"] }.uniq.size == rows.size
      rows.each do |row|
        next unless row["file"]
        row["file"] = Pathname.new(File.expand_path(row["file"])).relative_path_from(Pathname.pwd).to_s
      end
      rows
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError
      nil
    end

    def read_rspec_reports(dir)
      files = Dir[File.join(dir, "rspec-*.json")].sort
      started = Dir[File.join(dir, "rspec-*.json.started")].map { |p| p.delete_suffix(".started") }.sort
      return if files.empty? && started.empty?
      raise InvalidReport, "RSpec worker report missing" unless files == started
      rows = files.flat_map do |file|
        data = JSON.parse(File.read(file))
        examples = data.fetch("examples")
        summary = data.fetch("summary")
        unless examples.is_a?(Array) && summary.fetch("example_count") == examples.size &&
               summary.fetch("errors_outside_of_examples_count") == 0
          raise InvalidReport, "RSpec worker report incomplete"
        end
        examples.map do |e|
          unless e.is_a?(Hash) && e["id"].is_a?(String) && e["file_path"].is_a?(String) &&
                 e["line_number"].is_a?(Integer) && %w[passed failed pending].include?(e["status"])
            raise InvalidReport, "RSpec worker example invalid"
          end
          { "id" => e["id"], "file" => Pathname.new(File.expand_path(e["file_path"])).relative_path_from(Pathname.pwd).to_s,
            "line" => e["line_number"], "status" => e["status"], "custom_protocol" => e["custom_protocol"] }
        end
      end
      raise InvalidReport, "RSpec worker report contains duplicate IDs" unless rows.map { |r| r["id"] }.uniq.size == rows.size
      rows
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError
      raise InvalidReport, "RSpec worker report malformed"
    end
  end
end
