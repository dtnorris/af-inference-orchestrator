# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require_relative "../lib/production_backlog_remote_campaign"

class ProductionBacklogRemoteCampaignTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("production-backlog-remote-campaign-")
    target = File.join(@root, "config", "models.yml")
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(ROOT, "config", "models.yml"), target)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_builds_deterministic_jobs_and_rpof_requests_without_mutating_manifests
    first = manifest("experiments/core.yml", dimension: "Combat Emphasis")
    second = manifest("experiments/excluded.yml", dimension: "Levels", model: "gptoss")
    first_before = File.binread(first)
    second_before = File.binread(second)

    plan = build_plan(%w[experiments/core.yml experiments/excluded.yml])

    jobs = plan.fetch("jobs")
    assert_equal %w[production-0001 production-0002], jobs.map { |job| job.fetch("job_id") }
    assert_equal ["bin/lme-production-remote-job", "experiments/core.yml"], jobs.first.fetch("argv")
    assert_equal({ "LME_RUNTIME_MAX_TOKENS" => "8192" }, jobs.first.fetch("env"))
    assert_equal({}, jobs.last.fetch("env"))
    assert_equal %w[model:qwen model:gptoss], jobs.map { |job| job.fetch("affinity") }

    assert_equal(
      [
        {
          "model_ref" => "qwen",
          "ollama_model" => "qwen3.6:35b-a3b",
          "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
          "expected_digest" => "07d35212591fc27746f0a317c975a6d68754fb38e9053d82e25f06057af28522"
        },
        {
          "model_ref" => "gptoss",
          "ollama_model" => "gpt-oss:20b",
          "pull_model" => "gpt-oss:20b",
          "expected_digest" => "17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7"
        }
      ],
      plan.fetch("qualified_models")
    )

    capability = plan.fetch("capability_request")
    assert_equal "afio-rpof-capability-check-request/v0.2", capability.fetch("contract_version")
    assert_equal "default", capability.fetch("fleet_key")
    assert_equal({ "mode" => "all" }, capability.fetch("worker_selector"))
    assert_equal(
      [
        {
          "name" => "qwen3.6:35b-a3b",
          "expected_digest" => "07d35212591fc27746f0a317c975a6d68754fb38e9053d82e25f06057af28522"
        },
        {
          "name" => "gpt-oss:20b",
          "expected_digest" => "17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7"
        }
      ],
      capability.dig("requirements", "models")
    )
    assert_equal 131_072, capability.dig("requirements", "required_context_length")
    assert_equal true, capability.dig("requirements", "require_fully_gpu_resident")

    dispatch = ProductionBacklogRemoteCampaign.build_dispatch_request(
      plan:,
      capability: {
        "fleet_id" => "fixture-fleet-id",
        "selected_worker_indices" => [1, 2]
      }
    )
    assert_equal "afio-rpof-dispatch-request/v0.1", dispatch.fetch("contract_version")
    assert_equal "default", dispatch.dig("target", "fleet_key")
    assert_equal "fixture-fleet-id", dispatch.dig("target", "expected_fleet_id")
    assert_equal [1, 2], dispatch.dig("target", "worker_indices")
    assert_equal true, dispatch.fetch("group_by_affinity")
    assert_equal jobs, dispatch.fetch("jobs")

    assert_equal first_before, File.binread(first)
    assert_equal second_before, File.binread(second)
  end

  def test_fails_closed_when_qualified_identity_is_incomplete
    models_path = File.join(@root, "config", "models.yml")
    config = YAML.safe_load_file(models_path)
    config.fetch("models").fetch("qwen").delete("pull_model")
    File.write(models_path, YAML.dump(config))
    manifest("experiments/incomplete.yml", dimension: "Combat Emphasis")

    error = assert_raises(ProductionBacklogRemoteCampaign::Error) do
      build_plan(["experiments/incomplete.yml"])
    end

    assert_includes error.message, "remote production bridge requires complete qualified model identity"
    assert_includes error.message, "pull_model"
  end

  private

  def build_plan(manifests)
    ProductionBacklogRemoteCampaign.build_plan(
      repo_root: @root,
      contract_type: "adventure_ingest_v1",
      manifests:,
      group_by_model: true,
      fleet_key: "default",
      worker_selector: { "mode" => "all" },
      required_context: 131_072
    )
  end

  def manifest(path, dimension:, model: "qwen")
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(
      target,
      YAML.dump(
        "name" => File.basename(path, ".yml"),
        "dimension" => dimension,
        "models" => [model],
        "workers" => ["mac"],
        "production_contract" => { "contract_type" => "adventure_ingest_v1" }
      )
    )
    target
  end
end
