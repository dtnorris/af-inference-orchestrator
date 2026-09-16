# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "yaml"
require_relative "../lib/production_execution_pool_plan"

class ProductionExecutionPoolPlanTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  QWEN_DIGEST = "07d35212591fc27746f0a317c975a6d68754fb38e9053d82e25f06057af28522"

  def setup
    @root = Dir.mktmpdir("production-execution-pools-")
    FileUtils.mkdir_p(File.join(@root, "config"))
    FileUtils.cp(File.join(ROOT, "config", "models.yml"), File.join(@root, "config", "models.yml"))
    FileUtils.cp(
      File.join(ROOT, "config", "production_execution_pools.yml"),
      File.join(@root, "config", "production_execution_pools.yml")
    )
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_builds_deterministic_hardware_agnostic_pool_plan_from_frozen_queue
    manifests = [
      manifest("experiments/001.yml", model: "qwen"),
      manifest("experiments/002.yml", model: "gptoss"),
      manifest("experiments/003.yml", model: "qwen"),
      manifest("experiments/004.yml", model: "gemma"),
      manifest("experiments/005.yml", model: "qwen27")
    ]
    queue = queue_for(manifests.map { |path| relative(path) })
    planner = ProductionExecutionPoolPlan.new(root: @root)

    first = planner.build(queue_path: queue)
    second = planner.build(queue_path: queue)

    assert_equal first, second
    assert_equal "afio-production-execution-pool-plan/v0.1", first.fetch("contract_version")
    assert_equal 5, first.dig("queue", "manifest_count")
    assert_match(/\A[0-9a-f]{64}\z/, first.dig("queue", "run_order_sha256"))
    assert_match(/\A[0-9a-f]{64}\z/, first.dig("queue", "snapshot_sha256"))
    assert_equal 6.0, first.dig("capacity", "max_total_hourly_usd")
    assert_equal %w[gemma4 gpt-oss qwen27 qwen35], first.fetch("pools").map { |pool| pool.fetch("pool_id") }
    assert_equal(
      { "gemma4" => "gemma", "gpt-oss" => "gptoss", "qwen27" => "qwen27", "qwen35" => "qwen" },
      first.fetch("pools").to_h { |pool| [pool.fetch("pool_id"), pool.fetch("model_ref")] }
    )

    qwen = first.fetch("pools").find { |pool| pool.fetch("pool_id") == "qwen35" }
    assert_equal "qwen", qwen.fetch("model_ref")
    assert_equal 2, qwen.fetch("job_count")
    assert_equal %w[experiments/001.yml experiments/003.yml], qwen.fetch("manifests").map { |row| row.fetch("path") }
    assert qwen.fetch("manifests").all? { |row| row.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }
    assert_equal "qwen3.6:35b-a3b", qwen.dig("requirements", "ollama_model")
    assert_equal "qwen3.6:35b-a3b-q4_K_M", qwen.dig("requirements", "pull_model")
    assert_equal QWEN_DIGEST, qwen.dig("requirements", "expected_digest")
    assert_equal 131_072, qwen.dig("requirements", "required_context_length")
    assert_equal true, qwen.dig("requirements", "require_fully_gpu_resident")
    assert_equal(
      { "desired_workers" => 4, "minimum_workers" => 2, "max_pool_hourly_usd" => 3.0 },
      qwen.fetch("capacity")
    )

    serialized = JSON.generate(first)
    refute_includes serialized, '"gpu"'
    refute_includes serialized, '"fleet"'
    refute_includes serialized, '"provider"'
  end

  def test_overrides_worker_context_and_cost_policy_without_changing_model_identity
    queue = queue_for([relative(manifest("experiments/qwen.yml", model: "qwen"))])
    plan = ProductionExecutionPoolPlan.new(root: @root).build(
      queue_path: queue,
      desired_workers: { "qwen35" => 8 },
      minimum_workers: { "qwen35" => 3 },
      max_pool_hourly_usd: { "qwen35" => 5.25 },
      max_total_hourly_usd: 7.5,
      required_context_length: 262_144
    )

    qwen = plan.fetch("pools").fetch(0)
    assert_equal "qwen35", qwen.fetch("pool_id")
    assert_equal "qwen", qwen.fetch("model_ref")
    assert_equal 8, qwen.dig("capacity", "desired_workers")
    assert_equal 3, qwen.dig("capacity", "minimum_workers")
    assert_equal 5.25, qwen.dig("capacity", "max_pool_hourly_usd")
    assert_equal 7.5, plan.dig("capacity", "max_total_hourly_usd")
    assert_equal 262_144, qwen.dig("requirements", "required_context_length")
    assert_equal "qwen3.6:35b-a3b", qwen.dig("requirements", "ollama_model")
    assert_equal QWEN_DIGEST, qwen.dig("requirements", "expected_digest")
  end

  def test_fails_closed_for_multi_model_manifest
    queue = queue_for([relative(manifest("experiments/multi.yml", models: %w[qwen qwen27]))])

    error = assert_raises(ProductionExecutionPoolPlan::Error) do
      ProductionExecutionPoolPlan.new(root: @root).build(queue_path: queue)
    end

    assert_includes error.message, "exactly one frozen manifest model"
  end

  def test_fails_closed_for_unmapped_or_unqualified_model
    queue = queue_for([relative(manifest("experiments/granite.yml", model: "granite"))])
    error = assert_raises(ProductionExecutionPoolPlan::Error) do
      ProductionExecutionPoolPlan.new(root: @root).build(queue_path: queue)
    end
    assert_includes error.message, "no execution pool maps frozen model"

    policy = YAML.safe_load_file(File.join(@root, "config", "production_execution_pools.yml"))
    policy.fetch("pools")["granite"] = {
      "model_ref" => "granite",
      "desired_workers" => 1,
      "minimum_workers" => 1,
      "max_pool_hourly_usd" => 3.0
    }
    File.write(File.join(@root, "config", "production_execution_pools.yml"), YAML.dump(policy))

    error = assert_raises(ProductionExecutionPoolPlan::Error) do
      ProductionExecutionPoolPlan.new(root: @root).build(queue_path: queue)
    end
    assert_includes error.message, "no pull_model"
  end

  def test_policy_rejects_duplicate_model_ref_mappings
    policy_path = File.join(@root, "config", "production_execution_pools.yml")
    policy = YAML.safe_load_file(policy_path)
    policy.fetch("pools")["qwen35-copy"] = {
      "model_ref" => "qwen",
      "desired_workers" => 1,
      "minimum_workers" => 1,
      "max_pool_hourly_usd" => 3.0
    }
    File.write(policy_path, YAML.dump(policy))
    queue = queue_for([relative(manifest("experiments/qwen.yml", model: "qwen"))])

    error = assert_raises(ProductionExecutionPoolPlan::Error) do
      ProductionExecutionPoolPlan.new(root: @root).build(queue_path: queue)
    end

    assert_includes error.message, "mapped by multiple execution pools"
  end

  private

  def manifest(path, model: nil, models: nil)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    selected_models = models || [model]
    File.write(
      target,
      YAML.dump(
        "name" => File.basename(path, ".yml"),
        "models" => selected_models,
        "workers" => ["mac"]
      )
    )
    target
  end

  def queue_for(manifests)
    queue = File.join(@root, "production_backlog", "fixture")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))
    File.write(File.join(queue, "run_order.txt"), manifests.join("\n") + "\n")
    queue
  end

  def relative(path)
    path.delete_prefix("#{@root}/")
  end
end

class ProductionExecutionPoolPlanCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("production-execution-pools-cli-")
    copy("bin/lme-production-pool-plan")
    copy("lib/production_execution_pool_plan.rb")
    copy("config/models.yml")
    copy("config/production_execution_pools.yml")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_cli_writes_stable_plan_and_applies_explicit_overrides
    manifest_path = File.join(@root, "experiments", "qwen.yml")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, YAML.dump("models" => ["qwen"], "workers" => ["mac"]))
    manifest_before = File.binread(manifest_path)
    queue = File.join(@root, "production_backlog", "fixture")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))
    File.write(File.join(queue, "run_order.txt"), "experiments/qwen.yml\n")

    command = [
      RbConfig.ruby,
      File.join(@root, "bin", "lme-production-pool-plan"),
      queue,
      "--output", "output/fixture/execution-pools.json",
      "--workers", "qwen35=6",
      "--minimum-workers", "qwen35=2",
      "--max-pool-hourly-usd", "qwen35=4.25",
      "--max-total-hourly-usd", "5.5",
      "--context", "262144"
    ]

    out, err, status = Open3.capture3({ "LME_REPO" => @root }, *command)
    assert status.success?, out + err
    assert_includes out, "qwen35"
    assert_includes out, "Hardware/provider selection is intentionally absent"
    assert_equal manifest_before, File.binread(manifest_path)

    output_path = File.join(@root, "output", "fixture", "execution-pools.json")
    first = File.binread(output_path)
    plan = JSON.parse(first)
    pool = plan.fetch("pools").fetch(0)
    assert_equal 6, pool.dig("capacity", "desired_workers")
    assert_equal 2, pool.dig("capacity", "minimum_workers")
    assert_equal 4.25, pool.dig("capacity", "max_pool_hourly_usd")
    assert_equal 5.5, plan.dig("capacity", "max_total_hourly_usd")
    assert_equal 262_144, pool.dig("requirements", "required_context_length")

    out, err, status = Open3.capture3({ "LME_REPO" => @root }, *command)
    assert status.success?, out + err
    assert_equal first, File.binread(output_path)
  end

  def test_cli_refuses_to_overwrite_a_different_existing_plan
    manifest_path = File.join(@root, "experiments", "qwen.yml")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, YAML.dump("models" => ["qwen"], "workers" => ["mac"]))
    queue = File.join(@root, "production_backlog", "fixture")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))
    File.write(File.join(queue, "run_order.txt"), "experiments/qwen.yml\n")
    output_path = File.join(@root, "output", "fixture", "execution-pools.json")
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, "{}\n")

    out, err, status = Open3.capture3(
      { "LME_REPO" => @root },
      RbConfig.ruby,
      File.join(@root, "bin", "lme-production-pool-plan"),
      queue,
      "--output", "output/fixture/execution-pools.json"
    )

    refute status.success?, out + err
    assert_includes err, "existing execution-pool plan differs"
    assert_equal "{}\n", File.read(output_path)
  end

  private

  def copy(path)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(ROOT, path), target)
    FileUtils.chmod(0o755, target) if path.start_with?("bin/")
  end
end
