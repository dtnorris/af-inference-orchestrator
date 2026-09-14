# frozen_string_literal: true

require_relative "rpof_client"

module LocalModelEvaluation
  class RpofReadiness
    BURST_NAME = /\Aburst_(\d+)\z/

    def self.applicable?(experiment)
      Array(experiment.worker_names).any? { |name| name.to_s.match?(BURST_NAME) }
    end

    def initialize(repo_root:, client: nil, required_context_length: nil)
      @repo_root = File.expand_path(repo_root)
      @client = client || RpofClient.new(repo_root: @repo_root)
      @required_context_length = Integer(required_context_length || ENV.fetch("LME_RUNPOD_REQUIRED_CONTEXT", "131072"))
    end

    def check(experiment:, workers:, models:)
      unless self.class.applicable?(experiment)
        return { "ready" => true, "applicable" => false, "experiment" => experiment.name, "checks" => [] }
      end
      indices = Array(experiment.worker_names).filter_map do |name|
        match = name.to_s.match(BURST_NAME)
        Integer(match[1]) if match
      end.sort
      required_models = Array(experiment.models).map do |alias_name|
        { "name" => models.fetch(alias_name).fetch("ollama_model").to_s }
      end
      request = {
        "contract_version" => "afio-rpof-capability-check-request/v0.1",
        "fleet_key" => ENV.fetch("LME_RUNPOD_FLEET", "default"),
        "worker_selector" => { "mode" => "indices", "indices" => indices },
        "requirements" => {
          "models" => required_models,
          "required_context_length" => @required_context_length,
          "require_fully_gpu_resident" => true
        }
      }
      result = @client.capability_check(request)
      {
        "ready" => result.fetch("ready"),
        "applicable" => true,
        "experiment" => experiment.name,
        "fleet_id" => result["fleet_id"],
        "checks" => result.fetch("diagnostics").map do |row|
          { "name" => row.fetch("code"), "status" => row.fetch("status"), "detail" => row.fetch("detail") }
        end,
        "billing" => result["billing"],
        "provenance" => result["capabilities"]
      }
    rescue KeyError, ArgumentError, TypeError, RpofClient::Error => e
      {
        "ready" => false,
        "applicable" => true,
        "experiment" => experiment.name,
        "checks" => [{ "name" => "rpof-bridge", "status" => "FAIL", "detail" => e.message }]
      }
    end

    def render(snapshot)
      return "RunPod readiness: NOT APPLICABLE -- experiment has no managed burst_N workers.\n" unless snapshot.fetch("applicable")
      lines = ["RunPod readiness", "  Experiment: #{snapshot.fetch('experiment')}"]
      lines << "  Fleet: #{snapshot['fleet_id']}" if snapshot["fleet_id"]
      lines << ""
      snapshot.fetch("checks").each do |row|
        lines << format("%-24s %-5s %s", row.fetch("name"), row.fetch("status"), row.fetch("detail"))
      end
      if snapshot["billing"]
        lines << ""
        lines << format("Tracked rate: $%.4f/hr", snapshot.dig("billing", "current_tracked_hourly_rate_usd"))
        lines << format("Estimated accrued cost: $%.4f", snapshot.dig("billing", "estimated_accrued_cost_usd"))
      end
      lines << ""
      lines << (snapshot.fetch("ready") ? "READY TO RUN" : "NOT READY")
      lines.join("\n") + "\n"
    end
  end
end
