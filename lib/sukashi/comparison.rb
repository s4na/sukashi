require_relative "planner"
require_relative "failure_diagnosis"
require_relative "repository"

module Sukashi
  class Comparison
    def initialize(repo, config, plan, retry_full_only: false, failure_policy: "strict")
      raise Error, "unknown failure policy: #{failure_policy}" unless %w[strict missed].include?(failure_policy)
      raise Error, "missed policy requires retry_full_only" if failure_policy == "missed" && !retry_full_only
      @repo, @config, @plan = repo, config, plan
      @retry_full_only, @failure_policy = retry_full_only, failure_policy
    end

    def run
      seed = @plan["seed"].is_a?(Integer) ? @plan["seed"] : 1
      valid = @plan["version"] == 1 && @plan["config"] == @config.fingerprint &&
        @plan["head"] && @repo.clean?(@plan["head"]) && @plan["jobs"].is_a?(Hash) &&
        @config.jobs.keys.sort == @plan["jobs"].keys.sort && @plan["jobs"].values.all? { |v| v.is_a?(Hash) }
      reports = @config.jobs.to_h do |name, job|
        decision = valid ? @plan["jobs"][name] : { "mode" => "full", "reason" => "stale or invalid plan", "reason_detail" => Reasons.build("invalid_plan") }
        runner = Runner.new(job, seed)
        if valid && decision["mode"] != "full"
          saved = @plan["runtime"].is_a?(Hash) ? @plan["runtime"][name] : nil
          current = runner.invoke(discover: true) if verified_runtime?(saved)
          unless current && current.ok && verified_runtime?(current.runtime_identity) && saved == current.runtime_identity &&
                 decision["inventory"].is_a?(Array) && current.ids == decision["inventory"]
            detail = Reasons.build("runtime_identity_changed")
            decision = { "mode" => "full", "reason" => detail.fetch("message"), "reason_detail" => detail }
          end
        end
        report = compare(runner, decision, job["runner"])
        report["rediscovery_seconds"] = current&.seconds
        [name, report]
      end
      { "version" => 1, "schema_minor" => 2, "failure_policy" => @failure_policy, "head" => @repo.revision("HEAD"), "seed" => seed, "plan_seconds" => @plan["plan_seconds"], "jobs" => reports, "ok" => reports.values.all? { |r| r["ok"] } }
    end

    private

    def verified_runtime?(identity)
      identity.is_a?(Hash) && identity["status"] == "verified" &&
        identity["fingerprints"].is_a?(Array) && !identity["fingerprints"].empty? &&
        identity["fingerprints"].all? { |value| value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/) }
    end

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
      diagnosis = FailureDiagnosis.new(runner).call(missing, enabled: @retry_full_only && kind != "command")
      strict_ok = full.ok && !drift && (!subset || sample.ok) && missing.empty?
      # Relax only a fully observed set of failures that all passed on retry.
      explained = full.exit_status == 1 && !missing.empty? && !opaque && full.failures == missing &&
        diagnosis["flaky_or_order_dependent"] == missing && diagnosis["retry_ok"]
      ok = strict_ok || (@failure_policy == "missed" && !drift && (!subset || sample.ok) && explained)
      {
        "mode" => subset ? "subset" : (decision["mode"] == "skip" ? "skip" : "full"),
        "reason" => decision["reason"],
        "reason_detail" => decision["reason_detail"] || Reasons.from_legacy(decision["reason"]),
        "selected_ids" => ids, "executed_ids" => sample&.ids,
        "file_level_count" => decision["file_level_count"], "full_count" => full.ids&.size, "full_failures" => full.failures,
        "selected_failures" => sample&.failures, "full_only_failures" => missing,
        "inventory_drift" => !!drift, "full_only_job" => opaque,
        "selected_seconds" => sample&.seconds, "full_seconds" => full.seconds,
        "selected_status" => sample&.status, "full_status" => full.status,
        "selected_only_failures" => sample ? sample.failures - full.failures : [],
        "ok" => !!ok
      }.merge(diagnosis)
    end
  end
end
