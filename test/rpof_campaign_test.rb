# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class RpofCampaignTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "lme-rpof-campaign")
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("rpof-campaign-")
    @fake = File.join(@tmp, "rpof")
    File.write(@fake, <<~'SH')
      #!/bin/sh
      set -eu
      command=$1
      shift
      request=""
      output=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --request)
            request=$2
            shift 2
            ;;
          --output)
            output=$2
            shift 2
            ;;
          --workdir)
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done

      cp "$request" "$CAPTURE_ROOT/$command.json"
      case "$command" in
        capability-check)
          cat >"$output" <<'JSON'
      {"contract_version":"afio-rpof-capability-check-result/v0.1","ready":true,"fleet_key":"fixture","fleet_id":"fixture-fleet","selected_worker_indices":[1,2],"capabilities":null,"diagnostics":[]}
      JSON
          ;;
        dispatch)
          mkdir -p "$output"
          cat >"$output/summary.json" <<'JSON'
      {"contract_version":"afio-rpof-dispatch-summary/v0.1","fleet_key":"fixture","fleet_id":"fixture-fleet","started_at_utc":"2026-09-14T12:00:00Z","finished_at_utc":"2026-09-14T12:00:01Z","status":"completed","worker_count":2,"job_count":1,"completed_count":1,"failed_count":0,"not_started_count":0,"not_started_job_ids":[],"infrastructure_failures":[],"jobs":[]}
      JSON
          ;;
        *)
          echo "unexpected command: $command" >&2
          exit 2
          ;;
      esac
    SH
    FileUtils.chmod(0o755, @fake)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_translates_generic_jobs_through_frozen_capability_and_dispatch_contracts
    jobs_path = File.join(@tmp, "jobs.json")
    output = File.join(@tmp, "evidence")
    capability_output = File.join(@tmp, "capability.json")
    File.write(jobs_path, JSON.dump(
      "jobs" => [{
        "job_id" => "fixture-job",
        "argv" => ["ruby", "-e", "puts :ok"],
        "env" => {},
        "affinity" => "fixture"
      }]
    ))

    stdout, stderr, status = Open3.capture3(
      {
        "RPOF_EXECUTABLE" => @fake,
        "CAPTURE_ROOT" => @tmp
      },
      RbConfig.ruby,
      SCRIPT,
      "--workers", "1-2",
      "--fleet", "fixture",
      "--model", "gpt-oss:20b",
      "--expect-digest", "gpt-oss:20b=#{DIGEST}",
      "--context", "32768",
      "--gpu", "fixture-gpu",
      "--jobs", jobs_path,
      "--workdir", @tmp,
      "--output", output,
      "--capability-output", capability_output,
      "--group-by-affinity"
    )

    assert status.success?, stdout + stderr
    capability = JSON.parse(File.read(File.join(@tmp, "capability-check.json")))
    assert_equal "afio-rpof-capability-check-request/v0.1", capability.fetch("contract_version")
    assert_equal "fixture", capability.fetch("fleet_key")
    assert_equal [1, 2], capability.dig("worker_selector", "indices")
    assert_equal DIGEST, capability.dig("requirements", "models", 0, "expected_digest")
    assert_equal "fixture-gpu", capability.dig("requirements", "required_gpu_id")

    dispatch = JSON.parse(File.read(File.join(@tmp, "dispatch.json")))
    assert_equal "afio-rpof-dispatch-request/v0.1", dispatch.fetch("contract_version")
    assert_equal "fixture-fleet", dispatch.dig("target", "expected_fleet_id")
    assert_equal true, dispatch.fetch("group_by_affinity")
    assert_equal "fixture-job", dispatch.dig("jobs", 0, "job_id")
    assert File.file?(capability_output)
  end
end
