require "digest"
require "json"
require "rbconfig"

module Sukashi
  # Only a digest and fixed reason codes leave the child process.
  module RuntimeIdentity
    def self.capture
      return opaque("bundler_unavailable") unless defined?(Bundler) && Bundler.respond_to?(:load)
      gemfile = Bundler.default_gemfile
      lockfile = Bundler.default_lockfile
      return opaque("lockfile_unavailable") unless File.file?(gemfile) && File.file?(lockfile)

      own_root = File.realpath(File.join(__dir__, "../.."))
      specs = Bundler.load.specs.map do |spec|
        source = spec.source
        if source.is_a?(Bundler::Source::Path)
          # A mutable path/git dependency is not identified by its version.
          # The running selector itself is the only exception: hash its code.
          unless spec.name == "sukashi" && File.realpath(spec.full_gem_path) == own_root
            return opaque("mutable_dependency")
          end
        elsif source.is_a?(Bundler::Source::Metadata) && spec.name == "bundler" && spec.version.to_s == Bundler::VERSION
          # Bundler describes itself as runtime metadata, not a registry gem.
          # Other unknown or mutable sources must still remain opaque.
        elsif !source.is_a?(Bundler::Source::Rubygems)
          return opaque("dependency_source_unverified")
        end
        [spec.name, spec.version.to_s, spec.platform.to_s]
      end.sort
      code_paths = Dir[File.join(own_root, "{lib/**/*.rb,exe/*,*.gemspec,RELEASE}")].select { |path| File.file?(path) }
      code = code_paths.sort.map do |path|
        [path.delete_prefix(own_root + "/"), Digest::SHA256.file(path).hexdigest]
      end
      environment = ENV.select do |key, _|
        key.start_with?("BUNDLE_") || %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH PATH].include?(key)
      end.sort
      payload = [
        RUBY_DESCRIPTION, RUBY_ENGINE, RUBY_PLATFORM, Bundler::VERSION, Gem::VERSION, File.realpath(RbConfig.ruby),
        File.realpath(gemfile), Digest::SHA256.file(gemfile).hexdigest,
        File.realpath(lockfile), Digest::SHA256.file(lockfile).hexdigest,
        specs, code, environment
      ]
      { "status" => "verified", "fingerprint" => Digest::SHA256.hexdigest(JSON.generate(payload)) }
    rescue StandardError
      opaque("runtime_identity_unavailable")
    end

    def self.opaque(reason)
      { "status" => "opaque", "reason" => reason }
    end
  end
end

if (directory = ENV["SUKASHI_RUNTIME_DIR"])
  at_exit do
    begin
      path = File.join(directory, "#{Process.pid}.identity")
      File.write(path, JSON.generate(Sukashi::RuntimeIdentity.capture))
    rescue StandardError
      # Missing evidence makes the parent choose full; do not mask test status.
    end
  end
end
