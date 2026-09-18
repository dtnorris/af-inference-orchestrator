# frozen_string_literal: true

class ProductionWorkerExpansionPolicy
  class Error < StandardError; end

  def evaluate(remaining_jobs:, active_workers:, observed_seconds_per_job:, estimated_bootstrap_seconds:,
               candidate_worker_hourly_usd:, current_fleet_hourly_usd:, desired_worker_ceiling:,
               minimum_time_saved_seconds:, maximum_incremental_cost_per_hour_saved_usd:)
    jobs = nonnegative_integer(remaining_jobs, "remaining jobs")
    workers = positive_integer(active_workers, "active workers")
    ceiling = positive_integer(desired_worker_ceiling, "desired worker ceiling")
    seconds_per_job = positive_float(observed_seconds_per_job, "observed seconds per job")
    bootstrap_seconds = nonnegative_float(estimated_bootstrap_seconds, "estimated bootstrap seconds")
    candidate_rate = nonnegative_float(candidate_worker_hourly_usd, "candidate worker hourly cost")
    fleet_rate = nonnegative_float(current_fleet_hourly_usd, "current fleet hourly cost")
    minimum_saved = nonnegative_float(minimum_time_saved_seconds, "minimum time saved seconds")
    maximum_cost_per_hour_saved = nonnegative_float(
      maximum_incremental_cost_per_hour_saved_usd,
      "maximum incremental cost per hour saved"
    )

    baseline = simulate_schedule(
      remaining_jobs: jobs,
      active_workers: workers,
      seconds_per_job:
    )
    expanded = simulate_schedule(
      remaining_jobs: jobs,
      active_workers: workers,
      seconds_per_job:,
      candidate_ready_seconds: bootstrap_seconds
    )

    finish_without = baseline.fetch(:finish_seconds)
    finish_with = expanded.fetch(:finish_seconds)
    time_saved = [finish_without - finish_with, 0.0].max
    baseline_cost = fleet_rate * finish_without / 3600.0
    expanded_cost = (fleet_rate + candidate_rate) * finish_with / 3600.0
    incremental_cost = expanded_cost - baseline_cost
    cost_per_hour_saved = if time_saved.positive?
                            incremental_cost / (time_saved / 3600.0)
                          end

    reason = if jobs.zero?
               "no_remaining_work"
             elsif workers >= ceiling
               "worker_ceiling_reached"
             elsif expanded.fetch(:candidate_jobs).zero?
               "candidate_would_not_receive_work"
             elsif !time_saved.positive?
               "no_wall_clock_gain"
             elsif time_saved < minimum_saved
               "insufficient_time_saved"
             elsif cost_per_hour_saved > maximum_cost_per_hour_saved
               "cost_per_hour_saved_exceeds_limit"
             else
               "expand"
             end

    {
      "expand" => reason == "expand",
      "reason" => reason,
      "inputs" => {
        "remaining_jobs" => jobs,
        "active_workers" => workers,
        "desired_worker_ceiling" => ceiling,
        "observed_seconds_per_job" => seconds_per_job,
        "estimated_bootstrap_seconds" => bootstrap_seconds,
        "candidate_worker_hourly_usd" => candidate_rate,
        "current_fleet_hourly_usd" => fleet_rate,
        "minimum_time_saved_seconds" => minimum_saved,
        "maximum_incremental_cost_per_hour_saved_usd" => maximum_cost_per_hour_saved
      },
      "estimates" => {
        "finish_without_expansion_seconds" => finish_without,
        "finish_with_expansion_seconds" => finish_with,
        "time_saved_seconds" => time_saved,
        "candidate_jobs" => expanded.fetch(:candidate_jobs),
        "candidate_productive_seconds" => expanded.fetch(:candidate_jobs) * seconds_per_job,
        "baseline_cost_usd" => baseline_cost,
        "expanded_cost_usd" => expanded_cost,
        "incremental_cost_usd" => incremental_cost,
        "incremental_cost_per_hour_saved_usd" => cost_per_hour_saved
      }
    }
  end

  private

  def simulate_schedule(remaining_jobs:, active_workers:, seconds_per_job:, candidate_ready_seconds: nil)
    slots = Array.new(active_workers) do |index|
      { available_at: 0.0, order: index, candidate: false }
    end
    if candidate_ready_seconds
      slots << {
        available_at: candidate_ready_seconds,
        order: active_workers,
        candidate: true
      }
    end

    finish_seconds = 0.0
    candidate_jobs = 0
    remaining_jobs.times do
      slot = slots.min_by { |row| [row.fetch(:available_at), row.fetch(:order)] }
      slot[:available_at] += seconds_per_job
      finish_seconds = [finish_seconds, slot.fetch(:available_at)].max
      candidate_jobs += 1 if slot.fetch(:candidate)
    end

    { finish_seconds:, candidate_jobs: }
  end

  def positive_integer(value, label)
    integer = Integer(value)
    raise ArgumentError unless integer.positive?

    integer
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a positive integer"
  end

  def nonnegative_integer(value, label)
    integer = Integer(value)
    raise ArgumentError if integer.negative?

    integer
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a nonnegative integer"
  end

  def positive_float(value, label)
    number = Float(value)
    raise ArgumentError unless number.positive? && number.finite?

    number
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a positive finite number"
  end

  def nonnegative_float(value, label)
    number = Float(value)
    raise ArgumentError unless number >= 0.0 && number.finite?

    number
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a nonnegative finite number"
  end
end
