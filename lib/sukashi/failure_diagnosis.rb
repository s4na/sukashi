module Sukashi
  # A retry is evidence, not proof of flakiness or of the selector's correctness.
  class FailureDiagnosis
    def initialize(runner)
      @runner = runner
    end

    def call(ids, enabled:)
      report = { "missed_failures" => [], "flaky_or_order_dependent" => [],
        "unclassified_full_only_failures" => ids, "retry_ids" => nil,
        "retry_seconds" => nil, "retry_ok" => nil }
      return report unless enabled && !ids.empty?

      result = @runner.invoke(ids: ids)
      report.merge!("retry_ids" => result.ids, "retry_seconds" => result.seconds, "retry_ok" => result.ok)
      # A missing/extra ID or absent report is not a successful retry.
      return report unless result.ids == ids

      failed = result.failures
      passed = result.rows.filter_map { |row| row["id"] if row["status"] == "passed" }.sort
      # A failing process with no failed examples is an infrastructure/hook error.
      passed = [] if !result.ok && failed.empty?
      report.merge(
        "missed_failures" => failed,
        "flaky_or_order_dependent" => passed,
        "unclassified_full_only_failures" => ids - failed - passed
      )
    end
  end
end
