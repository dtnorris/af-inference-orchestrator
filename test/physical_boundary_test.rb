# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class PhysicalBoundaryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RPOF_OWNED_LIBRARIES = %w[
    bootstrap_store.rb
    process_supervisor.rb
    runpod_bootstrap.rb
    runpod_client.rb
    runpod_dispatcher.rb
    runpod_fleet.rb
    runpod_fleet_lifecycle.rb
    runpod_fleet_namespace.rb
    runpod_fleet_state.rb
    runpod_lease.rb
    runpod_status.rb
    runpod_tunnels.rb
    runpod_workers.rb
  ].freeze
  RETIRED_BRIDGE_LIBRARIES = %w[runpod_ready.rb runpod_provenance.rb].freeze
  RPOF_OWNED_SCRIPTS = %w[
    runpod_ollama_tunnel.sh
    setup_runpod_ollama_worker.sh
    setup_runpod_worker_remote.sh
  ].freeze
  COMPATIBILITY_SHIMS = %w[
    lme-runpod-bootstrap
    lme-runpod-dispatch
    lme-runpod-lease
    lme-runpod-lifecycle
    lme-runpod-status
    lme-runpod-tunnels
  ].freeze

  def test_rpof_owned_implementation_is_physically_absent
    (RPOF_OWNED_LIBRARIES + RETIRED_BRIDGE_LIBRARIES).each do |name|
      refute_path_exists File.join(ROOT, "lib", "local_model_evaluation", name), name
    end
    RPOF_OWNED_SCRIPTS.each do |name|
      refute_path_exists File.join(ROOT, "scripts", name), name
    end
  end

  def test_compatibility_helpers_are_only_small_external_process_shims
    COMPATIBILITY_SHIMS.each do |name|
      path = File.join(ROOT, "bin", name)
      assert_path_exists path
      source = File.read(path)
      assert_operator source.lines.length, :<=, 14, name
      assert_includes source, 'File.join(root, "bin", "lme-rpof")', name
      refute_match(/require(?:_relative)?\s+["']local_model_evaluation/, source, name)
      refute_match(/LocalModelEvaluation::Runpod|RUNPOD_API_BASE_URL|runpod-fleets/, source, name)
    end
  end

  def test_afio_runtime_does_not_import_or_reach_into_rpof_ruby
    runtime_files = Dir[
      File.join(ROOT, "{lib,bin,scripts}", "**", "*")
    ].select do |path|
      File.file?(path) &&
        !path.include?("/__pycache__/") &&
        File.extname(path) != ".pyc"
    end
    runtime = runtime_files.to_h { |path| [path.delete_prefix("#{ROOT}/"), File.read(path)] }

    runtime.each do |relative, source|
      refute_match(%r{runpod-ollama-fleet/lib|runpod_ollama_fleet/lib}, source, relative)
      refute_match(/\$LOAD_PATH.*runpod-ollama-fleet/, source, relative)
      refute_match(/require(?:_relative)?\s+["'][^"']*runpod_(?:client|fleet|lease|status|tunnels|workers|dispatcher|bootstrap|provenance|ready)/, source, relative)
      refute_match(/LocalModelEvaluation::Runpod(?:Client|Fleet|Lease|Status|Tunnels|Workers|Dispatcher|Bootstrap|Provenance|Ready)/, source, relative)
    end

    facade = File.read(File.join(ROOT, "lib", "local_model_evaluation.rb"))
    refute_includes facade, 'require_relative "local_model_evaluation/runpod_'
    assert_includes facade, 'require_relative "local_model_evaluation/rpof_client"'
    assert_includes facade, 'require_relative "local_model_evaluation/rpof_readiness"'
  end

  def test_local_plan_runs_with_rpof_deliberately_unavailable
    Dir.mktmpdir("lme-local-independence-") do |dir|
      workers = File.join(dir, "workers.yml")
      experiment = File.join(dir, "local.yml")
      File.write(workers, <<~YAML)
        workers:
          mac:
            type: ollama
            base_url: http://127.0.0.1:11434
            hourly_rate_usd: 0.0
            labels: [local]
            scorer_env:
              AF_LLM_PROVIDER: ollama
              AF_OLLAMA_BASE_URL: http://127.0.0.1:11434
      YAML
      File.write(experiment, <<~YAML)
        name: local-independence
        dispatch: pool
        models: [qwen]
        dimension: Exploration Emphasis
        adventures: [ADV-0001]
        replicates: 1
        workers: [mac]
        scorer:
          repo: scorer
          mode: regression
      YAML

      stdout, stderr, status = Open3.capture3(
        {
          "LME_WORKERS_CONFIG" => workers,
          "RPOF_EXECUTABLE" => File.join(dir, "missing-rpof")
        },
        RbConfig.ruby,
        File.join(ROOT, "bin", "lme"),
        "plan",
        experiment,
        chdir: ROOT
      )

      assert status.success?, stderr
      assert_includes stdout, "Experiment: local-independence"
      assert_includes stdout, "Workers: mac"
      refute_includes stderr, "RPOF"
    end
  end
end
