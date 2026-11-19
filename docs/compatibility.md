# Compatibility checks

GitHub Actions runs the complete test suite, including the Rails fixture and the
RSpec/Minitest adapters, on Ruby 3.2, 3.3, 3.4 and 4.0.

| Ruby | Dependencies |
| --- | --- |
| 3.2, 3.3 | Prism 1.4.x, Minitest 5.x, RSpec 3.13.x, Rails 7.2 |
| 3.4 | Prism 2.x, Minitest 6.x, RSpec 3.13.x, current Rails |
| 4.0 | Repository Gemfile.lock |

The lower-bound profile deliberately pins IRB/RDoc to versions compatible with
Prism 1.4. The two compatibility Gemfiles are resolved independently of the
development lockfile. Each job prints the resolved versions so failures can be
reproduced in GitHub Actions. These profiles sample the advertised range, not
every possible combination. New dependency releases are tested when CI next runs.

All executable verification belongs in GitHub Actions, as described in AGENTS.md.
