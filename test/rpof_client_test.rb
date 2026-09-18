# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/local_model_evaluation/rpof_client"

class RpofClientTest < Minitest::Test
  CLIENT = LocalModelEvaluation::RpofClient

  def setup
    @tmp = Dir.mktmpdir("rpof-client-")
    @fake = File.join(@tmp, "rpof")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_command_builders_preserve_rpof_cli_contracts_without_spawning
    assert_equal(
      ["/fixture/rpof", "capability-check", "--request", "request.json", "--output", "result.json"],
      CLIENT.capability_command(
        executable: "/fixture/rpof",
        request_path: "request.json",
        output_path: "result.json"
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "execution-pool-fulfill",
        "--request", "request.json", "--output", "result.json", "--dry-run", "--yes"
      ],
      CLIENT.fulfillment_command(
        executable: "/fixture/rpof",
        request_path: "request.json",
        output_path: "result.json",
        dry_run: true,
        assume_yes: true
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "dispatch", "--request", "request.json",
        "--workdir", File.expand_path("work"), "--output", File.expand_path("evidence")
      ],
      CLIENT.dispatch_command(
        executable: "/fixture/rpof",
        request_path: "request.json",
        workdir: "work",
        output_dir: "evidence"
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "dispatch", "--request", "request.json",
        "--workdir", File.expand_path("work"), "--output", File.expand_path("evidence"),
        "--dynamic-worker-admission"
      ],
      CLIENT.dispatch_command(
        executable: "/fixture/rpof",
        request_path: "request.json",
        workdir: "work",
        output_dir: "evidence",
        dynamic_worker_admission: true
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "dispatch-admit", "--fleet", "qwen",
        "--output", File.expand_path("evidence"), "--worker", "3"
      ],
      CLIENT.dispatch_admit_command(
        executable: "/fixture/rpof", fleet_key: "qwen", output_dir: "evidence", worker_index: 3
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "scale", "--fleet", "qwen", "--workers", "2",
        "--max-hourly-usd", "4.0", "--max-total-hourly-usd", "7.0", "--yes"
      ],
      CLIENT.scale_command(
        executable: "/fixture/rpof",
        fleet_key: "qwen",
        worker_count: 2,
        max_hourly_usd: 4,
        max_total_hourly_usd: 7
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "dispatch-close", "--fleet", "qwen",
        "--output", File.expand_path("evidence")
      ],
      CLIENT.dispatch_close_command(
        executable: "/fixture/rpof", fleet_key: "qwen", output_dir: "evidence"
      )
    )
    assert_equal(
      [
        "/fixture/rpof", "shutdown", "--fleet", "qwen", "--workers", "1,3", "--terminal",
        "--inactive-minutes", "5.0", "--drain-timeout-minutes", "10.0",
        "--reason", "afio_campaign_completed"
      ],
      CLIENT.terminal_shutdown_command(
        executable: "/fixture/rpof",
        fleet_key: "qwen",
        worker_indices: [3, 1, 3],
        inactivity_minutes: 5,
        drain_timeout_minutes: 10,
        reason: "afio_campaign_completed"
      )
    )
  end

  def test_result_contract_validation_is_exact_without_spawning
    cases = {
      CLIENT::CAPABILITY_RESULT_CONTRACT => "RPOF capability result",
      CLIENT::EXECUTION_POOL_RESULT_CONTRACT => "RPOF execution-pool result",
      CLIENT::DISPATCH_SUMMARY_CONTRACT => "RPOF dispatch summary"
    }

    cases.each do |contract, label|
      document = { "contract_version" => contract, "status" => "fixture" }
      assert_same document, CLIENT.validate_result_contract!(document, expected: contract, label:)

      error = assert_raises(CLIENT::Error) do
        CLIENT.validate_result_contract!(
          { "contract_version" => "wrong/v0" },
          expected: contract,
          label:
        )
      end
      assert_equal %(unsupported #{label} version: "wrong/v0"), error.message
    end
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
    client = CLIENT.new(repo_root: @tmp, executable: @fake)
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

  def test_worker_normalization_and_selector_expansion_are_pure
    assert_equal [1, 3], CLIENT.normalize_worker_indices([3, "1", 3])
    assert_equal [1, 2, 3, 32], CLIENT.expand_worker_selector("1-3,32")
  end
end
