# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class MatcherBurstScriptTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(REPO_ROOT, "bin", "lme-matcher-burst")

  def test_script_has_valid_bash_syntax
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT)
    assert status.success?, stderr
  end

  def test_script_locks_the_eight_case_gptoss_pilot_and_teardown
    text = File.read(SCRIPT)
    remote_job = File.read(File.join(REPO_ROOT, "bin", "lme-matcher-remote-job"))

    assert_includes text, 'WORKERS=8'
    assert_includes text, 'CLOUD="SECURE"'
    assert_includes text, 'MODEL="gpt-oss:20b"'
    assert_includes text, 'CONTEXT=32768'
    assert_includes text, '"Q1:1"'
    assert_includes text, '"Q4:2"'
    assert_includes text, '"AF_MATCHER_TEMPERATURE" => ""'
    assert_includes text, '"AF_MATCHER_SEED" => ""'
    assert_includes remote_job, '"af-matcher"'
    assert_includes remote_job, '"run-case"'
    assert_includes text, 'runpod-bootstrap'
    assert_includes text, 'runpod-tunnels start --workers 1-8'
    assert_includes text, 'bin/lme-rpof-campaign'
    assert_includes text, '--expect-digest'
    assert_includes text, '--group-by-affinity'
    assert_includes text, 'runpod-destroy --workers 1-8 --yes'
    assert_includes text, 'WATCHDOG_MINUTES="${LME_MATCHER_BURST_WATCHDOG_MINUTES:-25}"'
    assert_includes text, 'afio_git_sha=$LME_SHA'
    refute_includes text, 'lme_git_sha=$LME_SHA'
    refute_includes text, 'fleet.env'
    refute_includes text, 'source "$FLEET_ENV"'
    refute_includes text, 'LME_BURST_${worker}_URL'
  end
end
