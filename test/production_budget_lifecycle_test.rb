# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/production_budget_lifecycle"

class ProductionBudgetLifecycleTest < Minitest::Test
  PLAN = "a" * 64

  class FakeClient
    attr_reader :arms, :heartbeats, :teardowns

    def initialize(heartbeat_error: nil)
      @arms = []
      @heartbeats = []
      @teardowns = []
      @heartbeat_error = heartbeat_error
    end

    def arm_budget(budget:)
      @arms << budget
      { "state" => "ARMED", "mutation_allowed" => true }
    end

    def heartbeat_budget(budget_id:, plan_sha256:)
      @heartbeats << [budget_id, plan_sha256]
      raise LocalModelEvaluation::RpofClient::Error, @heartbeat_error if @heartbeat_error
      { "state" => "ARMED" }
    end

    def begin_budget_teardown(budget_id:, plan_sha256:, reason:)
      @teardowns << [budget_id, plan_sha256, reason]
      { "state" => "TEARDOWN_REQUIRED" }
    end
  end

  def test_start_heartbeats_and_finish_requests_teardown
    client = FakeClient.new
    lifecycle = ProductionBudgetLifecycle.new(root: Dir.pwd, client:)
    lifecycle.start!(budget: budget)
    assert_equal [["budget-fixture", PLAN]], client.heartbeats

    assert_equal true, lifecycle.finish!(reason: "fixture_complete")
    assert_equal [["budget-fixture", PLAN, "fixture_complete"]], client.teardowns
  end

  def test_initial_heartbeat_failure_requests_teardown_before_paid_work
    client = FakeClient.new(heartbeat_error: "fixture heartbeat failure")
    lifecycle = ProductionBudgetLifecycle.new(root: Dir.pwd, client:)

    error = assert_raises(ProductionBudgetLifecycle::Error) do
      lifecycle.start!(budget: budget)
    end

    assert_includes error.message, "fixture heartbeat failure"
    assert_equal [["budget-fixture", PLAN, "afio_budget_lifecycle_start_failed"]], client.teardowns
  end

  private

  def budget
    {
      "contract_version" => "afio-production-burst-budget/v0.1",
      "budget_id" => "budget-fixture",
      "plan_sha256" => PLAN,
      "max_cumulative_compute_usd" => 5.0,
      "max_runtime_seconds" => 2700.0,
      "guardian_poll_seconds" => 5.0,
      "orchestrator_heartbeat_timeout_seconds" => 30.0,
      "teardown_reserve_seconds" => 60.0
    }
  end
end
