# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/production_worker_expansion_policy"

class ProductionWorkerExpansionPolicyTest < Minitest::Test
  def setup
    @policy = ProductionWorkerExpansionPolicy.new
  end

  def test_expands_for_large_backlog_when_time_savings_are_cheap
    decision = evaluate(
      remaining_jobs: 208,
      active_workers: 1,
      current_fleet_hourly_usd: 1.09,
      minimum_time_saved_seconds: 60,
      maximum_incremental_cost_per_hour_saved_usd: 1.0
    )

    assert_equal true, decision.fetch("expand")
    assert_equal "expand", decision.fetch("reason")
    estimates = decision.fetch("estimates")
    assert_in_delta 23_920.0, estimates.fetch("finish_without_expansion_seconds"), 0.001
    assert_in_delta 12_145.0, estimates.fetch("finish_with_expansion_seconds"), 0.001
    assert_in_delta 11_775.0, estimates.fetch("time_saved_seconds"), 0.001
    assert_equal 103, estimates.fetch("candidate_jobs")
    assert_in_delta 0.112028, estimates.fetch("incremental_cost_usd"), 0.000001
    assert_in_delta 0.034251, estimates.fetch("incremental_cost_per_hour_saved_usd"), 0.000001
  end

  def test_rejects_candidate_that_would_not_receive_a_job_before_current_workers_finish
    decision = evaluate(
      remaining_jobs: 18,
      active_workers: 6,
      current_fleet_hourly_usd: 6.54,
      minimum_time_saved_seconds: 0,
      maximum_incremental_cost_per_hour_saved_usd: 100.0
    )

    assert_equal false, decision.fetch("expand")
    assert_equal "candidate_would_not_receive_work", decision.fetch("reason")
    assert_equal 0, decision.dig("estimates", "candidate_jobs")
    assert_equal 0.0, decision.dig("estimates", "time_saved_seconds")
    assert_nil decision.dig("estimates", "incremental_cost_per_hour_saved_usd")
  end

  def test_rejects_small_wall_clock_gain_below_explicit_threshold
    decision = evaluate(
      remaining_jobs: 40,
      active_workers: 6,
      current_fleet_hourly_usd: 6.54,
      minimum_time_saved_seconds: 60,
      maximum_incremental_cost_per_hour_saved_usd: 100.0
    )

    assert_equal false, decision.fetch("expand")
    assert_equal "insufficient_time_saved", decision.fetch("reason")
    assert_in_delta 45.0, decision.dig("estimates", "time_saved_seconds"), 0.001
    assert_equal 4, decision.dig("estimates", "candidate_jobs")
  end

  def test_rejects_expansion_when_cost_per_hour_saved_exceeds_explicit_limit
    decision = evaluate(
      remaining_jobs: 40,
      active_workers: 6,
      current_fleet_hourly_usd: 6.54,
      minimum_time_saved_seconds: 0,
      maximum_incremental_cost_per_hour_saved_usd: 10.0
    )

    assert_equal false, decision.fetch("expand")
    assert_equal "cost_per_hour_saved_exceeds_limit", decision.fetch("reason")
    assert_in_delta 11.868889, decision.dig("estimates", "incremental_cost_per_hour_saved_usd"), 0.000001
  end

  def test_rejects_expansion_at_worker_ceiling
    decision = evaluate(
      remaining_jobs: 208,
      active_workers: 10,
      desired_worker_ceiling: 10,
      current_fleet_hourly_usd: 10.90,
      minimum_time_saved_seconds: 0,
      maximum_incremental_cost_per_hour_saved_usd: 100.0
    )

    assert_equal false, decision.fetch("expand")
    assert_equal "worker_ceiling_reached", decision.fetch("reason")
  end

  def test_rejects_expansion_when_no_work_remains
    decision = evaluate(
      remaining_jobs: 0,
      active_workers: 4,
      current_fleet_hourly_usd: 4.36,
      minimum_time_saved_seconds: 0,
      maximum_incremental_cost_per_hour_saved_usd: 100.0
    )

    assert_equal false, decision.fetch("expand")
    assert_equal "no_remaining_work", decision.fetch("reason")
    assert_equal 0.0, decision.dig("estimates", "finish_without_expansion_seconds")
  end

  def test_validates_policy_inputs
    error = assert_raises(ProductionWorkerExpansionPolicy::Error) do
      evaluate(active_workers: 0)
    end
    assert_includes error.message, "active workers"

    error = assert_raises(ProductionWorkerExpansionPolicy::Error) do
      evaluate(maximum_incremental_cost_per_hour_saved_usd: -1)
    end
    assert_includes error.message, "maximum incremental cost per hour saved"
  end

  private

  def evaluate(overrides = {})
    @policy.evaluate(
      **{
        remaining_jobs: 208,
        active_workers: 1,
        observed_seconds_per_job: 115,
        estimated_bootstrap_seconds: 300,
        candidate_worker_hourly_usd: 1.09,
        current_fleet_hourly_usd: 1.09,
        desired_worker_ceiling: 10,
        minimum_time_saved_seconds: 60,
        maximum_incremental_cost_per_hour_saved_usd: 10.0
      }.merge(overrides)
    )
  end
end
