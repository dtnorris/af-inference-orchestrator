# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_model_evaluation/rpof_readiness"

class RpofReadinessBridgeTest < Minitest::Test
  Experiment = Struct.new(:name, :worker_names, :models, keyword_init: true)

  class FakeClient
    attr_reader :request
    def capability_check(request)
      @request = request
      {
        "ready" => true,
        "fleet_id" => "fixture-fleet",
        "diagnostics" => [{ "code" => "fleet.active", "status" => "PASS", "detail" => "active" }],
        "billing" => nil,
        "capabilities" => nil
      }
    end
  end

  def test_translates_experiment_requirements_without_importing_rpof_ruby
    client = FakeClient.new
    gate = LocalModelEvaluation::RpofReadiness.new(repo_root: "/tmp/lme", client: client, required_context_length: 32_768)
    experiment = Experiment.new(name: "fixture", worker_names: %w[burst_1 burst_32], models: ["gptoss"])
    snapshot = gate.check(
      experiment: experiment,
      workers: {},
      models: { "gptoss" => { "ollama_model" => "gpt-oss:20b" } }
    )
    assert snapshot.fetch("ready")
    assert_equal [1, 32], client.request.dig("worker_selector", "indices")
    assert_equal "gpt-oss:20b", client.request.dig("requirements", "models", 0, "name")
    assert_equal 32_768, client.request.dig("requirements", "required_context_length")
  end
end
