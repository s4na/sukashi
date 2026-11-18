# Run only in GitHub Actions. Never loads or executes the corpus application's code.
require "json"
require "open3"
require "fileutils"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)

def git(root, *args)
  out, err, status = Open3.capture3("git", *args, chdir: root)
  raise "git #{args.first} failed: #{err}" unless status.success?
  out.strip
end

abort "Run this benchmark only in GitHub Actions" unless ENV["GITHUB_ACTIONS"] == "true"

if ARGV.first == "--sample"
  require "stringio"
  require_relative "../lib/sukashi/cli"
  counts = []
  observer = Module.new do
    define_method(:initialize) do |sources|
      counts << sources.length
      super(sources)
    end
  end
  Sukashi::SourceIndex.prepend(observer)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  output = StringIO.new
  original_stdout = $stdout
  $stdout = output
  begin
    status = Sukashi::CLI.call(["plan", "--base", ARGV.fetch(1), "--config", ".sukashi-benchmark.yml"])
  ensure
    $stdout = original_stdout
  end
  raise "plan failed" unless status.zero?
  plan = JSON.parse(output.string)
  raise "both revisions were not indexed: #{counts.inspect}" unless counts.length == 2 && counts.min > 1_000
  rss_kib = File.read("/proc/self/status")[/^VmHWM:\s+(\d+)\s+kB$/, 1]
  raise "Linux peak RSS unavailable" unless rss_kib
  puts JSON.generate(
    wall_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
    plan_seconds: plan.fetch("plan_seconds"),
    peak_rss_kib: Integer(rss_kib),
    indexed_files: counts,
    decision: plan.fetch("jobs").fetch("probe").slice("mode", "reason"),
    ruby: RUBY_VERSION, prism: Prism::VERSION
  )
  exit
end

corpus = File.expand_path(ARGV.fetch(0))
output = File.expand_path(ARGV.fetch(1))
FileUtils.mkdir_p(output)
source_revision = git(corpus, "rev-parse", "HEAD")
raise "corpus must start clean" unless git(corpus, "status", "--porcelain").empty?
git(corpus, "config", "user.name", "github-actions[bot]")
git(corpus, "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
probe = File.join(corpus, "lib/sukashi_benchmark_probe.rb")
test = File.join(corpus, "sukashi_benchmark_probe_test.rb")
config = File.join(corpus, ".sukashi-benchmark.yml")
raise "benchmark paths already exist" if [probe, test, config].any? { |p| File.exist?(p) }
File.write(probe, "class SukashiBenchmarkProbe; def self.value(flag); if flag; 1; else; 2; end; end; end\n")
File.write(test, <<~RUBY)
  require "minitest/autorun"
  require_relative "lib/sukashi_benchmark_probe"
  class SukashiBenchmarkProbeTest < Minitest::Test
    def test_true; assert_equal 1, SukashiBenchmarkProbe.value(true); end
    def test_false; assert_equal 2, SukashiBenchmarkProbe.value(false); end
  end
RUBY
File.write(config, <<~YAML)
  jobs:
    probe:
      runner: minitest
      command: [ruby, sukashi_benchmark_probe_test.rb]
YAML
git(corpus, "add", "--", "lib/sukashi_benchmark_probe.rb", "sukashi_benchmark_probe_test.rb", ".sukashi-benchmark.yml")
git(corpus, "commit", "-qm", "Add synthetic benchmark inventory")
base = git(corpus, "rev-parse", "HEAD")
File.write(probe, File.read(probe).sub("if flag; 1;", "if flag; 3;"))
git(corpus, "add", "--", "lib/sukashi_benchmark_probe.rb")
git(corpus, "commit", "-qm", "Change synthetic benchmark branch")
samples = 3.times.map do
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, File.join(ROOT, "benchmark/large_repository.rb"), "--sample", base,
    chdir: corpus
  )
  raise "sample failed: #{stderr}" unless status.success?
  JSON.parse(stdout)
end
report = {
  corpus: "mastodon/mastodon", corpus_revision: source_revision,
  methodology: "real plan CLI; synthetic two-test inventory; application not booted; fresh Ruby process per sample; OS caches not cleared",
  samples: samples,
  median_wall_seconds: samples.map { |s| s.fetch("wall_seconds") }.sort[1],
  max_peak_rss_kib: samples.map { |s| s.fetch("peak_rss_kib") }.max
}
File.write(File.join(output, "results.json"), JSON.pretty_generate(report) + "\n")
summary = <<~MARKDOWN
  ## Large repository analysis benchmark
  - Corpus: mastodon/mastodon @ #{source_revision}
  - Ruby: #{samples.first.fetch("ruby")}; Prism: #{samples.first.fetch("prism")}
  - Indexed files (base/head): #{samples.first.fetch("indexed_files").join(" / ")}
  - Median wall time (3 fresh processes): #{report[:median_wall_seconds].round(3)} s
  - Maximum observed process peak RSS: #{report[:max_peak_rss_kib]} KiB
  - Synthetic two-test inventory, no application boot. This is not end-to-end Mastodon test-selection latency.
  - Raw samples and fallback reasons are in results.json. OS caches are not cleared.
MARKDOWN
File.write(File.join(output, "summary.md"), summary)
File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") { |f| f.write(summary) }
