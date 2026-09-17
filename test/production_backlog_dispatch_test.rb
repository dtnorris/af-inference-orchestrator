# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require_relative "../lib/production_backlog_dispatch"

class ProductionBacklogDispatchTest < Minitest::Test
  CheckResult = Struct.new(:error, :missing_models, :digest_mismatches, keyword_init: true)

  class FakeCommandAdapter
    attr_reader :calls

    def initialize(result: true)
      @result = result
      @calls = []
    end

    def run(environment:, argv:)
      @calls << { environment:, argv: }
      @result
    end
  end

  class FakeWorkerChecker
    attr_reader :calls

    def initialize(result: CheckResult.new(error: nil, missing_models: [], digest_mismatches: {}))
      @result = result
      @calls = []
    end

    def check(worker, **requirements)
      @calls << { worker:, requirements: }
      @result
    end
  end

  class FakeArtifactGuard
    attr_reader :manifests

    def initialize
      @manifests = []
    end

    def verify!(manifest:)
      @manifests << manifest
      true
    end
  end

  def test_dispatch_sets_only_the_qualified_token_override
    adapter = FakeCommandAdapter.new
    guard = FakeArtifactGuard.new
    runner = ProductionBacklogDispatch::Runner.new(command_adapter: adapter, artifact_guard: guard)

    assert runner.dispatch(manifest: "experiments/core.yml", runtime_max_tokens: "8192")
    assert runner.dispatch(manifest: "experiments/excluded.yml", runtime_max_tokens: nil)

    assert_equal %w[experiments/core.yml experiments/excluded.yml], guard.manifests
    assert_equal(
      [
        {
          environment: { "AF_LLM_MAX_TOKENS" => "8192" },
          argv: ["bin/lme", "run", "experiments/core.yml"]
        },
        {
          environment: { "AF_LLM_MAX_TOKENS" => nil },
          argv: ["bin/lme", "run", "experiments/excluded.yml"]
        }
      ],
      adapter.calls
    )
  end

  def test_dispatch_propagates_command_failure
    adapter = FakeCommandAdapter.new(result: false)
    runner = ProductionBacklogDispatch::Runner.new(command_adapter: adapter)

    refute runner.dispatch(manifest: "experiments/case.yml", runtime_max_tokens: nil)
  end

  def test_local_guard_resolves_manifest_alias_to_exact_qualified_digest
    digest = "a" * 64
    with_qualification_fixture(digest:) do |root, manifest|
      checker = FakeWorkerChecker.new
      guard = ProductionBacklogDispatch::LocalQualifiedArtifactGuard.new(
        repo_root: root,
        worker_checker: checker
      )

      assert guard.verify!(manifest:)
      call = checker.calls.fetch(0)
      assert_equal "mac", call.fetch(:worker).name
      assert_equal ["qwen3.6:35b-a3b"], call.dig(:requirements, :required_models)
      assert_equal(
        { "qwen3.6:35b-a3b" => digest },
        call.dig(:requirements, :required_model_digests)
      )
    end
  end

  def test_local_guard_fails_closed_when_qualified_digest_is_missing
    with_qualification_fixture(digest: nil) do |root, manifest|
      checker = FakeWorkerChecker.new
      guard = ProductionBacklogDispatch::LocalQualifiedArtifactGuard.new(
        repo_root: root,
        worker_checker: checker
      )

      error = assert_raises(ProductionBacklogDispatch::QualificationError) do
        guard.verify!(manifest:)
      end
      assert_includes error.message, "no exact 64-hex qualified_manifest_sha256"
      assert_empty checker.calls
    end
  end

  def test_local_guard_rejects_worker_digest_mismatch
    expected = "a" * 64
    actual = "b" * 64
    result = CheckResult.new(
      error: nil,
      missing_models: [],
      digest_mismatches: {
        "qwen3.6:35b-a3b" => { "expected" => expected, "actual" => actual }
      }
    )

    with_qualification_fixture(digest: expected) do |root, manifest|
      guard = ProductionBacklogDispatch::LocalQualifiedArtifactGuard.new(
        repo_root: root,
        worker_checker: FakeWorkerChecker.new(result:)
      )

      error = assert_raises(ProductionBacklogDispatch::QualificationError) do
        guard.verify!(manifest:)
      end
      assert_includes error.message, "qualified artifact digest mismatch"
      assert_includes error.message, "expected #{expected}, got #{actual}"
    end
  end

  private

  def with_qualification_fixture(digest:)
    Dir.mktmpdir("production-qualification") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "experiments"))
      model = { "ollama_model" => "qwen3.6:35b-a3b" }
      model["qualified_manifest_sha256"] = digest if digest
      File.write(
        File.join(root, "config", "models.yml"),
        YAML.dump("models" => { "qwen" => model })
      )
      File.write(
        File.join(root, "config", "workers.yml"),
        YAML.dump(
          "workers" => {
            "mac" => {
              "base_url" => "http://127.0.0.1:11434",
              "hourly_rate_usd" => 0.0
            }
          }
        )
      )
      manifest = File.join(root, "experiments", "case.yml")
      File.write(
        manifest,
        YAML.dump("models" => ["qwen"], "workers" => ["mac"])
      )
      yield root, manifest
    end
  end
end
