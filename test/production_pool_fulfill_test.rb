# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"
require "yaml"
require_relative "../lib/local_model_evaluation/production_pool_fulfillment"
require_relative "../lib/local_model_evaluation/production_pool_qualification"

class ProductionPoolFulfillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  class FakeRpofClient
    attr_reader :calls

    def initialize(result_overrides: {}, exit_status: 0)
      @result_overrides = result_overrides
      @exit_status = exit_status
      @calls = []
    end

    def fulfill_execution_pool(request:, dry_run:, assume_yes:, stream_output:)
      @calls << {
        request:,
        dry_run:,
        assume_yes:,
        stream_output:
      }
      ready = !dry_run
      result = {
        "contract_version" => "afio-rpof-execution-pool-fulfill-result/v0.1",
        "ready" => ready,
        "status" => dry_run ? "planned" : "ready",
        "plan_sha256" => request.fetch("plan_sha256"),
        "pool_id" => request.fetch("pool_id"),
        "execution_handle" => "opaque-#{request.fetch('pool_id')}",
        "worker_indices" => ready ? [1, 2] : []
      }.merge(@result_overrides)
      [result, @exit_status, "fake stdout", "fake stderr"]
    end
  end

  def setup
    @tmp = Dir.mktmpdir("afio-pool-fulfill-")
    copy("bin/lme-production-pool-fulfill")
    copy("lib/local_model_evaluation/rpof_client.rb")
    copy("lib/local_model_evaluation/production_pool_fulfillment.rb")
    copy("lib/local_model_evaluation/production_pool_qualification.rb")
    copy("lib/production_burst_budget_contract.rb")
    write_model_config
    fake_rpof
    @plan_path = File.join(@tmp, "output", "plan.json")
    FileUtils.mkdir_p(File.dirname(@plan_path))
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_dry_run_constructs_provider_agnostic_request_and_planned_handoff_in_process
    client = FakeRpofClient.new
    fulfillment = fulfill_with(client:, dry_run: true, assume_yes: false)

    call = client.calls.fetch(0)
    request = call.fetch(:request)
    assert_equal "afio-rpof-execution-pool-fulfill-request/v0.2", request.fetch("contract_version")
    assert_equal Digest::SHA256.hexdigest(plan_bytes), request.fetch("plan_sha256")
    assert_equal "afio-production-burst-budget/v0.1", request.dig("budget", "contract_version")
    assert_equal "budget-fixture", request.dig("budget", "budget_id")
    assert_equal request.fetch("plan_sha256"), request.dig("budget", "plan_sha256")
    assert_equal 5.0, request.dig("budget", "max_cumulative_compute_usd")
    assert_equal 2700.0, request.dig("budget", "max_runtime_seconds")
    assert_equal 5.0, request.dig("budget", "guardian_poll_seconds")
    assert_equal 30.0, request.dig("budget", "orchestrator_heartbeat_timeout_seconds")
    assert_equal 60.0, request.dig("budget", "teardown_reserve_seconds")
    assert_equal "qwen35", request.fetch("pool_id")
    assert_equal "qwen3.6:35b-a3b", request.dig("requirements", "ollama_model")
    assert_equal "qwen3.6:35b-a3b-q4_K_M", request.dig("requirements", "pull_model")
    assert_equal DIGEST, request.dig("requirements", "expected_digest")
    assert_equal 131_072, request.dig("requirements", "required_context_length")
    assert_equal 4, request.dig("capacity", "desired_workers")
    assert_equal 2, request.dig("capacity", "minimum_workers")
    assert_equal 3.0, request.dig("capacity", "max_pool_hourly_usd")
    assert_equal 6.0, request.dig("capacity", "max_total_hourly_usd")
    keys = collect_keys(request)
    refute_includes keys, "gpu_ids"
    refute_includes keys, "provider"
    refute_includes keys, "fleet_key"
    assert_equal true, call.fetch(:dry_run)
    assert_equal false, call.fetch(:assume_yes)
    assert_equal false, call.fetch(:stream_output)

    handoff = fulfillment.handoff
    assert_equal "afio-production-execution-pool-handoff/v0.1", handoff.fetch("contract_version")
    assert_equal "output/plan.json", handoff.dig("plan", "path")
    assert_equal request.fetch("plan_sha256"), handoff.dig("plan", "sha256")
    assert_equal "budget-fixture", handoff.dig("budget", "budget_id")
    assert_equal request.fetch("plan_sha256"), handoff.dig("budget", "plan_sha256")
    assert_equal "planned", handoff.dig("result", "status")
    assert_equal "opaque-qwen35", handoff.dig("result", "execution_handle")
    assert_equal "fake stdout", fulfillment.stdout
    assert_equal "fake stderr", fulfillment.stderr
  end

  def test_paid_fulfillment_can_target_one_worker_without_mutating_frozen_plan
    client = FakeRpofClient.new(result_overrides: { "worker_indices" => [1] })
    original = Marshal.load(Marshal.dump(plan))

    fulfillment = LocalModelEvaluation::ProductionPoolFulfillment.new(
      rpof_client: client
    ).fulfill(
      plan:,
      plan_bytes:,
      plan_path: "output/plan.json",
      pool: plan.fetch("pools").first,
      dry_run: false,
      assume_yes: true,
      target_workers: 1
    )

    request = client.calls.fetch(0).fetch(:request)
    assert_equal 1, request.dig("capacity", "desired_workers")
    assert_equal 1, request.dig("capacity", "minimum_workers")
    assert_equal original, plan
    assert_equal [1], fulfillment.handoff.dig("result", "worker_indices")
  end

  def test_targeted_fulfillment_rejects_capacity_above_frozen_plan_ceiling
    client = FakeRpofClient.new

    error = assert_raises(ArgumentError) do
      LocalModelEvaluation::ProductionPoolFulfillment.new(rpof_client: client).fulfill(
        plan:,
        plan_bytes:,
        plan_path: "output/plan.json",
        pool: plan.fetch("pools").first,
        dry_run: false,
        assume_yes: true,
        target_workers: 5
      )
    end

    assert_includes error.message, "exceeds planned desired workers"
    assert_empty client.calls
  end

  def test_paid_fulfillment_returns_ready_opaque_handle_and_workers_in_process
    client = FakeRpofClient.new
    fulfillment = fulfill_with(client:, dry_run: false, assume_yes: true)

    call = client.calls.fetch(0)
    assert_equal false, call.fetch(:dry_run)
    assert_equal true, call.fetch(:assume_yes)
    result = fulfillment.handoff.fetch("result")
    assert_equal true, result.fetch("ready")
    assert_equal "ready", result.fetch("status")
    assert_equal "opaque-qwen35", result.fetch("execution_handle")
    assert_equal [1, 2], result.fetch("worker_indices")
  end

  def test_fulfillment_rejects_result_identity_mismatch_in_process
    client = FakeRpofClient.new(result_overrides: { "pool_id" => "wrong-pool" })

    error = assert_raises(RuntimeError) do
      fulfill_with(client:, dry_run: true, assume_yes: false)
    end

    assert_includes error.message, "does not match the submitted AFIO plan/pool identity"
  end

  def test_cli_dry_run_routes_through_lme_rpof_and_writes_handoff
    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-pool-fulfill"),
      "output/plan.json",
      "--pool", "qwen35",
      "--output", "output/handoff.json",
      "--dry-run"
    )

    assert status.success?, out + err
    request = JSON.parse(File.read(File.join(@tmp, "captured-request.json")))
    assert_equal Digest::SHA256.file(@plan_path).hexdigest, request.fetch("plan_sha256")
    assert_equal "qwen35", request.fetch("pool_id")
    args = File.readlines(File.join(@tmp, "captured-args.txt"), chomp: true)
    assert_includes args, "--dry-run"
    refute_includes args, "--yes"
    handoff = JSON.parse(File.read(File.join(@tmp, "output", "handoff.json")))
    assert_equal "planned", handoff.dig("result", "status")
    assert_includes out, "Model ref: qwen"
    assert_includes out, "Runtime model: qwen3.6:35b-a3b"
  end

  def test_requires_explicit_dry_run_or_paid_authorization
    _out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-pool-fulfill"),
      "output/plan.json",
      "--pool", "qwen35",
      "--output", "output/handoff.json"
    )
    refute status.success?
    assert_includes err, "use --dry-run or --yes"
  end

  def test_rejects_stale_or_dequalified_plan_identity_in_process
    cases = {
      "model_ref" => lambda do |plan_document, _models|
        plan_document.fetch("pools").first["model_ref"] = "retired-qwen"
      end,
      "ollama_model" => lambda do |_plan_document, models|
        models.fetch("models").fetch("qwen")["ollama_model"] = "qwen3.6:35b-a3b-replacement"
      end,
      "pull_model" => lambda do |_plan_document, models|
        models.fetch("models").fetch("qwen")["pull_model"] = "qwen3.6:35b-a3b-q5_K_M"
      end,
      "expected_digest" => lambda do |_plan_document, models|
        models.fetch("models").fetch("qwen")["qualified_manifest_sha256"] = "b" * 64
      end
    }

    cases.each do |field, mutate|
      plan_document = plan
      models = model_config_document
      mutate.call(plan_document, models)
      File.write(model_config_path, YAML.dump(models))

      error = assert_raises(RuntimeError, "#{field} unexpectedly accepted") do
        LocalModelEvaluation::ProductionPoolQualification.verify_current_qualification!(
          plan_document.fetch("pools").first,
          models_path: model_config_path
        )
      end
      assert_includes error.message, field
    end
  end

  def test_cli_fails_closed_on_stale_qualification_before_rpof
    models = model_config_document
    models.fetch("models").fetch("qwen")["qualified_manifest_sha256"] = "b" * 64
    File.write(model_config_path, YAML.dump(models))
    FileUtils.rm_f(File.join(@tmp, "captured-args.txt"))
    FileUtils.rm_f(File.join(@tmp, "captured-request.json"))

    output = "output/rejected-expected-digest.json"
    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-pool-fulfill"),
      "output/plan.json",
      "--pool", "qwen35",
      "--output", output,
      "--dry-run"
    )

    refute status.success?, "stale qualification unexpectedly accepted:\n#{out}\n#{err}"
    assert_includes err, "expected_digest"
    refute File.exist?(File.join(@tmp, "captured-args.txt")), "stale qualification reached RPOF"
    refute File.exist?(File.join(@tmp, output)), "stale qualification wrote a fulfillment handoff"
  end

  private

  def fulfill_with(client:, dry_run:, assume_yes:)
    LocalModelEvaluation::ProductionPoolFulfillment.new(rpof_client: client).fulfill(
      plan:,
      plan_bytes:,
      plan_path: "output/plan.json",
      pool: plan.fetch("pools").first,
      dry_run:,
      assume_yes:
    )
  end

  def plan_bytes
    JSON.pretty_generate(plan) + "\n"
  end

  def plan
    {
      "contract_version" => "afio-production-execution-pool-plan/v0.1",
      "queue" => {
        "path" => "production_backlog/test",
        "run_order_sha256" => "c" * 64,
        "snapshot_sha256" => "d" * 64,
        "manifest_count" => 1
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
      "pools" => [{
        "pool_id" => "qwen35",
        "model_ref" => "qwen",
        "requirements" => {
          "ollama_model" => "qwen3.6:35b-a3b",
          "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
          "expected_digest" => DIGEST,
          "required_context_length" => 131_072,
          "require_fully_gpu_resident" => true
        },
        "capacity" => {
          "desired_workers" => 4,
          "minimum_workers" => 2,
          "max_pool_hourly_usd" => 3.0
        },
        "job_count" => 1,
        "manifests" => [{ "path" => "fixture.yml", "sha256" => "e" * 64 }]
      }]
    }
  end

  def model_config_path
    File.join(@tmp, "config", "models.yml")
  end

  def model_config_document
    {
      "models" => {
        "qwen" => {
          "ollama_model" => "qwen3.6:35b-a3b",
          "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
          "qualified_manifest_sha256" => DIGEST
        }
      }
    }
  end

  def write_model_config
    FileUtils.mkdir_p(File.dirname(model_config_path))
    File.write(model_config_path, YAML.dump(model_config_document))
  end

  def copy(path)
    target = File.join(@tmp, path)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(ROOT, path), target)
    FileUtils.chmod(0o755, target) if path.start_with?("bin/")
  end

  def collect_keys(value)
    case value
    when Hash
      value.keys.map(&:to_s) + value.values.flat_map { |child| collect_keys(child) }
    when Array
      value.flat_map { |child| collect_keys(child) }
    else
      []
    end
  end

  def fake_rpof
    path = File.join(@tmp, "bin", "lme-rpof")
    File.write(path, <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?}
      command=$1
      shift
      if [ "$command" != "execution-pool-fulfill" ]; then
        echo "unexpected command $command" >&2
        exit 1
      fi

      printf '%s\n' "$@" > "$root/captured-args.txt"
      request_path=
      output_path=
      dry_run=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --request)
            request_path=$2
            shift 2
            ;;
          --output)
            output_path=$2
            shift 2
            ;;
          --dry-run)
            dry_run=true
            shift
            ;;
          --yes)
            shift
            ;;
          *)
            shift
            ;;
        esac
      done

      cp "$request_path" "$root/captured-request.json"
      plan_sha256=$(sed -n 's/^[[:space:]]*"plan_sha256": "\([^"]*\)".*/\1/p' "$request_path" | head -n 1)
      pool_id=$(sed -n 's/^[[:space:]]*"pool_id": "\([^"]*\)".*/\1/p' "$request_path" | head -n 1)

      if [ "$dry_run" = true ]; then
        ready=false
        status=planned
        worker_indices='[]'
      else
        ready=true
        status=ready
        worker_indices='[1, 2]'
      fi

      cat > "$output_path" <<EOF
      {
        "contract_version": "afio-rpof-execution-pool-fulfill-result/v0.1",
        "ready": $ready,
        "status": "$status",
        "plan_sha256": "$plan_sha256",
        "pool_id": "$pool_id",
        "execution_handle": "opaque-$pool_id",
        "worker_indices": $worker_indices
      }
      EOF
    SH
    FileUtils.chmod(0o755, path)
  end
end
