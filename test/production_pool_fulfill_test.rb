# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"

class ProductionPoolFulfillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("afio-pool-fulfill-")
    copy("bin/lme-production-pool-fulfill")
    copy("lib/local_model_evaluation/rpof_client.rb")
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
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      root = ENV.fetch("LME_REPO")
      command = ARGV.shift
      abort "unexpected command #{command}" unless command == "execution-pool-fulfill"
      File.write(File.join(root, "captured-args.txt"), ARGV.join("\n") + "\n")
      request_path = ARGV.fetch(ARGV.index("--request") + 1)
      output_path = ARGV.fetch(ARGV.index("--output") + 1)
      request = JSON.parse(File.read(request_path))
      File.write(File.join(root, "captured-request.json"), JSON.pretty_generate(request) + "\n")
      dry_run = ARGV.include?("--dry-run")
      result = {
        "contract_version" => "afio-rpof-execution-pool-fulfill-result/v0.1",
        "ready" => !dry_run,
        "status" => dry_run ? "planned" : "ready",
        "plan_sha256" => request.fetch("plan_sha256"),
        "pool_id" => request.fetch("pool_id"),
        "execution_handle" => "opaque-#{request.fetch('pool_id')}",
        "worker_indices" => dry_run ? [] : [1, 2],
        "requirements" => request.fetch("requirements"),
        "capacity" => {
          "status" => dry_run ? "planned" : "minimum_met",
          "desired_workers" => request.dig("capacity", "desired_workers"),
          "minimum_workers" => request.dig("capacity", "minimum_workers"),
          "initial_workers" => 0,
          "final_workers" => dry_run ? 0 : 2,
          "max_pool_hourly_usd" => request.dig("capacity", "max_pool_hourly_usd"),
          "max_total_hourly_usd" => request.dig("capacity", "max_total_hourly_usd")
        },
        "hardware_policy" => { "cloud" => "SECURE", "qualified_gpu_ids" => ["fixture"] },
        "runtime_alias_evidence" => [],
        "capabilities" => nil,
        "detail" => dry_run ? "fixture plan" : "fixture ready"
      }
      File.write(output_path, JSON.pretty_generate(result) + "\n")
    RUBY
    FileUtils.chmod(0o755, path)
  end
end
