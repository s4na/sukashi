Gem::Specification.new do |spec|
  spec.name = "sukashi"
  spec.version = "0.1.0"
  spec.summary = "Select RSpec and Minitest tests from a pull request and check them against the full suite"
  spec.authors = ["s4na"]
  spec.homepage = "https://github.com/s4na/sukashi"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["exe/*", "lib/**/*.rb", "docs/test-selection.md", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["sukashi"]
  spec.add_dependency "prism", ">= 1.4", "< 3"
end
