require_relative "planner"

module Sukashi
  class Comparison
    def initialize(repo, config, plan)
      @repo, @config, @plan = repo, config, plan
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
      { "head" => @repo.revision("HEAD"), "seed" => seed, "plan_seconds" => @plan["plan_seconds"], "jobs" => reports, "ok" => reports.values.all? { |r| r["ok"] } }
    end

    private

    def compare(runner, decision, kind)
      inventory = decision["inventory"]
      selected = decision["selected"]
      subset = decision["mode"] == "subset" && inventory.is_a?(Array) && selected.is_a?(Hash) && !selected.empty? &&
        selected.keys.all?(String) && (selected.keys - inventory).empty?
      ids = selected.keys.sort if subset
      sample = runner.invoke(ids: ids) if subset

      # In shadow mode the original full job is authoritative even for a skip.
      # A full plan runs once; there is no second identical execution.
      full = runner.invoke(plain: kind == "command")
      opaque = full.rows.nil?
      if opaque && kind != "command"
        # Some wrappers do not accept instrumentation options (or run more than
        # one framework). Preserve the real job's verdict, including failures.
        original = runner.invoke(plain: true)
        full = original
      end
      missing = if subset
        full.failures - sample.failures
      elsif decision["mode"] == "skip"
        full.failures
      else
        []
      end
      drift = (subset && sample.ids != ids) || (inventory && !opaque && full.ids != inventory) || (subset && opaque)
      {
        "mode" => subset ? "subset" : (decision["mode"] == "skip" ? "skip" : "full"),
        "reason" => decision["reason"], "selected_ids" => ids, "executed_ids" => sample&.ids,
        "file_level_count" => decision["file_level_count"], "full_count" => full.ids&.size, "full_failures" => full.failures,
        "selected_failures" => sample&.failures, "full_only_failures" => missing,
        "inventory_drift" => !!drift, "full_only_job" => opaque,
        "selected_seconds" => sample&.seconds, "full_seconds" => full.seconds,
        "selected_status" => sample&.status, "full_status" => full.status,
        "ok" => full.ok && !drift && (!subset || sample.ok) && missing.empty?
      }
    end
  end
end
