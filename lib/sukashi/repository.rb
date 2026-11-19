require "open3"
require_relative "diagnostics"

module Sukashi
  class Error < StandardError; end

  class Repository
    def git(*args)
      raise Error, "git arguments must not contain NUL bytes" if args.any? { |arg| arg.include?("\0") }
      Diagnostics.command(["git", *args])
      output, stderr, status = Open3.capture3("git", *args)
      raise Error, "git #{args.first} failed (exit #{status.exitstatus}): #{stderr.strip}" unless status.success?
      output
    rescue SystemCallError => e
      raise Error, "cannot start git: #{e.message}"
    end

    def revision(ref)
      git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
    end

    def merge_base(base, head)
      git("merge-base", revision(base), head).strip
    rescue Error => e
      warn "sukashi: #{e.message}; falling back to full jobs"
      nil
    end

    def clean?(head)
      revision("HEAD") == head && git("diff", "--name-only", head, "--").empty? &&
        git("ls-files", "--others", "--exclude-standard", "-z").split("\0").none? { |p| p.end_with?(".rb") }
    end

    def changes(base, head)
      entries = git("diff", "--name-status", "-z", "-M", base, head, "--").split("\0").each
      changes = []
      loop do
        status = entries.next
        path = entries.next
        case status[0]
        when "R", "C" then changes << [path, entries.next]
        when "A" then changes << [nil, path]
        when "D" then changes << [path, nil]
        else changes << [path, path]
        end
      end
      changes
    end

    # Use the committed blobs on both sides (including deleted files) without checking out B.
    def ruby_sources(commit)
      paths = git("ls-tree", "-rz", commit).split("\0").filter_map do |entry|
        info, path = entry.split("\t", 2)
        mode, type, oid = info.split
        [path, oid] if path.end_with?(".rb", ".ru") && type == "blob" && mode.start_with?("100")
      end
      Diagnostics.command(["git", "cat-file", "--batch"])
      IO.popen(["git", "cat-file", "--batch"], "r+b") do |io|
        paths.to_h do |path, oid|
          io.puts(oid)
          io.flush
          header = io.gets
          raise Error, "missing blob for #{path}" unless header&.start_with?("#{oid} blob ")
          source = io.read(Integer(header.split.last))
          io.read(1)
          [path, source]
        end
      end
    end
  end
end
