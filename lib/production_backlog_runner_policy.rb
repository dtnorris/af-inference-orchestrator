# frozen_string_literal: true

require "json"
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

  def manifest_status(manifest:, output_root:)
    name = manifest.fetch("name")
    metadata = Dir.glob(File.join(output_root, name, "runs", "*", "metadata.json")).sort
    return "pending" if metadata.empty?

    statuses = metadata.map { |path| JSON.parse(File.read(path))["status"].to_s }
    return "complete" if statuses.all? { |status| status == "complete" }
    return "failed" if statuses.any? { |status| status == "failed" }
    return "running" if statuses.any? { |status| status == "running" }

    "unknown"
  rescue JSON::ParserError
    "unknown"
  end

  def manifest_status_for_file(manifest_path:, output_root:)
    manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
    manifest_status(manifest:, output_root:)
  end

  def inspect_manifest_file(contract_type:, manifest_path:, output_root:)
    manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
    [
      manifest_status(manifest:, output_root:),
      runtime_max_tokens_for(contract_type:, manifest:)
    ]
  end
end
