require "shellwords"

module Sukashi
  module Diagnostics
    def self.with_debug(enabled)
      previous = Thread.current[:sukashi_debug]
      Thread.current[:sukashi_debug] = enabled
      yield
    ensure
      Thread.current[:sukashi_debug] = previous
    end

    def self.debug?
      Thread.current[:sukashi_debug] || ENV["SUKASHI_DEBUG"] == "1"
    end

    def self.command(argv)
      warn "sukashi: #{Shellwords.join(argv)}" if debug?
    end
  end
end
