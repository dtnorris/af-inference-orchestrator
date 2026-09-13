# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_runner_policy"
require "yaml"

class SeriousnessProductionContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONTRACT = File.join(ROOT, "production_backlog", "qualified_seriousness.yml")
  RUNTIME = File.join(ROOT, "production_backlog", "seriousness-reset-runtime.yml")

  def test_seriousness_contract_is_frozen_to_qualified_profile
    contract = YAML.safe_load_file(CONTRACT)

    assert_equal 1, contract.fetch("version")
    assert_equal "seriousness_local_qualified_v1", contract.fetch("contract_type")
    assert_equal "Seriousness", contract.fetch("dimension")
    assert_equal "seriousness-reset-only", contract.fetch("profile")
    assert_equal "Seriousness", contract.fetch("catalog_column")
    assert_equal "qwen", contract.fetch("model_alias")
    assert_equal "qwen3.6:35b-a3b", contract.fetch("ollama_model")
    assert_equal "c5f27d1060623938fa4d338340647396fb9fdc16",
                 contract.fetch("qualified_scorer_baseline")
    assert_equal "1.6.1", contract.fetch("afao_version")
    assert_equal 100, contract.fetch("max_page_count_exclusive")
    assert_equal "low", contract.fetch("reasoning_effort")
    assert_equal 16_384, contract.fetch("max_tokens")
    assert_equal 0, contract.fetch("temperature")
    assert_equal 1, contract.fetch("replicates")
    assert_equal 0.0, contract.fetch("external_api_cost_usd")
    assert_equal true, contract.fetch("no_favorable_rerun")
  end

  def test_runtime_matches_qualification
    contract = YAML.safe_load_file(CONTRACT)
    runtime = YAML.safe_load_file(RUNTIME).fetch("llm")

    assert_equal "ollama", runtime.fetch("provider")
    assert_equal contract.fetch("ollama_model"), runtime.fetch("model")
    assert_equal contract.fetch("reasoning_effort"), runtime.fetch("reasoning_effort")
    assert_equal contract.fetch("max_tokens"), runtime.fetch("max_tokens")
  end

  def test_runner_policy_routes_seriousness_contract_to_dedicated_verifier
    assert_equal(
      "verify_production_backlog_seriousness.sh",
      ProductionBacklogRunnerPolicy.verifier_for("seriousness_local_qualified_v1")
    )
  end

  def test_seriousness_production_tools_are_executable
    assert File.executable?(File.join(ROOT, "bin", "prepare-production-backlog-seriousness"))
    assert File.executable?(File.join(ROOT, "verify_production_backlog_seriousness.sh"))
  end
end
