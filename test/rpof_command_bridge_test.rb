# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class RpofCommandBridgeTest < Minitest::Test
  SCRIPT = File.expand_path("../bin/lme", __dir__)

  def setup
    @tmp = Dir.mktmpdir("rpof-command-bridge-")
    @fake = File.join(@tmp, "rpof")
    File.write(@fake, <<~'RUBY')
      #!/usr/bin/env ruby
      puts ARGV.join("|")
    RUBY
    FileUtils.chmod(0o755, @fake)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_existing_runpod_status_command_delegates_to_rpof
    stdout, stderr, status = Open3.capture3(
      { "RPOF_EXECUTABLE" => @fake },
      RbConfig.ruby,
      SCRIPT,
      "runpod-status",
      "--fleet",
      "default"
    )

    assert status.success?, stderr
    assert_equal "status\n", stdout
  end
end
