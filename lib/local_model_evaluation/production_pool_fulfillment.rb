# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "../production_burst_budget_contract"

module LocalModelEvaluation
  class ProductionPoolFulfillment
    REQUEST_CONTRACT = "afio-rpof-execution-pool-fulfill-request/v0.2"
    HANDOFF_CONTRACT = "afio-production-execution-pool-handoff/v0.1"

    Result = Struct.new(:handoff, :rpof_exit, :stdout, :stderr, keyword_init: true)

    def initialize(rpof_client:, paid_lock_path: nil)
      @rpof_client = rpof_client
      @paid_lock_path = paid_lock_path && File.expand_path(paid_lock_path)
    end

    def fulfill(plan:, plan_bytes:, plan_path:, pool:, dry_run:, assume_yes:, stream_output: false,
                target_workers: nil)
      request = build_request(plan:, plan_bytes:, pool:, target_workers:)
      operation = lambda do
        @rpof_client.fulfill_execution_pool(
          request:,
          dry_run:,
          assume_yes:,
          stream_output:
        )
      end
      result, rpof_exit, stdout, stderr = if !dry_run && assume_yes && @paid_lock_path
                                            with_paid_lock(&operation)
                                          else
                                            operation.call
                                          end
      validate_result_identity!(request:, result:)

      Result.new(
        handoff: {
          "contract_version" => HANDOFF_CONTRACT,
          "plan" => {
            "path" => plan_path,
            "sha256" => request.fetch("plan_sha256")
          },
          "budget" => {
            "budget_id" => request.dig("budget", "budget_id"),
            "plan_sha256" => request.fetch("plan_sha256")
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

    def build_request(plan:, plan_bytes:, pool:, target_workers:)
      requirements = pool.fetch("requirements")
      capacity = pool.fetch("capacity")
      planned_desired = positive_integer(capacity.fetch("desired_workers"), "planned desired workers")
      target = target_workers.nil? ? planned_desired : positive_integer(target_workers, "target workers")
      if target > planned_desired
        raise ArgumentError, "target workers #{target} exceeds planned desired workers #{planned_desired}"
      end
      minimum = target_workers.nil? ? capacity.fetch("minimum_workers") : target
      plan_sha = ProductionBurstBudgetContract.plan_sha256(plan_bytes)
      budget = ProductionBurstBudgetContract.request_budget(
        budget: plan.fetch("budget"),
        plan_sha256: plan_sha
      )
      {
        "contract_version" => REQUEST_CONTRACT,
        "plan_sha256" => plan_sha,
        "budget" => budget,
        "pool_id" => pool.fetch("pool_id"),
        "requirements" => {
          "ollama_model" => requirements.fetch("ollama_model"),
          "pull_model" => requirements.fetch("pull_model"),
          "expected_digest" => requirements.fetch("expected_digest"),
          "required_context_length" => requirements.fetch("required_context_length"),
          "require_fully_gpu_resident" => requirements.fetch("require_fully_gpu_resident")
        },
        "capacity" => {
          "desired_workers" => target,
          "minimum_workers" => minimum,
          "max_pool_hourly_usd" => capacity.fetch("max_pool_hourly_usd"),
          "max_total_hourly_usd" => plan.dig("capacity", "max_total_hourly_usd")
        }
      }
    end

    def with_paid_lock
      FileUtils.mkdir_p(File.dirname(@paid_lock_path))
      File.open(@paid_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        begin
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end
    end

    def positive_integer(value, label)
      integer = Integer(value)
      raise ArgumentError unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{label} must be a positive integer"
    end

    def validate_result_identity!(request:, result:)
      return if result["plan_sha256"].to_s == request.fetch("plan_sha256") &&
                result["pool_id"].to_s == request.fetch("pool_id")

      raise "RPOF fulfillment result does not match the submitted AFIO plan/pool identity"
    end
  end
end
