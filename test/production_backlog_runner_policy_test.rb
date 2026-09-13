# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_runner_policy"

class ProductionBacklogRunnerPolicyTest < Minitest::Test
  def manifest(dimension:, models: ["qwen"], contract_type: "adventure_ingest_v1", name: "case")
    {
      "name" => name,
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

  def test_manifest_inspection_combines_live_status_and_runtime_policy
    Dir.mktmpdir("runner-policy") do |root|
      manifest_path = File.join(root, "case.yml")
      output_root = File.join(root, "output")
      core = ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.first
      File.write(manifest_path, YAML.dump(manifest(dimension: core)))

      status, max_tokens = ProductionBacklogRunnerPolicy.inspect_manifest_file(
        contract_type: "adventure_ingest_v1",
        manifest_path:,
        output_root:
      )
      assert_equal "pending", status
      assert_equal ProductionBacklogRuntimeContract::EXPECTED_LLM.fetch("max_tokens"), max_tokens

      run_dir = File.join(output_root, "case", "runs", "fixture")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "metadata.json"), JSON.dump("status" => "complete"))
      assert_equal(
        "complete",
        ProductionBacklogRunnerPolicy.manifest_status_for_file(manifest_path:, output_root:)
      )

      File.write(File.join(run_dir, "metadata.json"), "{not-json")
      assert_equal(
        "unknown",
        ProductionBacklogRunnerPolicy.manifest_status_for_file(manifest_path:, output_root:)
      )
    end
  end
end
