# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class RpofCommandBridgeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "lme")
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
    "lme-runpod-bootstrap" => "bootstrap",
    "lme-runpod-dispatch" => "dispatch-legacy",
    "lme-runpod-lease" => "lease",
    "lme-runpod-status" => "status",
    "lme-runpod-tunnels" => "tunnels"
  }.freeze

  def test_bin_lme_runpod_command_mapping_is_exact
    source = File.read(SCRIPT)

    COMMANDS.each do |legacy, rpof|
      assert_includes source, %("#{legacy}" => "#{rpof}"), legacy
    end

    assert_includes source, <<~RUBY.chomp
      if (rpof_command = rpof_compat[command])
        exec(
          RbConfig.ruby,
          File.join(ROOT, "bin", "lme-rpof"),
          rpof_command,
          *ARGV
        )
      end
    RUBY
  end

  def test_representative_bin_lme_runpod_command_delegates_with_opaque_arguments
    Dir.mktmpdir("rpof-command-bridge-") do |tmp|
      fake = File.join(tmp, "rpof")
      File.write(fake, <<~'RUBY')
        #!/usr/bin/env ruby
        puts ARGV.join("|")
      RUBY
      FileUtils.chmod(0o755, fake)

      stdout, stderr, status = Open3.capture3(
        { "RPOF_EXECUTABLE" => fake },
        RbConfig.ruby,
        SCRIPT,
        "runpod-dispatch",
        "--fleet",
        "fixture",
        "--opaque",
        "value with spaces"
      )

      assert status.success?, stderr
      assert_equal "dispatch-legacy|--fleet|fixture|--opaque|value with spaces\n", stdout
    end
  end

  def test_historical_helper_paths_keep_exact_rpof_command_contracts
    HELPER_COMMANDS.each do |name, rpof|
      source = File.read(File.join(ROOT, "bin", name))
      expected = %(exec RbConfig.ruby, File.join(root, "bin", "lme-rpof"), "#{rpof}", *ARGV)
      assert_includes source, expected, name
    end

    lifecycle = File.read(File.join(ROOT, "bin", "lme-runpod-lifecycle"))
    assert_includes lifecycle, "command = ARGV.shift"
    assert_includes lifecycle, "%w[scale replace].include?(command)"
    assert_includes lifecycle, 'exec RbConfig.ruby, File.join(root, "bin", "lme-rpof"), command, *ARGV'
  end
end
