# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "yaml"
require "digest"

class ProductionBurstTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("production-burst-")
    copy("bin/lme-production-burst")
    copy("lib/production_backlog_runner_policy.rb")
    copy("lib/production_backlog_runtime_contract.rb")
    executable("bin/verify-production-backlog", "#!/bin/sh\nexit 0\n")
    executable("bin/preflight-production-backlog-sources", "#!/bin/sh\nexit 0\n")
    fake_fulfill
    fake_campaign
    build_fixture
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_independent_lane_failure_does_not_block_other_ready_campaigns
    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp, "FIXTURE_FAIL_POOL" => "gemma4" },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-burst"),
      "output/plan.json",
      "--output", "output/burst",
      "--yes"
    )

    refute status.success?, out + err
    ledger = JSON.parse(File.read(File.join(@tmp, "output", "burst", "production-burst.json")))
    assert_equal "completed", ledger.dig("pools", "qwen35", "status")
    assert_equal "fulfillment_failed", ledger.dig("pools", "gemma4", "status")
    assert_equal "completed", ledger.dig("pools", "gpt-oss", "status")
    launches = File.readlines(File.join(@tmp, "campaign-launches.txt"), chomp: true)
    assert_includes launches, "qwen35"
    refute_includes launches, "gemma4"
    assert_includes launches, "gpt-oss"
  end

  def test_resume_skips_completed_and_sticky_workload_failed_lanes
    burst_root = File.join(@tmp, "output", "burst")
    FileUtils.mkdir_p(File.join(burst_root, "pools", "qwen35", "campaign"))
    File.write(
      File.join(burst_root, "pools", "qwen35", "campaign", "summary.json"),
      JSON.dump("status" => "completed")
    )
    FileUtils.mkdir_p(File.join(burst_root, "pools", "gemma4", "campaign"))
    File.write(
      File.join(burst_root, "pools", "gemma4", "campaign", "summary.json"),
      JSON.dump("status" => "workload_failed")
    )

    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-burst"),
      "output/plan.json",
      "--output", "output/burst",
      "--yes"
    )

    assert_equal 2, status.exitstatus, out + err
    fulfilled = File.readlines(File.join(@tmp, "fulfill-calls.txt"), chomp: true)
    refute_includes fulfilled, "qwen35"
    refute_includes fulfilled, "gemma4"
    assert_includes fulfilled, "gpt-oss"
    ledger = JSON.parse(File.read(File.join(burst_root, "production-burst.json")))
    assert_equal "completed", ledger.dig("pools", "qwen35", "status")
    assert_equal "workload_failed", ledger.dig("pools", "gemma4", "status")
    assert_equal "completed", ledger.dig("pools", "gpt-oss", "status")
  end

  def test_dry_run_fulfills_all_pools_but_launches_no_campaigns
    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-burst"),
      "output/plan.json",
      "--output", "output/burst-dry",
      "--dry-run"
    )

    assert status.success?, out + err
    assert_includes out, "qwen35: model_ref=qwen runtime=qwen3.6:35b-a3b digest=#{DIGEST}"
    assert_includes out, "gemma4: model_ref=gemma runtime=gemma4:26b digest=#{DIGEST}"
    assert_includes out, "gpt-oss: model_ref=gptoss runtime=gpt-oss:20b digest=#{DIGEST}"
    fulfilled = File.readlines(File.join(@tmp, "fulfill-calls.txt"), chomp: true)
    assert_equal %w[qwen35 gemma4 gpt-oss], fulfilled
    refute File.exist?(File.join(@tmp, "campaign-launches.txt"))
    ledger = JSON.parse(File.read(File.join(@tmp, "output", "burst-dry", "production-burst.json")))
    assert_equal "planned", ledger.fetch("status")
  end

  private

  def copy(path)
    target = File.join(@tmp, path)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(ROOT, path), target)
    FileUtils.chmod(0o755, target) if path.start_with?("bin/")
  end

  def executable(path, content)
    target = File.join(@tmp, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
    FileUtils.chmod(0o755, target)
  end

  def fake_fulfill
    executable("bin/lme-production-pool-fulfill", <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?}
      plan_arg=$1
      shift
      case "$plan_arg" in
        /*) plan_path=$plan_arg ;;
        *) plan_path="$root/$plan_arg" ;;
      esac

      pool=
      output_arg=
      dry=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --pool)
            pool=$2
            shift 2
            ;;
          --output)
            output_arg=$2
            shift 2
            ;;
          --dry-run)
            dry=true
            shift
            ;;
          *)
            shift
            ;;
        esac
      done
      case "$output_arg" in
        /*) output=$output_arg ;;
        *) output="$root/$output_arg" ;;
      esac

      printf '%s\n' "$pool" >> "$root/fulfill-calls.txt"
      if command -v sha256sum >/dev/null 2>&1; then
        plan_sha=$(sha256sum "$plan_path")
      else
        plan_sha=$(shasum -a 256 "$plan_path")
      fi
      plan_sha=${plan_sha%% *}

      fail_pool=${FIXTURE_FAIL_POOL:-}
      if [ "$dry" = true ]; then
        ready=false
        status=planned
        worker_indices='[]'
        detail=planned
        exit_status=0
      elif [ "$pool" = "$fail_pool" ]; then
        ready=false
        status=unfulfilled
        worker_indices='[]'
        detail='fixture unavailable'
        exit_status=1
      else
        ready=true
        status=ready
        worker_indices='[1]'
        detail=ready
        exit_status=0
      fi

      output_dir=${output%/*}
      [ "$output_dir" = "$output" ] && output_dir=.
      mkdir -p "$output_dir"
      printf '%s\n' \
        '{' \
        '  "contract_version": "afio-production-execution-pool-handoff/v0.1",' \
        "  \"plan\": { \"path\": \"$plan_path\", \"sha256\": \"$plan_sha\" }," \
        "  \"pool_id\": \"$pool\"," \
        '  "request": {},' \
        '  "result": {' \
        '    "contract_version": "afio-rpof-execution-pool-fulfill-result/v0.1",' \
        "    \"ready\": $ready," \
        "    \"status\": \"$status\"," \
        "    \"plan_sha256\": \"$plan_sha\"," \
        "    \"pool_id\": \"$pool\"," \
        "    \"execution_handle\": \"ep-$pool\"," \
        "    \"worker_indices\": $worker_indices," \
        "    \"detail\": \"$detail\"" \
        '  }' \
        '}' > "$output"
      exit "$exit_status"
    SH
  end

  def fake_campaign
    executable("bin/lme-rpof-campaign", <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?}
      fleet=
      output=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --fleet)
            fleet=$2
            shift 2
            ;;
          --output)
            output=$2
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done

      pool=${fleet#ep-}
      printf '%s\n' "$pool" >> "$root/campaign-launches.txt"
      mkdir -p "$output"
      if [ "${FIXTURE_WORKLOAD_FAIL_POOL:-}" = "$pool" ]; then
        status=workload_failed
        completed_count=0
        failed_count=1
        exit_status=2
      else
        status=completed
        completed_count=1
        failed_count=0
        exit_status=0
      fi

      printf '%s\n' \
        '{' \
        '  "contract_version": "afio-rpof-dispatch-summary/v0.1",' \
        "  \"status\": \"$status\"," \
        '  "job_count": 1,' \
        "  \"completed_count\": $completed_count," \
        "  \"failed_count\": $failed_count" \
        '}' > "$output/summary.json"
      exit "$exit_status"
    SH
  end

  def build_fixture
    queue = File.join(@tmp, "production_backlog", "fixture")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))

    pools = [
      ["qwen35", "qwen", "qwen3.6:35b-a3b"],
      ["gemma4", "gemma", "gemma4:26b"],
      ["gpt-oss", "gptoss", "gpt-oss:20b"]
    ]
    manifests = pools.map do |pool_id, model_ref, _runtime|
      rel = "experiments/#{pool_id}.yml"
      path = File.join(@tmp, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(
        path,
        YAML.dump(
          "name" => pool_id,
          "dimension" => "Exploration Emphasis",
          "models" => [model_ref],
          "workers" => ["mac"],
          "production_contract" => { "contract_type" => "adventure_ingest_v1" }
        )
      )
      [rel, path]
    end
    File.write(File.join(queue, "run_order.txt"), manifests.map(&:first).join("\n") + "\n")

    plan = {
      "contract_version" => "afio-production-execution-pool-plan/v0.1",
      "queue" => {
        "path" => "production_backlog/fixture",
        "run_order_sha256" => Digest::SHA256.file(File.join(queue, "run_order.txt")).hexdigest,
        "snapshot_sha256" => Digest::SHA256.file(File.join(queue, "snapshot.yml")).hexdigest,
        "manifest_count" => manifests.length
      },
      "capacity" => { "max_total_hourly_usd" => 6.0 },
      "pools" => pools.each_with_index.map do |(pool_id, model_ref, runtime), index|
        rel, path = manifests.fetch(index)
        {
          "pool_id" => pool_id,
          "model_ref" => model_ref,
          "requirements" => {
            "ollama_model" => runtime,
            "pull_model" => "#{runtime}-pull",
            "expected_digest" => DIGEST,
            "required_context_length" => 131_072,
            "require_fully_gpu_resident" => true
          },
          "capacity" => {
            "desired_workers" => 1,
            "minimum_workers" => 1,
            "max_pool_hourly_usd" => 3.0
          },
          "job_count" => 1,
          "manifests" => [{
            "path" => rel,
            "sha256" => Digest::SHA256.file(path).hexdigest
          }]
        }
      end
    }
    plan_path = File.join(@tmp, "output", "plan.json")
    FileUtils.mkdir_p(File.dirname(plan_path))
    File.write(plan_path, JSON.pretty_generate(plan) + "\n")
  end
end
