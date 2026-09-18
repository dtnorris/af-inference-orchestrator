# frozen_string_literal: true

require_relative "local_model_evaluation/rpof_client"
require_relative "production_budget_heartbeat"

class ProductionBudgetLifecycle
  Error = Class.new(StandardError)

  def initialize(root:, client: nil, err: $stderr)
    @root = File.expand_path(root)
    @client = client || LocalModelEvaluation::RpofClient.new(repo_root: @root)
    @err = err
    @heartbeat = nil
    @identity = nil
  end

  def start!(budget:)
    identity = {
      budget_id: budget.fetch("budget_id"),
      plan_sha256: budget.fetch("plan_sha256")
    }
    armed = false
    snapshot = @client.arm_budget(budget:)
    armed = true
    unless snapshot.fetch("state").to_s == "ARMED" && snapshot.fetch("mutation_allowed") == true
      raise Error, "RPOF production budget did not become mutation-ready"
    end
    @identity = identity
    @heartbeat = ProductionBudgetHeartbeat.new(
      client: @client,
      budget_id: @identity.fetch(:budget_id),
      plan_sha256: @identity.fetch(:plan_sha256),
      interval_seconds: budget.fetch("guardian_poll_seconds")
    ).start
    snapshot
  rescue StandardError => e
    if armed
      begin
        @client.begin_budget_teardown(
          budget_id: identity.fetch(:budget_id),
          plan_sha256: identity.fetch(:plan_sha256),
          reason: "afio_budget_lifecycle_start_failed"
        )
      rescue StandardError
        nil
      end
    end
    raise Error, e.message
  end

  def finish!(reason:)
    return true unless @identity

    begin
      @client.begin_budget_teardown(
        budget_id: @identity.fetch(:budget_id),
        plan_sha256: @identity.fetch(:plan_sha256),
        reason:
      )
    ensure
      @heartbeat&.stop
    end
    true
  rescue StandardError => e
    @err.puts "WARNING: could not explicitly begin RPOF budget teardown: #{e.message}; " \
              "orchestrator heartbeat has stopped so the independent guardian will fail closed."
    @err.flush if @err.respond_to?(:flush)
    false
  ensure
    @heartbeat&.stop
  end
end
