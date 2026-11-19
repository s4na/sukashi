# Supported public entry point: Sukashi::CLI.call(argv).
# Other components are available for internal composition, not stable public APIs.
require_relative "sukashi/version"
require_relative "sukashi/repository"
require_relative "sukashi/configuration"
require_relative "sukashi/source_index"
require_relative "sukashi/test_helpers"
require_relative "sukashi/selection"
require_relative "sukashi/runner"
require_relative "sukashi/planner"
require_relative "sukashi/comparison"
require_relative "sukashi/cli"
