# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"
require "yaml"
require_relative "../lib/local_model_evaluation/production_pool_qualification"

class ProductionPoolFulfillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("afio-pool-fulfill-")
    copy("bin/lme-production-pool-fulfill")
    copy("lib/local_model_evaluation/rpof_client.rb")
    copy("lib/local_model_evaluation/production_pool_qualification.rb")
    write_model_config
    fake_rpof
    @plan_path = File.join(@tmp, "output", "plan.json")
    FileUtils.mkdir_p(File.dirname(@plan_path))
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_dry_run_sends_provider_agnostic_pool_requirement_to_rpof
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
    assert_equal "afio-rpof-execution-pool-fulfill-request/v0.1", request.fetch("contract_version")
    assert_equal Digest::SHA256.file(@plan_path).hexdigest, request.fetch("plan_sha256")
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

    args = File.readlines(File.join(@tmp, "captured-args.txt"), chomp: true)
    assert_includes args, "--dry-run"
    refute_includes args, "--yes"

    handoff = JSON.parse(File.read(File.join(@tmp, "output", "handoff.json")))
    assert_equal "afio-production-execution-pool-handoff/v0.1", handoff.fetch("contract_version")
    assert_equal "planned", handoff.dig("result", "status")
    assert_equal "opaque-qwen35", handoff.dig("result", "execution_handle")
    assert_includes out, "Model ref: qwen"
    assert_includes out, "Runtime model: qwen3.6:35b-a3b"
    assert_includes out, "Pull model: qwen3.6:35b-a3b-q4_K_M"
    assert_includes out, "Qualified digest: #{DIGEST}"
  end

  def test_paid_handoff_returns_ready_opaque_handle_and_worker_indices
    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(@tmp, "bin", "lme-production-pool-fulfill"),
      "output/plan.json",
      "--pool", "qwen35",
      "--output", "output/handoff-paid.json",
      "--yes"
    )

    assert status.success?, out + err
    args = File.readlines(File.join(@tmp, "captured-args.txt"), chomp: true)
    assert_includes args, "--yes"
    result = JSON.parse(File.read(File.join(@tmp, "output", "handoff-paid.json"))).fetch("result")
    assert_equal true, result.fetch("ready")
    assert_equal "ready", result.fetch("status")
    assert_equal "opaque-qwen35", result.fetch("execution_handle")
    assert_equal [1, 2], result.fetch("worker_indices")
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
