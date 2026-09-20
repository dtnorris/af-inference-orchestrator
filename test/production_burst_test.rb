# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "yaml"
require "digest"
require_relative "../lib/production_burst_runner"

class ProductionBurstTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64
  POOLS = [
    ["qwen35", "qwen", "qwen3.6:35b-a3b"],
    ["gemma4", "gemma", "gemma4:26b"],
    ["gpt-oss", "gptoss", "gpt-oss:20b"]
  ].freeze

  class FakePreflight
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run!(queue_dir:, contract_type:)
      @calls << { queue_dir:, contract_type: }
      true
    end
  end

  class FakeFulfillmentLauncher
    attr_reader :calls
    attr_reader :targets

    def initialize(fail_pool: nil)
      @fail_pool = fail_pool
      @calls = []
      @targets = []
    end

    def call(plan_path:, pool_id:, handoff_path:, dry_run:, target_workers: nil)
      @calls << pool_id
      @targets << target_workers
      plan_sha = Digest::SHA256.file(plan_path).hexdigest
      plan_document = JSON.parse(File.read(plan_path))
      failed = !dry_run && pool_id == @fail_pool
      result = if dry_run
                 {
                   "ready" => false,
                   "status" => "planned",
                   "execution_handle" => "ep-#{pool_id}",
                   "worker_indices" => [],
                   "detail" => "planned"
                 }
               elsif failed
                 {
                   "ready" => false,
                   "status" => "unfulfilled",
                   "execution_handle" => "ep-#{pool_id}",
                   "worker_indices" => [],
                   "detail" => "fixture unavailable"
                 }
               else
                 {
                   "ready" => true,
                   "status" => "ready",
                   "execution_handle" => "ep-#{pool_id}",
                   "worker_indices" => (1..Integer(target_workers || 1)).to_a,
                   "detail" => "ready"
                 }
               end
      FileUtils.mkdir_p(File.dirname(handoff_path))
      File.write(
        handoff_path,
        JSON.pretty_generate(
          "contract_version" => "afio-production-execution-pool-handoff/v0.1",
          "plan" => { "path" => plan_path, "sha256" => plan_sha },
          "budget" => {
            "budget_id" => plan_document.dig("budget", "budget_id"),
            "plan_sha256" => plan_sha
          },
          "pool_id" => pool_id,
          "request" => {},
          "result" => result.merge(
            "contract_version" => "afio-rpof-execution-pool-fulfill-result/v0.1",
            "plan_sha256" => plan_sha,
            "pool_id" => pool_id
          )
        ) + "\n"
      )
      !failed
    end
  end

  class FakeCampaignLauncher
    attr_reader :launches

    def initialize(workload_fail_pool: nil)
      @workload_fail_pool = workload_fail_pool
      @launches = []
      @statuses = {}
      @next_pid = 10_000
    end

    def launch(pool_id:, workers:, execution_handle:, requirements:, jobs_path:, campaign_dir:, queue_dir:, keep_fleet:,
               plan_path:, initial_fulfillment_seconds:)
      @launches << {
        pool_id:,
        workers:,
        execution_handle:,
        requirements:,
        jobs_path:,
        campaign_dir:,
        queue_dir:,
        keep_fleet:,
        plan_path:,
        initial_fulfillment_seconds:
      }
      @next_pid += 1
      pid = @next_pid
      status = pool_id == @workload_fail_pool ? "workload_failed" : "completed"
      FileUtils.mkdir_p(campaign_dir)
      File.write(File.join(campaign_dir, "summary.json"), JSON.dump("status" => status))
      @statuses[pid] = status
      pid
    end

    def wait(pid)
      @statuses.fetch(pid) == "workload_failed" ? 2 : 0
    end

    def alive?(_pid)
      false
    end

    def interrupt(_pid); end

    def wait_after_interrupt(_pid); end
  end

  class FakeBudgetLifecycle
    attr_reader :starts, :finishes

    def initialize
      @starts = []
      @finishes = []
    end

    def start!(budget:)
      @starts << budget
      { "state" => "ARMED", "mutation_allowed" => true }
    end

    def finish!(reason:)
      @finishes << reason
      true
    end
  end

  def setup
    @tmp = Dir.mktmpdir("production-burst-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_independent_lane_failure_does_not_block_other_ready_campaigns_in_process
    build_fixture
    fulfillment = FakeFulfillmentLauncher.new(fail_pool: "gemma4")
    campaign = FakeCampaignLauncher.new

    result, = run_runner(fulfillment:, campaign:)

    assert_equal 1, result.exit_status
    assert_equal "completed", result.ledger.dig("pools", "qwen35", "status")
    assert_equal "fulfillment_failed", result.ledger.dig("pools", "gemma4", "status")
    assert_equal "completed", result.ledger.dig("pools", "gpt-oss", "status")
    assert_equal %w[qwen35 gemma4 gpt-oss], fulfillment.calls
    assert_equal %w[qwen35 gpt-oss], campaign.launches.map { |launch| launch.fetch(:pool_id) }
  end

  def test_resume_skips_completed_and_sticky_workload_failed_lanes_in_process
    build_fixture
    burst_root = File.join(@tmp, "output", "burst")
    write_campaign_summary(burst_root, "qwen35", "completed")
    write_campaign_summary(burst_root, "gemma4", "workload_failed")
    fulfillment = FakeFulfillmentLauncher.new
    campaign = FakeCampaignLauncher.new

    result, = run_runner(fulfillment:, campaign:)

    assert_equal 2, result.exit_status
    assert_equal ["gpt-oss"], fulfillment.calls
    assert_equal ["gpt-oss"], campaign.launches.map { |launch| launch.fetch(:pool_id) }
    assert_equal "completed", result.ledger.dig("pools", "qwen35", "status")
    assert_equal "workload_failed", result.ledger.dig("pools", "gemma4", "status")
    assert_equal "completed", result.ledger.dig("pools", "gpt-oss", "status")
  end

  def test_dry_run_fulfills_all_pools_but_launches_no_campaigns_in_process
    build_fixture
    fulfillment = FakeFulfillmentLauncher.new
    campaign = FakeCampaignLauncher.new

    result, out = run_runner(fulfillment:, campaign:, dry_run: true, output: "output/burst-dry")

    assert_equal 0, result.exit_status
    assert_equal "planned", result.ledger.fetch("status")
    assert_equal "budget-fixture", result.ledger.dig("budget", "budget_id")
    assert_equal Digest::SHA256.file(File.join(@tmp, "output", "plan.json")).hexdigest,
                 result.ledger.dig("budget", "plan_sha256")
    assert_equal %w[qwen35 gemma4 gpt-oss], fulfillment.calls
    assert_empty campaign.launches
    assert_includes out, "qwen35: model_ref=qwen runtime=qwen3.6:35b-a3b digest=#{DIGEST}"
    assert_includes out, "gemma4: model_ref=gemma runtime=gemma4:26b digest=#{DIGEST}"
    assert_includes out, "gpt-oss: model_ref=gptoss runtime=gpt-oss:20b digest=#{DIGEST}"
  end

  def test_resume_rejects_mismatched_budget_identity
    build_fixture(pools: [POOLS.first])
    fulfillment = FakeFulfillmentLauncher.new
    campaign = FakeCampaignLauncher.new
    run_runner(
      fulfillment:,
      campaign:,
      dry_run: true,
      output: "output/budget-resume"
    )

    ledger_path = File.join(@tmp, "output", "budget-resume", "production-burst.json")
    ledger = JSON.parse(File.read(ledger_path))
    ledger.fetch("budget")["budget_id"] = "different-budget"
    File.write(ledger_path, JSON.pretty_generate(ledger) + "\n")

    error = assert_raises(ProductionBurstRunner::Error) do
      run_runner(
        fulfillment: FakeFulfillmentLauncher.new,
        campaign: FakeCampaignLauncher.new,
        dry_run: true,
        output: "output/budget-resume"
      )
    end
    assert_includes error.message, "different production budget identity"
    assert_includes error.message, "new --output directory"
  end

  def test_paid_burst_starts_campaign_with_one_worker_and_passes_expansion_context
    build_fixture(pools: [POOLS.first])
    plan_path = File.join(@tmp, "output", "plan.json")
    document = JSON.parse(File.read(plan_path))
    document.dig("pools", 0, "capacity")["desired_workers"] = 4
    document.dig("pools", 0, "capacity")["minimum_workers"] = 2
    File.write(plan_path, JSON.pretty_generate(document) + "\n")

    fulfillment = FakeFulfillmentLauncher.new
    campaign = FakeCampaignLauncher.new
    clock = 0.0
    runner = ProductionBurstRunner.new(
      root: @tmp,
      preflight: FakePreflight.new,
      fulfillment_launcher: fulfillment,
      campaign_launcher: campaign,
      out: StringIO.new,
      err: StringIO.new,
      budget_lifecycle: FakeBudgetLifecycle.new,
      monotonic_clock: -> { clock += 5.0 }
    )

    result = runner.run(
      plan: "output/plan.json",
      output: "output/burst-starter",
      dry_run: false,
      keep_fleets: false
    )

    assert_equal 0, result.exit_status
    assert_equal [1], fulfillment.targets
    launch = campaign.launches.fetch(0)
    assert_equal [1], launch.fetch(:workers)
    assert_equal "output/plan.json", launch.fetch(:plan_path)
    assert_in_delta 5.0, launch.fetch(:initial_fulfillment_seconds), 0.001
  end

  def test_resume_recovers_admitted_prefix_and_pending_prepare_but_reuses_original_dispatch_initial_workers
    build_fixture(pools: [POOLS.first])
    plan_path = File.join(@tmp, "output", "plan.json")
    document = JSON.parse(File.read(plan_path))
    document.dig("pools", 0, "capacity")["desired_workers"] = 4
    document.dig("pools", 0, "capacity")["minimum_workers"] = 1
    File.write(plan_path, JSON.pretty_generate(document) + "\n")

    campaign_dir = File.join(@tmp, "output", "burst-resume", "pools", "qwen35", "campaign")
    FileUtils.mkdir_p(campaign_dir)
    File.write(File.join(campaign_dir, "manifest.json"), JSON.generate("worker_indices" => [1]))
    File.write(
      File.join(campaign_dir, "worker-admissions.jsonl"),
      [2, 3].map { |index| JSON.generate("status" => "admitted", "worker_index" => index) }.join("\n") + "\n"
    )
    File.write(
      File.join(campaign_dir, "worker-expansion.jsonl"),
      JSON.generate("event" => "preparing", "target_worker" => 4) + "\n"
    )

    fulfillment = FakeFulfillmentLauncher.new
    campaign = FakeCampaignLauncher.new
    result, = run_runner(
      fulfillment:,
      campaign:,
      output: "output/burst-resume"
    )

    assert_equal 0, result.exit_status
    assert_equal [4], fulfillment.targets
    launch = campaign.launches.fetch(0)
    assert_equal [1], launch.fetch(:workers)
    assert_equal "ep-qwen35", launch.fetch(:execution_handle)
  end

  def test_cli_smoke_wires_preflight_fulfillment_and_campaign_children
    build_fixture(pools: [POOLS.first])
    copy("bin/lme-production-burst")
    copy("lib/production_burst_runner.rb")
    copy("lib/production_burst_budget_contract.rb")
    copy("lib/production_budget_heartbeat.rb")
    copy("lib/production_budget_lifecycle.rb")
    copy("lib/local_model_evaluation/rpof_client.rb")
    copy("lib/production_backlog_runner_policy.rb")
    copy("lib/production_backlog_runtime_contract.rb")
    fake_rpof_budget_child
    executable("bin/verify-production-backlog", <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' verifier >> "$LME_REPO/preflight-calls.txt"
    SH
    executable("bin/preflight-production-backlog-sources", <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' source >> "$LME_REPO/preflight-calls.txt"
    SH
    fake_fulfill_child
    fake_campaign_child
    plan_path = File.join(@tmp, "output", "plan.json")
    plan = JSON.parse(File.read(plan_path))
    campaign_dir = File.join(@tmp, "output", "burst", "pools", "qwen35", "campaign")
    FileUtils.mkdir_p(campaign_dir)
    fixture_env = {
      "LME_REPO" => @tmp,
      "AFIO_TEST_PLAN_SHA256" => Digest::SHA256.file(plan_path).hexdigest,
      "AFIO_TEST_BUDGET_ID" => plan.dig("budget", "budget_id")
    }

    out, err, status = Open3.capture3(
      fixture_env,
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-burst"),
      "output/plan.json",
      "--output", "output/burst",
      "--yes"
    )

    assert status.success?, out + err
    assert_equal %w[verifier source], File.readlines(File.join(@tmp, "preflight-calls.txt"), chomp: true)
    assert_equal ["qwen35"], File.readlines(File.join(@tmp, "fulfill-calls.txt"), chomp: true)
    assert_equal ["qwen35"], File.readlines(File.join(@tmp, "campaign-launches.txt"), chomp: true)
    ledger = JSON.parse(File.read(File.join(@tmp, "output", "burst", "production-burst.json")))
    assert_equal "completed", ledger.fetch("status")
    assert_equal "completed", ledger.dig("pools", "qwen35", "status")
  end

  private

  def run_runner(fulfillment:, campaign:, dry_run: false, output: "output/burst")
    out = StringIO.new
    err = StringIO.new
    preflight = FakePreflight.new
    runner = ProductionBurstRunner.new(
      root: @tmp,
      preflight:,
      fulfillment_launcher: fulfillment,
      campaign_launcher: campaign,
      out:,
      err:,
      budget_lifecycle: FakeBudgetLifecycle.new
    )
    result = runner.run(
      plan: "output/plan.json",
      output:,
      dry_run:,
      keep_fleets: false
    )
    [result, out.string, err.string, preflight]
  end

  def write_campaign_summary(burst_root, pool_id, status)
    campaign = File.join(burst_root, "pools", pool_id, "campaign")
    FileUtils.mkdir_p(campaign)
    File.write(File.join(campaign, "summary.json"), JSON.dump("status" => status))
  end

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

  def fake_rpof_budget_child
    executable("bin/lme-rpof", <<~'SH')
      #!/bin/sh
      set -eu
      command=${1:-}
      subcommand=${2:-}
      if [ "$command" != "budget" ]; then
        echo "unexpected command: $*" >&2
        exit 2
      fi
      case "$subcommand" in
        arm)
          printf '%s\n' '{"state":"ARMED","mutation_allowed":true}'
          ;;
        heartbeat)
          printf '%s\n' '{"state":"ARMED","mutation_allowed":true}'
          ;;
        begin-teardown)
          printf '%s\n' '{"state":"TEARDOWN_REQUIRED","mutation_allowed":false}'
          ;;
        status)
          printf '%s\n' '{"state":"ARMED","mutation_allowed":true}'
          ;;
        *)
          echo "unexpected budget subcommand: $subcommand" >&2
          exit 2
          ;;
      esac
    SH
  end

  def fake_fulfill_child
    executable("bin/lme-production-pool-fulfill", <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?}
      plan_arg=$1
      shift
      pool=
      output_arg=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --pool) pool=$2; shift 2 ;;
          --output) output_arg=$2; shift 2 ;;
          *) shift ;;
        esac
      done
      plan_path="$root/$plan_arg"
      output="$root/$output_arg"
      printf '%s\n' "$pool" >> "$root/fulfill-calls.txt"
      plan_sha=${AFIO_TEST_PLAN_SHA256:?}
      budget_id=${AFIO_TEST_BUDGET_ID:?}
      printf '%s\n' \
        '{' \
        '  "contract_version": "afio-production-execution-pool-handoff/v0.1",' \
        "  \"plan\": { \"path\": \"$plan_path\", \"sha256\": \"$plan_sha\" }," \
        "  \"budget\": { \"budget_id\": \"$budget_id\", \"plan_sha256\": \"$plan_sha\" }," \
        "  \"pool_id\": \"$pool\"," \
        '  "request": {},' \
        '  "result": {' \
        '    "contract_version": "afio-rpof-execution-pool-fulfill-result/v0.1",' \
        '    "ready": true,' \
        '    "status": "ready",' \
        "    \"plan_sha256\": \"$plan_sha\"," \
        "    \"pool_id\": \"$pool\"," \
        "    \"execution_handle\": \"ep-$pool\"," \
        '    "worker_indices": [1],' \
        '    "detail": "ready"' \
        '  }' \
        '}' > "$output"
    SH
  end

  def fake_campaign_child
    executable("bin/lme-rpof-campaign", <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?}
      fleet=
      output=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --fleet) fleet=$2; shift 2 ;;
          --output) output=$2; shift 2 ;;
          *) shift ;;
        esac
      done
      pool=${fleet#ep-}
      printf '%s\n' "$pool" >> "$root/campaign-launches.txt"
      printf '%s\n' '{"contract_version":"afio-rpof-dispatch-summary/v0.1","status":"completed"}' > "$output/summary.json"
    SH
  end

  def build_fixture(pools: POOLS)
    queue = File.join(@tmp, "production_backlog", "fixture")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))

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
      "budget" => {
        "contract_version" => "afio-production-burst-budget/v0.1",
        "budget_id" => "budget-fixture",
        "max_cumulative_compute_usd" => 5.0,
        "max_runtime_seconds" => 2700.0,
        "guardian_poll_seconds" => 5.0,
        "orchestrator_heartbeat_timeout_seconds" => 30.0,
        "teardown_reserve_seconds" => 60.0
      },
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
