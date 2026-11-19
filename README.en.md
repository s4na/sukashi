# sukashi

[日本語](README.md)

Sukashi is a Ruby CLI that uses Prism to select RSpec examples and Minitest test methods affected by changed branches in a pull request. It compares the selected tests with a full run at the same commit and seed. It supports configured Ruby test jobs, including Rails request specs and system tests.

## Installation

Requires Ruby 3.2 or later. Add the Git repository to your project's Gemfile:

```ruby
gem "sukashi", github: "s4na/sukashi"
```

```sh
bundle install
bundle exec sukashi --version
```

The main-branch release workflow records a patch version and the tested source revision in `RELEASE` after tests pass. `--version` reports both. Patch numbers use the workflow run number and may have gaps. Your `Gemfile.lock` pins the Git revision; use `bundle update sukashi` to update it. These instructions do not require a RubyGems release.

## Compare selected tests with the full suite

Run from the repository root, with Git history and the same databases, browsers, and other prerequisites as your normal CI jobs:

```sh
bundle exec sukashi check --base origin/main --head HEAD --seed 1234 > comparison.json
```

`--base` accepts a ref or commit SHA. In pull-request CI, check out the actual PR head and fetch the base and merge-base history. With GitHub Actions, use `github.event.pull_request.head.sha` as the checkout ref, `fetch-depth: 0`, and `github.event.pull_request.base.sha` for `--base`.

To inspect selection reasons before execution, save a plan and run it from the same checkout:

```sh
bundle exec sukashi plan --base origin/main --seed 1234 > plan.json
bundle exec sukashi run --plan plan.json > comparison.json
```

- `subset` runs selected test IDs followed by the full suite.
- `full` runs the full suite. If an instrumented RSpec or Minitest command supplies no usable test report, Sukashi can also run the original command without instrumentation.
- `skip` means no selection is needed, for example when there is no diff or only explicitly ignored documentation changed. It still runs the full suite for comparison.

JSON goes to stdout; test logs go to stderr. `full_only_failures` lists IDs that failed only in the full run. `inventory_drift` reports mismatches between discovered, selected, and executed IDs. Test failures or comparison mismatches return exit code 1; configuration and pre-execution input errors return 2.

`file_level_count` lets you compare individual test selection with selecting entire test files. Timing is reported separately as `plan_seconds`, `selected_seconds`, and `full_seconds`.

## Configure existing test jobs

By default, Sukashi discovers RSpec in `spec/` and Minitest in `test/`. Rails uses `bin/rails test:all`, including system tests. Plain Ruby loads `test_*.rb` and `*_test.rb` under `test/`.

For custom paths, tags, or split jobs, list every full-suite job in `.sukashi.yml` (or use `--config FILE`). When a configuration file is present, only its listed jobs are covered:

```yaml
jobs:
  specs:
    runner: rspec
    command: [bundle, exec, rspec, spec, integration/spec]
  rails_tests:
    runner: minitest
    command: [bin/rails, "test:all"]
  legacy:
    runner: command
    command: [bundle, exec, rake, legacy_tests]
ignore: ["docs/**/*.md"]
```

Commands are argument arrays, not shell strings. RSpec commands must accept RSpec CLI options; Minitest commands must start Minitest. The `command` runner executes an existing full job and checks its exit status. Jobs without individual test IDs appear in `full_only_job`.

## Scope and limitations

The initial selector can distinguish changes to one arm of an `if ... else ... end` in a class method that directly tests a boolean parameter. Tests passing literal arguments, or literal-URL Rails routes through an action to such a method, may exclude tests that only reach the opposite arm. Controller response tracing is limited to simple `render plain:` calls.

Dynamic calls, shared setup, custom Rack middleware, implicit or template/layout rendering, and method replacement such as `prepend` limit what can be resolved. Condition changes, moves, and deletions widen selection to file dependencies in both revisions. Parse failures, unclassified changes, or missing comparison history fall back to full execution.

RSpec `let` and `before` keep their file and its consumers as candidates. Controller `before_action` affects routes through that controller and its subclasses. Hooks that cannot be scoped, such as shared `fixtures :all` or `config.before`, cause a full run.

Full-suite comparison can reveal a missed selection only when the full run reproduces the failure. Sukashi does not establish that an application is free of defects, and this comparison mode does not eliminate full-suite execution.

## Development and project information

Repository verification runs in GitHub Actions, as required by [AGENTS.md](AGENTS.md). Do not run repository tests, lint, builds, or CLI smoke checks locally.

- [Selection design (Japanese)](docs/test-selection.md)
- [Rails fixture and scenarios (Japanese)](fixtures/rails_app/README.md)
- [Changelog](CHANGELOG.md)
- [Issue tracker](https://github.com/s4na/sukashi/issues)
- [License and Crystalball attribution](README.md#参考元とライセンス)
