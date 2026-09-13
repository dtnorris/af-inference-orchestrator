# frozen_string_literal: true

require "yaml"
require_relative "production_backlog_runtime_contract"

module ProductionBacklogRunnerPolicy
  DEFAULT_VERIFIER = "verify_production_backlog.sh"
  VERIFIERS = {
    "ee_local_qualified_v1" => "verify_production_backlog_ee.sh",
    "gmbs_local_qualified_v1" => "verify_production_backlog_gmbs.sh",
    "gmpb_local_qualified_v1" => "verify_production_backlog_gmpb.sh",
    "seriousness_local_qualified_v1" => "verify_production_backlog_seriousness.sh",
    "adventure_ingest_v1" => "bin/verify-production-backlog"
  }.freeze

  module_function

  def verifier_for(contract_type)
    VERIFIERS.fetch(contract_type.to_s, DEFAULT_VERIFIER)
  end

  def contract_type_from_snapshot(path)
    return "" unless File.file?(path)

    data = YAML.safe_load_file(path, aliases: true) || {}
    data["contract_type"].to_s
  end

  def runtime_max_tokens_for(contract_type:, manifest:)
    return nil unless contract_type.to_s == "adventure_ingest_v1"
    return nil unless manifest.dig("production_contract", "contract_type") == "adventure_ingest_v1"
    return nil unless manifest.fetch("models", []) == ["qwen"]
    return nil unless ProductionBacklogRuntimeContract.runtime_key_for(manifest["dimension"])

    ProductionBacklogRuntimeContract::EXPECTED_LLM.fetch("max_tokens")
  end

  def runtime_max_tokens_for_file(contract_type:, manifest_path:)
    manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
    runtime_max_tokens_for(contract_type:, manifest:)
  end
end
