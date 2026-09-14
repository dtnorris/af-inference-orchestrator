# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class RpofCommandBridgeTest < Minitest::Test
  SCRIPT = File.expand_path("../bin/lme", __dir__)
  COMMANDS = {
    "runpod-create" => "create",
    "runpod-destroy" => "destroy",
    "runpod-tunnels" => "tunnels",
    "runpod-status" => "status",
    "runpod-lease" => "lease",
    "runpod-scale" => "scale",
    "runpod-replace" => "replace",
    "runpod-bootstrap" => "bootstrap",
    "runpod-dispatch" => "dispatch-legacy"
  }.freeze
  HELPER_COMMANDS = {
    "lme-runpod-bootstrap" => ["bootstrap"],
    "lme-runpod-dispatch" => ["dispatch-legacy"],
    "lme-runpod-lease" => ["lease"],
    "lme-runpod-lifecycle" => ["scale", "scale"],
    "lme-runpod-status" => ["status"],
    "lme-runpod-tunnels" => ["tunnels"]
  }.freeze

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

  def test_supported_bin_lme_runpod_commands_delegate_with_opaque_arguments
    COMMANDS.each do |legacy, rpof|
      stdout, stderr, status = Open3.capture3(
        { "RPOF_EXECUTABLE" => @fake },
        RbConfig.ruby,
        SCRIPT,
        legacy,
        "--fleet",
        "fixture"
      )

      assert status.success?, "#{legacy}: #{stderr}"
      assert_equal "#{rpof}|--fleet|fixture\n", stdout, legacy
    end
  end

  def test_historical_helper_paths_are_thin_process_shims
    HELPER_COMMANDS.each do |name, argv|
      stdout, stderr, status = Open3.capture3(
        { "RPOF_EXECUTABLE" => @fake },
        RbConfig.ruby,
        File.expand_path("../bin/#{name}", __dir__),
        *argv.drop(1),
        "--fixture"
      )

      assert status.success?, "#{name}: #{stderr}"
      assert_equal "#{argv.first}|--fixture\n", stdout, name
    end
  end
end
