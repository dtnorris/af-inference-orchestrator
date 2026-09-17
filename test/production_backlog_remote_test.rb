# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "yaml"
require_relative "../lib/production_backlog_runtime_contract"

class ProductionBacklogRemoteTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("production-backlog-remote-")
    copy("bin/lme-production-backlog-remote")
    copy("bin/lme-production-remote-job")
    copy("lib/production_backlog_runner_policy.rb")
    copy("lib/production_backlog_runtime_contract.rb")
    copy("lib/local_model_evaluation/rpof_client.rb")
    copy("config/models.yml")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_campaign_preflights_and_materializes_deterministic_remote_jobs_without_touching_manifests
    executable("bin/verify-production-backlog", <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' "$@" > "$LME_REPO/verifier-called"
    SH
    executable("bin/preflight-production-backlog-sources", <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' "$@" > "$LME_REPO/source-preflight-called"
    SH
    executable("bin/lme-rpof", <<~'SH')
      #!/bin/sh
      set -eu

      root=${LME_REPO:?LME_REPO required}
      command=${1:?command required}
      shift
      request=""
      output=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --request)
            request=${2:?--request value required}
            shift 2
            ;;
          --output)
            output=${2:?--output value required}
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done

      case "$command" in
        capability-check)
          [ -n "$request" ] || { echo "missing --request" >&2; exit 2; }
          [ -n "$output" ] || { echo "missing --output" >&2; exit 2; }
          cp "$request" "$root/capability-request.json"
          cat > "$output" <<'JSON'
      {"contract_version":"afio-rpof-capability-check-result/v0.1","ready":true,"fleet_key":"default","fleet_id":"fixture-fleet-id","selected_worker_indices":[1,2],"capabilities":null,"diagnostics":[]}
      JSON
          ;;
        dispatch)
          [ -n "$request" ] || { echo "missing --request" >&2; exit 2; }
          [ -n "$output" ] || { echo "missing --output" >&2; exit 2; }
          cp "$request" "$root/dispatch-request.json"
          mkdir -p "$output"
          printf '{"social":"%s","investigation":"%s"}\n' \
            "${AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE-}" \
            "${AF_INVESTIGATION_GUARDRAIL_PROFILE-}" > "$root/dispatch-env.json"
          cat > "$output/summary.json" <<'JSON'
      {"contract_version":"afio-rpof-dispatch-summary/v0.1","fleet_key":"default","fleet_id":"fixture-fleet-id","started_at_utc":"2026-09-14T12:00:00Z","finished_at_utc":"2026-09-14T12:00:01Z","status":"completed","worker_count":2,"job_count":2,"completed_count":2,"failed_count":0,"not_started_count":0,"not_started_job_ids":[],"infrastructure_failures":[],"jobs":[]}
      JSON
          ;;
        *)
          echo "unexpected RPOF command: $command" >&2
          exit 2
          ;;
      esac
    SH

    core = ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.first
    first = manifest("experiments/core.yml", dimension: core)
    second = manifest("experiments/excluded.yml", dimension: "Levels", model: "gptoss")
    first_before = File.binread(first)
    second_before = File.binread(second)
    queue = queue_for(%w[experiments/core.yml experiments/excluded.yml])

    out, err, status = Open3.capture3(
      { "LME_REPO" => @root, "AF_LLM_MAX_TOKENS" => "99999" },
      RbConfig.ruby,
      File.join(@root, "bin", "lme-production-backlog-remote"),
      queue,
      "--all",
      "--group-by-model",
      "--output", "output/remote-campaign"
    )

    assert status.success?, out + err
    assert File.file?(File.join(@root, "verifier-called"))
    assert File.file?(File.join(@root, "source-preflight-called"))
    assert_equal first_before, File.binread(first)
    assert_equal second_before, File.binread(second)

    jobs = JSON.parse(File.read(File.join(@root, "output", "remote-campaign.jobs.json"))).fetch("jobs")
    assert_equal %w[production-0001 production-0002], jobs.map { |job| job.fetch("job_id") }
    assert_equal ["bin/lme-production-remote-job", "experiments/core.yml"], jobs.first.fetch("argv")
    assert_equal({ "LME_RUNTIME_MAX_TOKENS" => "8192" }, jobs.first.fetch("env"))
    assert_equal({}, jobs.last.fetch("env"))
    assert_equal %w[model:qwen model:gptoss], jobs.map { |job| job.fetch("affinity") }

    capability = JSON.parse(File.read(File.join(@root, "capability-request.json")))
    assert_equal "afio-rpof-capability-check-request/v0.1", capability.fetch("contract_version")
    assert_equal "default", capability.fetch("fleet_key")
    assert_equal({ "mode" => "all" }, capability.fetch("worker_selector"))
    assert_equal(
      %w[qwen3.6:35b-a3b gpt-oss:20b],
      capability.dig("requirements", "models").map { |model| model.fetch("name") }
    )
    assert_equal 131_072, capability.dig("requirements", "required_context_length")
    assert_equal true, capability.dig("requirements", "require_fully_gpu_resident")

    dispatch = JSON.parse(File.read(File.join(@root, "dispatch-request.json")))
    assert_equal "afio-rpof-dispatch-request/v0.1", dispatch.fetch("contract_version")
    assert_equal "default", dispatch.dig("target", "fleet_key")
    assert_equal "fixture-fleet-id", dispatch.dig("target", "expected_fleet_id")
    assert_equal [1, 2], dispatch.dig("target", "worker_indices")
    assert_equal true, dispatch.fetch("group_by_affinity")
    assert_equal jobs, dispatch.fetch("jobs")

    env = JSON.parse(File.read(File.join(@root, "dispatch-env.json")))
    assert_equal "phase6-v0.3", env.fetch("social")
    assert_equal "phase6-v0.4", env.fetch("investigation")
  end

  def test_remote_job_remaps_only_mac_endpoint_and_clears_inherited_token_override
    workers_path = File.join(@root, "config", "workers.yml")
    FileUtils.mkdir_p(File.dirname(workers_path))
    original_workers = {
      "workers" => {
        "mac" => {
          "base_url" => "http://127.0.0.1:11434",
          "labels" => %w[local apple-silicon],
          "max_parallel" => 1,
          "hourly_rate_usd" => 0.0,
          "scorer_env" => {
            "AF_LLM_PROVIDER" => "ollama",
            "AF_OLLAMA_BASE_URL" => "http://127.0.0.1:11434"
          }
        }
      }
    }
    File.write(workers_path, YAML.dump(original_workers))
    workers_before = File.binread(workers_path)
    manifest_path = manifest("experiments/case.yml", dimension: "Combat Emphasis")
    manifest_before = File.binread(manifest_path)

    executable("bin/lme", <<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      require "json"
      require "yaml"
      root = ENV.fetch("LME_REPO")
      config_path = ENV.fetch("LME_WORKERS_CONFIG")
      File.write(File.join(root, "captured-workers.yml"), File.read(config_path))
      File.write(
        File.join(root, "captured-job.json"),
        JSON.dump(
          "argv" => ARGV,
          "tokens" => ENV["AF_LLM_MAX_TOKENS"],
          "workers_config" => config_path
        )
      )
      manifest = YAML.safe_load_file(ARGV.fetch(1))
      run_dir = File.join(root, "output", manifest.fetch("name"), "runs", "fixture")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "metadata.json"), JSON.dump("status" => "complete"))
    RUBY

    out, err, status = Open3.capture3(
      {
        "LME_REPO" => @root,
        "LME_OLLAMA_URL" => "http://127.0.0.1:11456",
        "LME_RUNTIME_MAX_TOKENS" => "8192",
        "AF_LLM_MAX_TOKENS" => "99999"
      },
      RbConfig.ruby,
      File.join(@root, "bin", "lme-production-remote-job"),
      "experiments/case.yml"
    )

    assert status.success?, out + err
    assert_equal workers_before, File.binread(workers_path)
    assert_equal manifest_before, File.binread(manifest_path)

    captured = YAML.safe_load_file(File.join(@root, "captured-workers.yml"))
    mac = captured.fetch("workers").fetch("mac")
    assert_equal "http://127.0.0.1:11456", mac.fetch("base_url")
    assert_equal %w[local apple-silicon], mac.fetch("labels")
    assert_equal "ollama", mac.fetch("scorer_env").fetch("AF_LLM_PROVIDER")
    assert_equal "http://127.0.0.1:11456", mac.fetch("scorer_env").fetch("AF_OLLAMA_BASE_URL")

    capture = JSON.parse(File.read(File.join(@root, "captured-job.json")))
    assert_equal ["run", "experiments/case.yml"], capture.fetch("argv")
    assert_equal "8192", capture.fetch("tokens")
    refute File.exist?(capture.fetch("workers_config")), "temporary workers config should be removed"
  end

  private

  def copy(path)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(ROOT, path), target)
    FileUtils.chmod(0o755, target) if path.start_with?("bin/")
  end

  def executable(path, content)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
    FileUtils.chmod(0o755, target)
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

  def queue_for(manifests)
    queue = File.join(@root, "production_backlog", "production-backlog-test")
    FileUtils.mkdir_p(queue)
    File.write(File.join(queue, "snapshot.yml"), YAML.dump("contract_type" => "adventure_ingest_v1"))
    File.write(File.join(queue, "run_order.txt"), manifests.join("\n") + "\n")
    queue
  end
end
