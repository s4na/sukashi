require_relative "planner"

module Sukashi
  class Comparison
    def initialize(repo, config, plan, mode: "shadow")
      raise ArgumentError, "unknown execution mode: #{mode}" unless %w[shadow enforce].include?(mode)
      @repo, @config, @plan, @mode = repo, config, plan, mode
    end

    def run
      seed = @plan["seed"].is_a?(Integer) ? @plan["seed"] : 1
      valid = @plan["version"] == 1 && @plan["config"] == @config.fingerprint &&
        @plan["head"] && @repo.clean?(@plan["head"]) && @plan["jobs"].is_a?(Hash) &&
        @config.jobs.keys.sort == @plan["jobs"].keys.sort && @plan["jobs"].values.all? { |v| v.is_a?(Hash) }
      reports = @config.jobs.to_h do |name, job|
        decision = valid ? @plan["jobs"][name] : { "mode" => "full", "reason" => "stale or invalid plan" }
        [name, compare(Runner.new(job, seed), decision, job["runner"])]
      end
      { "execution_mode" => @mode, "head" => @repo.revision("HEAD"), "seed" => seed, "plan_seconds" => @plan["plan_seconds"], "jobs" => reports, "ok" => reports.values.all? { |r| r["ok"] } }
    end

    private

    def usable_inventory?(inventory)
      inventory.is_a?(Array) && !inventory.empty? && inventory.all?(String) && inventory.uniq.size == inventory.size
    end

    # No full comparison is implied by a successful enforce run.
    def enforce(runner, decision, kind, ids)
      inventory = decision["inventory"]
      instrument = kind != "command" && usable_inventory?(inventory)
      skip = decision["mode"] == "skip" && instrument
      result = runner.invoke(ids: ids, plain: !instrument) unless skip
      drift = if ids
        result.ids != ids
      elsif !skip && instrument
        result.ids != inventory
      end
      {
        "mode" => skip ? "skip" : (ids ? "subset" : "full"),
        "reason" => decision["reason"], "selected_ids" => ids,
        "executed_ids" => ids ? result.ids : nil,
        "file_level_count" => decision["file_level_count"],
        "full_count" => !skip && !ids ? result.ids&.size : nil,
        "full_failures" => !skip && !ids ? result.failures : nil,
        "selected_failures" => ids ? result.failures : nil,
        "full_only_failures" => nil, "inventory_drift" => !!drift,
        "full_only_job" => !skip && result.rows.nil?,
        "selected_seconds" => ids ? result.seconds : nil,
        "full_seconds" => !skip && !ids ? result.seconds : nil,
        "comparison_performed" => false,
        "ok" => skip || (result.ok && !drift)
      }
    end

    def compare(runner, decision, kind)
      inventory = decision["inventory"]
      selected = decision["selected"]
      subset = kind != "command" && decision["mode"] == "subset" && inventory.is_a?(Array) && selected.is_a?(Hash) && !selected.empty? &&
        selected.keys.all?(String) && (selected.keys - inventory).empty?
      subset &&= usable_inventory?(inventory) if @mode == "enforce"
      ids = selected.keys.sort if subset
      return enforce(runner, decision, kind, ids) if @mode == "enforce"
      sample = runner.invoke(ids: ids) if subset

      # In shadow mode the original full job is authoritative even for a skip.
      # A full plan runs once; there is no second identical execution.
      full = runner.invoke(plain: kind == "command")
      opaque = full.rows.nil?
      # Keep the existing runner compatibility path in default shadow mode.
      full = runner.invoke(plain: true) if opaque && kind != "command"
      missing = if subset
        full.failures - sample.failures
      elsif decision["mode"] == "skip"
        full.failures
      else
        []
      end
      drift = (subset && sample.ids != ids) || (inventory && !opaque && full.ids != inventory) || (subset && opaque)
      {
        "comparison_performed" => !opaque && (subset || decision["mode"] == "skip"),
        "mode" => subset ? "subset" : (decision["mode"] == "skip" ? "skip" : "full"),
        "reason" => decision["reason"], "selected_ids" => ids, "executed_ids" => sample&.ids,
        "file_level_count" => decision["file_level_count"], "full_count" => full.ids&.size, "full_failures" => full.failures,
        "selected_failures" => sample&.failures, "full_only_failures" => missing,
        "inventory_drift" => !!drift, "full_only_job" => opaque,
        "selected_seconds" => sample&.seconds, "full_seconds" => full.seconds,
        "ok" => full.ok && !drift && (!subset || sample.ok) && missing.empty?
      }
    end
  end
end
