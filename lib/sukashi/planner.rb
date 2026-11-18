require_relative "selection"
require_relative "runner"

module Sukashi
  class Planner
    def initialize(repo, config, head, base, seed)
      @repo, @config, @head, @base, @seed = repo, config, head, base, seed
    end

    def plan
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      jobs = @config.jobs.transform_values do |job|
        inventory = Runner.new(job, @seed).invoke(discover: true)
        inventory.ok ? inventory.rows : nil
      end
      @test_paths = jobs.values.compact.flatten.filter_map { |r| r["file"] }.to_set
      reason = prepare
      decisions = jobs.to_h do |name, rows|
        decision = if reason == :skip
          { "mode" => "skip", "reason" => "no executable changes" }
        elsif reason || !rows || rows.empty?
          { "mode" => "full", "reason" => reason || "job inventory unavailable or empty" }
        else
          select(rows)
        end
        [name, decision.merge("inventory" => rows&.map { |r| r["id"] }&.sort)]
      end
      { "version" => 1, "base" => @base, "head" => @head, "config" => @config.fingerprint,
        "seed" => @seed, "jobs" => decisions,
        "plan_seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    end

    private

    def prepare
      return "working tree differs from requested head" unless @repo.clean?(@head)
      return "merge base unavailable" unless @base
      changes = @repo.changes(@base, @head)
      changes.reject! do |pair|
        pair.compact.all? do |path|
          !shared?(path) && !path.end_with?(".rb") && !@test_paths.include?(path) && @config.ignore.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
        end
      end
      return :skip if changes.empty?
      paths = changes.flatten.compact
      shared = paths.find { |p| shared?(p) || !p.end_with?(".rb") }
      return "shared or unclassified dependency: #{shared}" if shared
      @old, @new = [@base, @head].map { |rev| SourceIndex.new(@repo.ruby_sources(rev)) }
      errors = @old.errors | @new.errors
      return "Prism parse failed: #{errors.join(', ')}" unless errors.empty?
      @only_local_specs = changes.all? do |left, right|
        next false unless left && left == right && @test_paths.include?(left)
        template = @old.local_spec_template(left)
        template && template == @new.local_spec_template(right)
      end
      @targets = {}
      @changed_tests = Set.new
      @moved = {}
      old_users, new_users = Set.new, Set.new
      shared_hooks = ((@old.hooks | @new.hooks) - @test_paths) | @old.unscoped_hooks | @new.unscoped_hooks
      changes.each do |old_path, new_path|
        @moved[new_path] = old_path if new_path && old_path != new_path
        @changed_tests << new_path if @test_paths.include?(new_path)
        if (old_path && !@old.sources.key?(old_path)) || (new_path && !@new.sources.key?(new_path))
          return "source unavailable: #{new_path || old_path}"
        end
        if [old_path, new_path].compact.any? { |p| shared_hooks.include?(p) }
          return "shared setup changed: #{new_path || old_path}"
        end
        diff = BranchDiff.between(@old, @new, new_path) if old_path && old_path == new_path
        unless diff
          left = old_path ? @old.dependents([old_path]) : Set.new
          right = new_path ? @new.dependents([new_path]) : Set.new
          return "no known test dependency: #{new_path || old_path}" if ((left | right) & @test_paths).empty?
          old_users.merge(left)
          new_users.merge(right)
          next
        end
        diff.each do |owner, singleton, name, arm|
          target = (@targets[[owner, singleton, name]] ||= { paths: [], arms: [] })
          target[:paths] |= [new_path]
          target[:arms] |= [arm]
        end
      end
      @local_users = old_users | new_users
      @analyses = [Reachability.new(@old, @targets, @test_paths, old_users),
                   Reachability.new(@new, @targets, @test_paths, new_users)]
      nil
    end

    def shared?(path)
      path.start_with?("config/", "db/", "spec/support/", "test/support/", "app/views/", "app/assets/", "app/javascript/", ".github/") ||
        %w[Gemfile Gemfile.lock .rspec .sukashi.yml spec_helper.rb rails_helper.rb test_helper.rb].include?(File.basename(path)) ||
        path.end_with?(".gemspec")
    end

    def select(rows)
      selected = {}
      locations = rows.map { |row| [row["file"], row["line"]] }.tally
      excluded = {}
      reached = Hash.new { |h, k| h[k] = Set.new }
      rows.each do |row|
        path, line = row.values_at("file", "line")
        if row["custom_protocol"]
          selected[row["id"]] = "test runner helper or execution protocol overridden"
          next
        end
        if @changed_tests.include?(path) || locations[[path, line]] > 1
          selected[row["id"]] = "changed test or shared definition"
          next
        end
        if @only_local_specs && path && !@local_users.include?(path)
          excluded[row["id"]] = "only local test bodies changed in other files"
          next
        end
        verdicts = [@analyses.first.inspect_test(@moved.fetch(path, path), line), @analyses.last.inspect_test(path, line)]
        @analyses.each do |analysis|
          analysis.evidence.each { |key, arm| reached[[key, arm]] << row["id"] }
        end
        if verdicts.include?(:affected)
          selected[row["id"]] = "reaches changed arm"
        elsif verdicts.include?(:file)
          selected[row["id"]] = "depends on changed file"
        elsif verdicts.include?(:unknown)
          selected[row["id"]] = "unresolved execution path"
        else
          excluded[row["id"]] = verdicts.include?(:other_arm) ? "only unchanged arm reachable" : "no dependency found"
        end
      end
      files = rows.filter_map { |r| r["file"] if selected.key?(r["id"]) }.to_set
      file_level_count = rows.count { |r| files.include?(r["file"]) }
      branches = @targets.flat_map do |key, info|
        info[:arms].map do |arm|
          { "path" => info[:paths].first, "method" => "#{key.first}.#{key.last}", "arm" => arm ? "then" : "else",
            "reachable_ids" => reached[[key, arm]].to_a.sort }
        end
      end
      if selected.empty? || selected.size == rows.size
        { "mode" => "full", "reason" => selected.empty? ? "no confirmed selection" : "all tests are candidates", "branches" => branches }
      else
        { "mode" => "subset", "selected" => selected.sort.to_h, "excluded" => excluded.sort.to_h,
          "file_level_count" => file_level_count, "branches" => branches }
      end
    end
  end
end
