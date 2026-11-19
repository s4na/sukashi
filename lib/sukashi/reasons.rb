module Sukashi
  module Reasons
    MESSAGES = {
      "working_tree_changed" => "working tree differs from requested head",
      "merge_base_unavailable" => "merge base unavailable",
      "no_executable_changes" => "no executable changes",
      "inventory_unavailable" => "job inventory unavailable or empty",
      "shared_dependency" => "shared or unclassified dependency",
      "parse_failed" => "Prism parse failed",
      "source_unavailable" => "source unavailable",
      "shared_setup_changed" => "shared setup changed",
      "no_test_dependency" => "no known test dependency",
      "custom_test_protocol" => "test runner helper or execution protocol overridden",
      "changed_test" => "changed test or shared definition",
      "other_test_file" => "only local test bodies changed in other files",
      "changed_arm" => "reaches changed arm",
      "changed_file" => "depends on changed file",
      "unresolved_path" => "unresolved execution path",
      "unchanged_arm" => "only unchanged arm reachable",
      "no_dependency" => "no dependency found",
      "unreachable_change" => "outside the constant reachability closure of the change",
      "no_selection" => "no confirmed selection",
      "all_candidates" => "all tests are candidates",
      "invalid_plan" => "stale or invalid plan",
      "runtime_identity_unavailable" => "runtime identity unavailable",
      "runtime_identity_changed" => "runtime identity changed or unavailable"
    }.freeze

    def self.build(code, path: nil, paths: nil)
      message = MESSAGES.fetch(code)
      message = "#{message}: #{path}" if path
      message = "#{message}: #{paths.join(', ')}" if paths
      { "code" => code, "message" => message }.tap do |detail|
        detail["path"] = path if path
        detail["paths"] = paths if paths
      end
    end

    # Old plans remain runnable; their prose is never parsed into a code.
    def self.from_legacy(message)
      { "code" => "legacy_reason", "message" => message } if message.is_a?(String)
    end
  end
end
