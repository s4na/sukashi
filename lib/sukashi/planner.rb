require_relative "selection"
require_relative "runner"
require_relative "reasons"

module Sukashi
  class Planner
    def initialize(repo, config, head, base, seed)
      @repo, @config, @head, @base, @seed = repo, config, head, base, seed
    end

    def plan
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      runtimes = {}
      jobs = @config.jobs.to_h do |name, job|
        inventory = Runner.new(job, @seed).invoke(discover: true)
        runtimes[name] = inventory.ok ? inventory.runtime_identity : nil
        [name, inventory.ok ? inventory.rows : nil]
      end
      @test_paths = jobs.values.compact.flatten.filter_map { |r| r["file"] }.to_set
      reason = prepare
      decisions = jobs.to_h do |name, rows|
        decision = if runtimes.dig(name, "status") != "verified"
          decision_with_reason("full", Reasons.build("runtime_identity_unavailable"))
        elsif reason == :skip
          decision_with_reason("skip", Reasons.build("no_executable_changes"))
        elsif reason || !rows || rows.empty?
          decision_with_reason("full", reason || Reasons.build("inventory_unavailable"))
        else
          select(rows)
        end
        [name, decision.merge("inventory" => rows&.map { |r| r["id"] }&.sort)]
      end
      { "version" => 1, "schema_minor" => 1, "base" => @base, "head" => @head, "config" => @config.fingerprint,
        "seed" => @seed, "jobs" => decisions, "runtime" => runtimes,
        "plan_seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    end

    private

    def decision_with_reason(mode, detail)
      { "mode" => mode, "reason" => detail.fetch("message"), "reason_detail" => detail }
    end

    def record_reason(messages, details, id, code)
      details[id] = Reasons.build(code)
      messages[id] = details[id].fetch("message")
    end

    def prepare
      return Reasons.build("working_tree_changed") unless @repo.clean?(@head)
      return Reasons.build("merge_base_unavailable") unless @base
      changes = @repo.changes(@base, @head)
      changes.reject! do |pair|
        pair.compact.all? do |path|
          !shared?(path) && !path.end_with?(".rb") && !@test_paths.include?(path) && @config.ignore.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
        end
      end
      return :skip if changes.empty?
      paths = changes.flatten.compact
      shared = paths.find { |p| shared?(p) || !p.end_with?(".rb") }
      return Reasons.build("shared_dependency", path: shared) if shared
      @old, @new = [@base, @head].map { |rev| SourceIndex.new(@repo.ruby_sources(rev)) }
      errors = @old.errors | @new.errors
      return Reasons.build("parse_failed", paths: errors) unless errors.empty?
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
          return Reasons.build("source_unavailable", path: new_path || old_path)
        end
        if [old_path, new_path].compact.any? { |p| shared_hooks.include?(p) }
          return Reasons.build("shared_setup_changed", path: new_path || old_path)
        end
        diff = BranchDiff.between(@old, @new, new_path) if old_path && old_path == new_path
        unless diff
          left = old_path ? @old.dependents([old_path]) : Set.new
          right = new_path ? @new.dependents([new_path]) : Set.new
          return Reasons.build("no_test_dependency", path: new_path || old_path) if ((left | right) & @test_paths).empty?
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
      @config.full_on.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
      end
    end

    def select(rows)
      selected = {}
      selected_details = {}
      locations = rows.map { |row| [row["file"], row["line"]] }.tally
      excluded = {}
      excluded_details = {}
      reached = Hash.new { |h, k| h[k] = Set.new }
      rows.each do |row|
        path, line = row.values_at("file", "line")
        if row["custom_protocol"]
          record_reason(selected, selected_details, row["id"], "custom_test_protocol")
          next
        end
        if @changed_tests.include?(path) || locations[[path, line]] > 1
          record_reason(selected, selected_details, row["id"], "changed_test")
          next
        end
        if @only_local_specs && path && !@local_users.include?(path)
          record_reason(excluded, excluded_details, row["id"], "other_test_file")
          next
        end
        verdicts = [@analyses.first.inspect_test(@moved.fetch(path, path), line), @analyses.last.inspect_test(path, line)]
        @analyses.each do |analysis|
          analysis.evidence.each { |key, arm| reached[[key, arm]] << row["id"] }
        end
        if verdicts.include?(:affected)
          record_reason(selected, selected_details, row["id"], "changed_arm")
        elsif verdicts.include?(:file)
          record_reason(selected, selected_details, row["id"], "changed_file")
        elsif verdicts.include?(:unknown)
          record_reason(selected, selected_details, row["id"], "unresolved_path")
        else
          record_reason(excluded, excluded_details, row["id"], verdicts.include?(:other_arm) ? "unchanged_arm" : "no_dependency")
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
        decision_with_reason("full", Reasons.build(selected.empty? ? "no_selection" : "all_candidates")).merge("branches" => branches)
      else
        { "mode" => "subset", "selected" => selected.sort.to_h, "excluded" => excluded.sort.to_h,
          "selected_details" => selected_details.sort.to_h, "excluded_details" => excluded_details.sort.to_h,
          "file_level_count" => file_level_count, "branches" => branches }
      end
    end
  end
end
