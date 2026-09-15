# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class RpofSeamTest < Minitest::Test
  SCRIPT = File.expand_path("../bin/lme-rpof", __dir__)

  def setup
    @tmp = Dir.mktmpdir("lme-rpof-seam-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_explicit_executable_is_invoked_without_ruby_import
    fake = File.join(@tmp, "rpof")
    File.write(fake, <<~'SH')
      #!/bin/sh
      set -eu
      first=1
      for arg in "$@"; do
        if [ "$first" -eq 0 ]; then
          printf '|'
        fi
        printf '%s' "$arg"
        first=0
      done
      printf '\n'
    SH
    FileUtils.chmod(0o755, fake)

    stdout, stderr, status = Open3.capture3(
      { "RPOF_EXECUTABLE" => fake },
      RbConfig.ruby, SCRIPT, "capability-check", "--request", "request.json"
    )

    assert status.success?, stderr
    assert_equal "capability-check|--request|request.json\n", stdout
  end

  def test_missing_executable_fails_closed
    missing = File.join(@tmp, "missing-rpof")

    _stdout, stderr, status = Open3.capture3(
      { "RPOF_EXECUTABLE" => missing },
      RbConfig.ruby, SCRIPT, "version"
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "RPOF executable not found or not executable"
    assert_includes stderr, "RPOF_EXECUTABLE"
  end
end
