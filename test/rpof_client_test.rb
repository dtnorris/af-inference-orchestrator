# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/local_model_evaluation/rpof_client"

class RpofClientTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rpof-client-")
    @fake = File.join(@tmp, "rpof")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_capability_check_reads_versioned_result
    File.write(@fake, <<~'SH')
      #!/bin/sh
      set -eu
      output=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --output)
            output=$2
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      cat >"$output" <<'JSON'
      {"contract_version":"afio-rpof-capability-check-result/v0.1","ready":true,"fleet_key":"fixture","fleet_id":"fixture-fleet","selected_worker_indices":[1],"capabilities":null,"diagnostics":[]}
      JSON
    SH
    FileUtils.chmod(0o755, @fake)
    client = LocalModelEvaluation::RpofClient.new(repo_root: @tmp, executable: @fake)
    result = client.capability_check({ "fleet_key" => "fixture" })
    assert result.fetch("ready")
    assert_equal "fixture-fleet", result.fetch("fleet_id")
  end

  def test_dispatch_can_stream_subprocess_output_and_still_read_summary
    File.write(@fake, <<~'SH')
      #!/bin/sh
      set -eu
      output=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --output)
            output=$2
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      echo "[burst_1] fixture-job"
      mkdir -p "$output"
      cat >"$output/summary.json" <<'JSON'
      {"contract_version":"afio-rpof-dispatch-summary/v0.1","status":"completed"}
      JSON
    SH
    FileUtils.chmod(0o755, @fake)
    client = LocalModelEvaluation::RpofClient.new(repo_root: @tmp, executable: @fake)
    summary = nil
    exit_status = nil
    captured_stdout = nil
    captured_stderr = nil

    stdout, stderr = capture_subprocess_io do
      summary, exit_status, captured_stdout, captured_stderr = client.dispatch(
        request: { "target" => { "fleet_key" => "fixture" } },
        workdir: @tmp,
        output_dir: File.join(@tmp, "dispatch-output"),
        stream_output: true
      )
    end

    assert_includes stdout, "[burst_1] fixture-job"
    assert_empty stderr
    assert_equal "completed", summary.fetch("status")
    assert_equal 0, exit_status
    assert_equal "", captured_stdout
    assert_equal "", captured_stderr
  end

  def test_worker_selector_expands_ranges_without_sixteen_worker_ceiling
    assert_equal [1, 2, 3, 32], LocalModelEvaluation::RpofClient.expand_worker_selector("1-3,32")
  end
end
