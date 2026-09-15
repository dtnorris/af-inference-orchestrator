# frozen_string_literal: true

require "minitest/autorun"

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
