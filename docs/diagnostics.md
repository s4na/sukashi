# CLI diagnostics

Exit codes: 0 means success, 1 means a failed comparison/job, 2 means invalid user input or a known operational error, and 3 means an unexpected internal exception.

`--verbose` (after the subcommand) or `SUKASHI_DEBUG=1` writes executed job/git commands and user-error backtraces to stderr. Internal exceptions always include a backtrace. JSON remains on stdout. Debug output can contain command arguments and local paths; redact it before sharing and do not put credentials in command arguments.

Git failures include git's stderr. Missing merge-base/history still falls back to full jobs, with a diagnostic on stderr.

Each comparison job adds `full_status` and `selected_status`: `passed`, `failed`, or `failed_to_start`. An unrun selected job has null status. The existing `ok` and failure arrays remain unchanged. A command that exits nonzero is `failed`; failure to launch the executable is `failed_to_start`. Instrumentation discovery may also use the internal status `unavailable`.
