# frozen_string_literal: true

require "yaml"
require_relative "production_backlog_runner_policy"

module ProductionBacklogRemoteCampaign
  class Error < StandardError; end

  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze

  module_function

  def build_plan(repo_root:, contract_type:, manifests:, group_by_model:, fleet_key:, worker_selector:, required_context:)
    root = File.expand_path(repo_root)
    model_aliases = []
    jobs = manifests.each_with_index.map do |manifest_arg, index|
      manifest_path = File.expand_path(manifest_arg, root)
      raise Error, "missing frozen manifest #{manifest_path}" unless File.file?(manifest_path)

      manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
      unless Array(manifest["workers"]).map(&:to_s) == ["mac"]
        raise Error, "remote production bridge requires workers: [mac]: #{manifest_arg}"
      end

      models = Array(manifest["models"]).map(&:to_s)
      model_aliases.concat(models)
      if group_by_model && (models.length != 1 || models.first.empty?)
        raise Error, "--group-by-model requires exactly one frozen manifest model: #{manifest_arg}"
      end

      runtime_max_tokens = ProductionBacklogRunnerPolicy.runtime_max_tokens_for(
        contract_type:,
        manifest:
      )
      environment = {}
      environment["LME_RUNTIME_MAX_TOKENS"] = runtime_max_tokens.to_s if runtime_max_tokens
      job = {
        "job_id" => format("production-%04d", index + 1),
        "argv" => ["bin/lme-production-remote-job", manifest_arg],
        "env" => environment
      }
      job["affinity"] = "model:#{models.first}" if group_by_model
      job
    end

    qualified_models = qualified_models_for(root:, model_aliases:)
    raise Error, "remote production bridge resolved no qualified models" if qualified_models.empty?

    {
      "jobs" => jobs,
      "qualified_models" => qualified_models,
      "group_by_affinity" => group_by_model,
      "capability_request" => {
        "contract_version" => "afio-rpof-capability-check-request/v0.2",
        "fleet_key" => fleet_key,
        "worker_selector" => worker_selector,
        "requirements" => {
          "models" => qualified_models.map do |model|
            {
              "name" => model.fetch("ollama_model"),
              "expected_digest" => model.fetch("expected_digest")
            }
          end,
          "required_context_length" => required_context,
          "require_fully_gpu_resident" => true
        }
      }
    }
  end

  def build_dispatch_request(plan:, capability:)
    {
      "contract_version" => "afio-rpof-dispatch-request/v0.1",
      "target" => {
        "fleet_key" => plan.fetch("capability_request").fetch("fleet_key"),
        "expected_fleet_id" => capability.fetch("fleet_id"),
        "worker_indices" => capability.fetch("selected_worker_indices")
      },
      "group_by_affinity" => plan.fetch("group_by_affinity"),
      "jobs" => plan.fetch("jobs")
    }
  end

  def qualified_models_for(root:, model_aliases:)
    model_config = YAML.safe_load_file(File.join(root, "config", "models.yml"), aliases: true).fetch("models")
    model_aliases.uniq.map do |alias_name|
      attrs = model_config.fetch(alias_name)
      ollama_model = attrs.fetch("ollama_model").to_s.strip
      pull_model = attrs.fetch("pull_model").to_s.strip
      digest = attrs.fetch("qualified_manifest_sha256").to_s.strip.downcase

      raise KeyError, "model #{alias_name.inspect} has empty ollama_model" if ollama_model.empty?
      raise KeyError, "model #{alias_name.inspect} has empty pull_model" if pull_model.empty?
      unless digest.match?(DIGEST_PATTERN)
        raise KeyError, "model #{alias_name.inspect} has invalid qualified_manifest_sha256"
      end

      {
        "model_ref" => alias_name,
        "ollama_model" => ollama_model,
        "pull_model" => pull_model,
        "expected_digest" => digest
      }
    end
  rescue KeyError => e
    raise Error, "remote production bridge requires complete qualified model identity: #{e.message}"
  end
  private_class_method :qualified_models_for
end
