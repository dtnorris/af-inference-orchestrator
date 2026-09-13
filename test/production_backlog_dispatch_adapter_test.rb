# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class ProductionBacklogDispatchAdapterTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_dispatch_executable_unsets_inherited_token_override_and_preserves_argv
    Dir.mktmpdir("production-dispatch") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      script = File.join(root, "bin", "lme")
      File.write(script, <<~'SH')
        #!/bin/sh
        set -eu
        printf '%s\n' "${AF_LLM_MAX_TOKENS-unset}" > observed-env
        printf '%s\n' "$@" > observed-argv
      SH
      FileUtils.chmod(0o755, script)

      _out, err, status = Open3.capture3(
        {
          "LME_REPO" => root,
          "AF_LLM_MAX_TOKENS" => "99999"
        },
        RbConfig.ruby,
        "--disable-gems",
        File.join(ROOT, "bin", "production-backlog-dispatch"),
        "experiments/a manifest.yml",
        ""
      )

      assert status.success?, err
      assert_equal "unset\n", File.read(File.join(root, "observed-env"))
      assert_equal(
        ["run", "experiments/a manifest.yml"],
        File.readlines(File.join(root, "observed-argv"), chomp: true)
      )
    end
  end
end
