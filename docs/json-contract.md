# JSON contract (plan 1.3, report 1.2)

The checked-in schemas use JSON Schema Draft 2020-12. `version` is the major version; `schema_minor` is additive evolution within that major. Missing `schema_minor` in an existing version-1 plan means 1.0. The runner continues to accept these old plans. Old reports without `version` predate the published report contract.

Readers must ignore unknown fields and handle unknown reason codes conservatively. Adding keys/codes increments the minor version; removing keys, changing types or changing existing semantics requires a new major version and schema file. Schemas intentionally allow additional properties.

## Fields

Plans contain committed `base` (nullable when unavailable), `head`, configuration fingerprint `config`, random `seed`, discovery/planning elapsed `plan_seconds`, a job-name keyed `jobs` map, and a job-name keyed `runtime` map. Since plan minor 2, a plan whose configuration lists `assume` entries has an `assumptions` map keyed by assumption name; each entry has boolean `applied` and, when not applied, a human `reason` (consumers must not parse it). A runtime entry is null when discovery failed; otherwise it has a `status`, and a `verified` entry lists SHA-256 `fingerprints` of the observed Ruby/Bundler environment. Saved subset/skip decisions are reused only when the current run reports the same verified identity.

Plan 1.3 records an optional per-job `inventory_digest` over the sorted test IDs, source files, lines and custom-protocol flags. Reuse of subset/skip requires the same digest at discovery. Older plans without this evidence fall back to full execution.

Each job has `mode` (full/subset/skip) and `inventory` (IDs or null). Full/skip decisions carry the original human `reason` and additive `reason_detail`. Subsets retain the original ID-to-message `selected`/`excluded` maps and add ID-to-detail `selected_details`/`excluded_details`, `file_level_count` and branch evidence. A branch contains path, method, then/else arm and reachable IDs.

Reports contain the current head, seed, `failure_policy` (`strict` or `missed`), original plan duration, per-job results and aggregate `ok`. Each result preserves mode/reason, selected/executed IDs, file/full counts, selected/full/full-only failure IDs, inventory drift, opaque-job flag, timings and `ok`. `selected_status` / `full_status` are `passed`, `failed`, `failed_to_start` or `unavailable` (null when not run). `selected_only_failures` lists IDs that failed only in the selected run. Retry diagnosis adds `missed_failures`, `flaky_or_order_dependent`, `unclassified_full_only_failures`, `retry_ids`, `retry_seconds` and `retry_ok`; the retry fields are null when no retry ran. Null IDs/counts/times mean unavailable or not run, never an empty successful run. Job `reason_detail` is null when no overall fallback reason exists. An older plan's prose is preserved as `legacy_reason`; it is not parsed or reclassified.

Since report 1.2, each job includes `rediscovery_seconds`, the elapsed time of the inventory check before running a saved decision. It includes an attempted discovery that causes a fallback to full execution. The value is null when discovery was not attempted. `plan_seconds` measures the original planning pass once across jobs.

A reason detail contains `code`, a human `message`, and optional `path` or `paths`. Consumers must not parse `message`. Paths are repository-relative. The parse_failed detail lists each source path that could not be parsed.

## Codes

| Code | Meaning |
| --- | --- |
| `working_tree_changed` | working tree differs from requested head |
| `merge_base_unavailable` | merge base unavailable |
| `no_executable_changes` | no executable changes |
| `inventory_unavailable` | job inventory unavailable or empty |
| `shared_dependency` | shared or unclassified dependency |
| `parse_failed` | Prism parse failed |
| `source_unavailable` | source unavailable |
| `shared_setup_changed` | shared setup changed |
| `no_test_dependency` | no known test dependency |
| `custom_test_protocol` | test runner helper or execution protocol overridden |
| `changed_test` | changed test or shared definition |
| `other_test_file` | only local test bodies changed in other files |
| `changed_arm` | reaches changed arm |
| `changed_file` | depends on changed file |
| `unresolved_path` | unresolved execution path |
| `unchanged_arm` | only unchanged arm reachable |
| `no_dependency` | no dependency found |
| `unreachable_change` | outside the constant reachability closure of the change (opt-in `assume: [constant_reachability]`) |
| `no_selection` | no confirmed selection |
| `all_candidates` | all tests are candidates |
| `invalid_plan` | stale or invalid plan |
| `runtime_identity_unavailable` | runtime identity unavailable while planning |
| `runtime_identity_changed` | runtime identity changed or unavailable when reusing a saved plan |
| `legacy_reason` | A legacy plan supplies prose without a machine code. |

## Verification

Tests validate real planner and comparison outputs against these schemas with the standard Python `jsonschema` validator in GitHub Actions. Fixtures cover full/subset/skip, unavailable inventory/history, shared dependencies, parse errors, old plans, and opaque jobs. Negative cases reject invalid modes, wrong version and malformed IDs.
