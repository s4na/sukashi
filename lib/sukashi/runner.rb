require "json"
require "tmpdir"
require "pathname"

module Sukashi
  Result = Struct.new(:ok, :rows, :seconds, :exit_status, keyword_init: true) do
    def ids
      rows&.map { |r| r.fetch("id") }&.sort
    end

    def failures
      Array(rows).filter_map { |r| r["id"] if r["status"] == "failed" }.sort
    end
  end

  class Runner
    def initialize(job, seed)
      @job, @seed = job, seed
    end

    def invoke(discover: false, ids: nil, plain: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return Result.new(ok: false) if discover && @job["runner"] == "command"
      Dir.mktmpdir("sukashi-run") do |dir|
        command = @job.fetch("command").dup
        env = { "SEED" => @seed.to_s, "SUKASHI_SELECT" => nil }
        if ids
          selection_path = File.join(dir, "selection")
          File.write(selection_path, ids.to_json)
          env["SUKASHI_SELECT"] = selection_path
        end
        case plain ? "command" : @job.fetch("runner")
        when "rspec"
          formatter = "json"
          if discover
            command.concat(["--require", File.expand_path("rspec_inventory.rb", __dir__)])
            formatter = "Sukashi::RSpecInventory"
          end
          command.concat(["--seed", @seed.to_s, "--format", formatter, "--out", File.join(dir, "rspec.json")])
          discover ? command << "--dry-run" : command.concat(["--format", "progress"])
          command.concat(["--require", File.expand_path("rspec_selection.rb", __dir__)]) if ids
        when "minitest"
          adapter = File.expand_path("minitest_adapter", __dir__)
          env.merge!("RUBYLIB" => [adapter, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR),
                     "RUBYOPT" => [ENV["RUBYOPT"], "-rsukashi_minitest"].compact.join(" "),
                     "SUKASHI_REPORT_DIR" => dir, "SUKASHI_DISCOVER" => discover ? "1" : "0")
        end
        ok = system(env, [command.first, command.first], *command.drop(1), out: :err)
        exit_status = $?.exitstatus
        rows = read_reports(dir) unless plain
        Result.new(ok: !!ok, rows: rows, exit_status: exit_status, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
      end
    rescue Errno::E2BIG, Errno::ENOENT => e
      warn e.message
      Result.new(ok: false)
    end

    private

    def read_reports(dir)
      files = Dir[File.join(dir, "*.json")]
      return if files.empty?
      rows = files.flat_map do |file|
        data = JSON.parse(File.read(file))
        if @job["runner"] == "rspec"
          return if data.fetch("summary").fetch("errors_outside_of_examples_count", 0).positive?
          data.fetch("examples").map do |e|
            { "id" => e.fetch("id"), "file" => e.fetch("file_path"), "line" => e.fetch("line_number"),
              "status" => e.fetch("status"), "custom_protocol" => e["custom_protocol"] }
          end
        else
          data
        end
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
  end
end
