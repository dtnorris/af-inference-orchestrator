# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_runner_policy"

class ProductionBacklogRunnerPolicyTest < Minitest::Test
  def manifest(dimension:, models: ["qwen"], contract_type: "adventure_ingest_v1")
    {
      "dimension" => dimension,
      "models" => models,
      "production_contract" => { "contract_type" => contract_type }
    }
  end

  def test_verifier_routing_is_exhaustive_without_shelling_out
    expected = {
      "adventure_ingest_v1" => "bin/verify-production-backlog",
      "ee_local_qualified_v1" => "verify_production_backlog_ee.sh",
      "gmbs_local_qualified_v1" => "verify_production_backlog_gmbs.sh",
      "gmpb_local_qualified_v1" => "verify_production_backlog_gmpb.sh",
      "seriousness_local_qualified_v1" => "verify_production_backlog_seriousness.sh",
      "other" => "verify_production_backlog.sh"
    }

    actual = expected.keys.to_h do |contract|
      [contract, ProductionBacklogRunnerPolicy.verifier_for(contract)]
    end
    assert_equal expected, actual
  end

  def test_runtime_amendment_policy_is_exact_without_shelling_out
    expected_tokens = ProductionBacklogRuntimeContract::EXPECTED_LLM.fetch("max_tokens")
    ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.each do |dimension|
      assert_equal expected_tokens, ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
        contract_type: "adventure_ingest_v1",
        manifest: manifest(dimension:)
      )
    end

    ["Exploration Emphasis", "GM Preparation Burden", "Seriousness", "Levels", "GM Beginner Suitability", "# of Sessions"].each do |dimension|
      assert_nil ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
        contract_type: "adventure_ingest_v1",
        manifest: manifest(dimension:)
      )
    end

    core = ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.first
    assert_nil ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
      contract_type: "adventure_ingest_v1",
      manifest: manifest(dimension: core, models: ["gptoss"])
    )
    assert_nil ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
      contract_type: "adventure_ingest_v1",
      manifest: manifest(dimension: core, contract_type: "other")
    )
    assert_nil ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
      contract_type: "unrelated",
      manifest: manifest(dimension: core)
    )
  end
end
