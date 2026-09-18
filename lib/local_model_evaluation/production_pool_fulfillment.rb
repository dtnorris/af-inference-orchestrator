# frozen_string_literal: true

require "digest"

module LocalModelEvaluation
  class ProductionPoolFulfillment
    REQUEST_CONTRACT = "afio-rpof-execution-pool-fulfill-request/v0.1"
    HANDOFF_CONTRACT = "afio-production-execution-pool-handoff/v0.1"

    Result = Struct.new(:handoff, :rpof_exit, :stdout, :stderr, keyword_init: true)

    def initialize(rpof_client:)
      @rpof_client = rpof_client
    end

    def fulfill(plan:, plan_bytes:, plan_path:, pool:, dry_run:, assume_yes:, stream_output: false)
      request = build_request(plan:, plan_bytes:, pool:)
      result, rpof_exit, stdout, stderr = @rpof_client.fulfill_execution_pool(
        request:,
        dry_run:,
        assume_yes:,
        stream_output:
      )
      validate_result_identity!(request:, result:)

      Result.new(
        handoff: {
          "contract_version" => HANDOFF_CONTRACT,
          "plan" => {
            "path" => plan_path,
            "sha256" => request.fetch("plan_sha256")
          },
          "pool_id" => pool.fetch("pool_id"),
          "request" => request,
          "result" => result
        },
        rpof_exit:,
        stdout:,
        stderr:
      )
    end

    private

    def build_request(plan:, plan_bytes:, pool:)
      requirements = pool.fetch("requirements")
      capacity = pool.fetch("capacity")
      {
        "contract_version" => REQUEST_CONTRACT,
        "plan_sha256" => Digest::SHA256.hexdigest(plan_bytes),
        "pool_id" => pool.fetch("pool_id"),
        "requirements" => {
          "ollama_model" => requirements.fetch("ollama_model"),
          "pull_model" => requirements.fetch("pull_model"),
          "expected_digest" => requirements.fetch("expected_digest"),
          "required_context_length" => requirements.fetch("required_context_length"),
          "require_fully_gpu_resident" => requirements.fetch("require_fully_gpu_resident")
        },
        "capacity" => {
          "desired_workers" => capacity.fetch("desired_workers"),
          "minimum_workers" => capacity.fetch("minimum_workers"),
          "max_pool_hourly_usd" => capacity.fetch("max_pool_hourly_usd"),
          "max_total_hourly_usd" => plan.dig("capacity", "max_total_hourly_usd")
        }
      }
    end

    def validate_result_identity!(request:, result:)
      return if result["plan_sha256"].to_s == request.fetch("plan_sha256") &&
                result["pool_id"].to_s == request.fetch("pool_id")

      raise "RPOF fulfillment result does not match the submitted AFIO plan/pool identity"
    end
  end
end
