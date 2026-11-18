require_relative "lib/sukashi/version"

Gem::Specification.new do |spec|
  spec.name = "sukashi"
  spec.version = Sukashi::VERSION
  spec.summary = "Select RSpec and Minitest tests from a pull request and check them against the full suite"
  spec.authors = ["s4na"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/s4na/sukashi"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/#{Sukashi::SOURCE_REVISION}"
  spec.metadata["source_revision"] = Sukashi::SOURCE_REVISION
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["exe/*", "lib/**/*.rb", "docs/*.md", "README.md", "LICENSE", "RELEASE"]
  spec.bindir = "exe"
  spec.executables = ["sukashi"]
  spec.add_dependency "prism", ">= 1.4", "< 3"
end
