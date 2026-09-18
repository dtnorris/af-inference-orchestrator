# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "yaml"
require_relative "../lib/production_backlog_runtime_contract"
require_relative "../lib/production_backlog_remote_runner"

class ProductionBacklogRemoteTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  class FakePreflight
    attr_reader :calls

    def initialize(events)
      @events = events
      @calls = []
    end

    def call(queue_arg:, contract_type:)
      @events << :preflight
      @calls << { queue_arg:, contract_type: }
    end
  end

  class FakeClient
    attr_reader :capability_requests, :dispatches

    def initialize(events:, capability:, summary:)
      @events = events
      @capability = capability
      @summary = summary
      @capability_requests = []
      @dispatches = []
    end

    def capability_check(request)
      @events << :capability
      @capability_requests << request
      @capability
    end

    def dispatch(request:, workdir:, output_dir:)
      @events << :dispatch
      @dispatches << { request:, workdir:, output_dir: }
      [@summary, 0, "fixture dispatch stdout\n", "fixture dispatch stderr\n"]
    end
  end

  def setup
    @root = Dir.mktmpdir("production-backlog-remote-")
    copy("bin/lme-production-backlog-remote")
    copy("bin/lme-production-remote-job")
    copy("lib/production_backlog_runner_policy.rb")
    copy("lib/production_backlog_runtime_contract.rb")
    copy("lib/production_backlog_remote_campaign.rb")
    copy("lib/production_backlog_remote_runner.rb")
    copy("lib/local_model_evaluation/rpof_client.rb")
    copy("config/models.yml")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_runner_preflights_checks_capability_dispatches_and_returns_result_in_process
    core = ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.first
    first = manifest("experiments/core.yml", dimension: core)
    first_before = File.binread(first)
    queue = queue_for(["experiments/core.yml"])
    events = []
    preflight = FakePreflight.new(events)
    capability = {
      "ready" => true,
      "fleet_id" => "fixture-fleet-id",
      "selected_worker_indices" => [1, 2],
      "diagnostics" => []
    }
    summary = { "status" => "completed" }
    client = FakeClient.new(events:, capability:, summary:)
    env = {}
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ProductionBacklogRemoteRunner::Runner.new(
      repo_root: @root,
      preflight:,
      client:,
      env:,
      stdout:,
      stderr:
    )

    result = runner.run(
      queue_arg: queue,
      workers: nil,
      all: true,
      output: "output/remote-campaign",
      fleet: nil,
      group_by_model: true,
      context: 131_072
    )

    assert_equal 0, result
    assert_equal %i[preflight capability dispatch], events
    assert_equal [{ queue_arg: queue, contract_type: "adventure_ingest_v1" }], preflight.calls
    assert_equal first_before, File.binread(first)

    jobs = JSON.parse(File.read(File.join(@root, "output", "remote-campaign.jobs.json"))).fetch("jobs")
    assert_equal 1, jobs.length
    assert_equal "production-0001", jobs.first.fetch("job_id")

    capability_request = client.capability_requests.fetch(0)
    assert_equal "afio-rpof-capability-check-request/v0.2", capability_request.fetch("contract_version")
    assert_equal "default", capability_request.fetch("fleet_key")
    assert_equal({ "mode" => "all" }, capability_request.fetch("worker_selector"))

    dispatch = client.dispatches.fetch(0)
    assert_equal @root, dispatch.fetch(:workdir)
    assert_equal File.join(@root, "output", "remote-campaign"), dispatch.fetch(:output_dir)
    dispatch_request = dispatch.fetch(:request)
    assert_equal "afio-rpof-dispatch-request/v0.1", dispatch_request.fetch("contract_version")
    assert_equal "default", dispatch_request.dig("target", "fleet_key")
    assert_equal "fixture-fleet-id", dispatch_request.dig("target", "expected_fleet_id")
    assert_equal [1, 2], dispatch_request.dig("target", "worker_indices")
    assert_equal true, dispatch_request.fetch("group_by_affinity")
    assert_equal jobs, dispatch_request.fetch("jobs")

    assert_equal "phase6-v0.3", env.fetch("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
    assert_equal "phase6-v0.4", env.fetch("AF_INVESTIGATION_GUARDRAIL_PROFILE")
    assert_includes stdout.string, "qwen: runtime=qwen3.6:35b-a3b"
    assert_includes stdout.string, "digest=07d35212591fc27746f0a317c975a6d68754fb38e9053d82e25f06057af28522"
    assert_includes stdout.string, "fixture dispatch stdout"
    assert_includes stderr.string, "fixture dispatch stderr"
  end

  def test_campaign_cli_parses_arguments_and_wires_runner_without_launching_preflight_children
    queue = queue_for(["experiments/core.yml"])

    out, err, status = Open3.capture3(
      { "LME_REPO" => @root },
      RbConfig.ruby,
      File.join(@root, "bin", "lme-production-backlog-remote"),
      queue,
      "--all",
      "--output", "output/remote-campaign"
    )

    refute status.success?, out
    assert_includes err, "missing/executable verifier"
    refute File.exist?(File.join(@root, "output", "remote-campaign.jobs.json"))
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
