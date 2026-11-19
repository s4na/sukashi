require "minitest/autorun"
require "open3"
require "rbconfig"

class PublicApiTest < Minitest::Test
  def test_public_entry_point_loads_without_running_a_command
    root = File.expand_path("..", __dir__)
    code = 'require "sukashi"; abort "missing CLI" unless Sukashi::CLI.respond_to?(:call)'
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", code, chdir: root)
    assert status.success?, err
    assert_empty out
    assert_empty err
  end
end
