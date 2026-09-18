# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "time"
require_relative "production_worker_expansion_policy"
require_relative "local_model_evaluation/production_pool_fulfillment"
require_relative "local_model_evaluation/rpof_client"

class ProductionWorkerExpansionController
  EVIDENCE_FILE = "worker-expansion.jsonl"
  DEFAULT_POLL_SECONDS = 1.0
  DEFAULT_MINIMUM_COMPLETED_OBSERVATIONS = 2
  DEFAULT_MINIMUM_TIME_SAVED_SECONDS = 60.0
  DEFAULT_MAXIMUM_INCREMENTAL_COST_PER_HOUR_SAVED_USD = 1.0

  Error = Class.new(StandardError)

  def initialize(root:, rpof_client:, policy: ProductionWorkerExpansionPolicy.new,
                 out: $stdout, sleeper: nil, monotonic_clock: nil, wall_clock: nil,
                 poll_seconds: DEFAULT_POLL_SECONDS,
                 minimum_completed_observations: DEFAULT_MINIMUM_COMPLETED_OBSERVATIONS,
                 minimum_time_saved_seconds: DEFAULT_MINIMUM_TIME_SAVED_SECONDS,
                 maximum_incremental_cost_per_hour_saved_usd: DEFAULT_MAXIMUM_INCREMENTAL_COST_PER_HOUR_SAVED_USD)
    @root = File.expand_path(root)
    @rpof_client = rpof_client
    @policy = policy
    @out = out
    @sleeper = sleeper || ->(seconds) { sleep seconds }
    @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @wall_clock = wall_clock || -> { Time.now.utc }
    @poll_seconds = positive_float(poll_seconds, "poll seconds")
    @minimum_completed_observations = positive_integer(
      minimum_completed_observations,
      "minimum completed observations"
    )
    @minimum_time_saved_seconds = nonnegative_float(
      minimum_time_saved_seconds,
      "minimum time saved seconds"
    )
    @maximum_incremental_cost_per_hour_saved_usd = nonnegative_float(
      maximum_incremental_cost_per_hour_saved_usd,
      "maximum incremental cost per hour saved"
    )
  end

  def run(plan_path:, pool_id:, execution_handle:, output_dir:, initial_worker_indices:,
          initial_fulfillment_seconds:, dispatch_alive:)
    plan_path = within_root(plan_path)
    plan_bytes = File.binread(plan_path)
    plan = JSON.parse(plan_bytes)
    pool = Array(plan.fetch("pools")).find { |row| row.fetch("pool_id").to_s == pool_id.to_s }
    raise Error, "execution pool #{pool_id.inspect} is not present in expansion plan" unless pool

    output = File.expand_path(output_dir)
    initial = normalize_contiguous_worker_prefix(initial_worker_indices, "initial worker indices")
    active = recover_active_worker_prefix(output, initial)
    desired = positive_integer(pool.dig("capacity", "desired_workers"), "desired workers")
    minimum = positive_integer(pool.dig("capacity", "minimum_workers"), "minimum workers")
    raise Error, "minimum workers cannot exceed desired workers" if minimum > desired
    raise Error, "recovered workers exceed desired worker ceiling" if active.length > desired

    initial_seconds = positive_float(initial_fulfillment_seconds, "initial fulfillment seconds")
    return result("dispatch_finished", active) unless wait_for_dispatch_open(output, execution_handle, dispatch_alive)

    bootstrap_samples = recovered_bootstrap_samples(output)
    if bootstrap_samples.empty?
      bootstrap_samples << initial_seconds
      append_event(
        output,
        pool_id,
        "controller_start",
        "starter_fulfillment_observed",
        active,
        starter_fulfillment_seconds: initial_seconds
      )
    else
      append_event(
        output,
        pool_id,
        "controller_resume",
        "resume_prefix_recovered",
        active,
        recovered_bootstrap_samples: bootstrap_samples.length
      )
    end

    max_pool_hourly = positive_float(pool.dig("capacity", "max_pool_hourly_usd"), "max pool hourly cost")
    max_total_hourly = positive_float(plan.dig("capacity", "max_total_hourly_usd"), "max total hourly cost")
    candidate_rate_estimate = max_pool_hourly / desired
    job_count = positive_integer(pool.fetch("job_count"), "job count")

    loop do
      return result("dispatch_finished", active) unless dispatch_alive.call

      if active.length >= desired
        append_event(output, pool_id, "stop", "worker_ceiling_reached", active)
        return result("worker_ceiling_reached", active)
      end

      observation = workload_observation(output, job_count)
      if observation.fetch("observed_jobs").zero?
        @sleeper.call(@poll_seconds)
        next
      end

      if observation.fetch("unclaimed_jobs").zero?
        close_admissions(execution_handle, output)
        append_event(output, pool_id, "stop", "no_unclaimed_work", active, observation:)
        return result("no_unclaimed_work", active)
      end

      decision = if active.length < minimum
                   {
                     "expand" => true,
                     "reason" => "below_minimum_capacity",
                     "inputs" => {
                       "active_workers" => active.length,
                       "minimum_workers" => minimum,
                       "desired_worker_ceiling" => desired
                     },
                     "estimates" => {}
                   }
                 else
                   if observation.fetch("completed_observations") < @minimum_completed_observations
                     @sleeper.call(@poll_seconds)
                     next
                   end

                   bootstrap_estimate = bootstrap_samples.sum / bootstrap_samples.length
                   @policy.evaluate(
                     remaining_jobs: observation.fetch("unclaimed_jobs"),
                     active_workers: active.length,
                     observed_seconds_per_job: observation.fetch("observed_seconds_per_job"),
                     estimated_bootstrap_seconds: bootstrap_estimate,
                     candidate_worker_hourly_usd: candidate_rate_estimate,
                     current_fleet_hourly_usd: candidate_rate_estimate * active.length,
                     desired_worker_ceiling: desired,
                     minimum_time_saved_seconds: @minimum_time_saved_seconds,
                     maximum_incremental_cost_per_hour_saved_usd: @maximum_incremental_cost_per_hour_saved_usd
                   )
                 end

      bootstrap_estimate = bootstrap_samples.sum / bootstrap_samples.length
      append_event(
        output,
        pool_id,
        "decision",
        decision.fetch("reason"),
        active,
        observation:,
        bootstrap_estimate_seconds: bootstrap_estimate,
        rate_estimate: {
          "source" => "budgeted_per_worker_rate_from_pool_ceiling",
          "candidate_worker_hourly_usd" => candidate_rate_estimate,
          "current_fleet_hourly_usd" => candidate_rate_estimate * active.length
        },
        decision:
      )

      unless decision.fetch("expand")
        close_admissions(execution_handle, output)
        return result(decision.fetch("reason"), active)
      end

      target = active.length + 1
      append_event(output, pool_id, "preparing", decision.fetch("reason"), active, target_worker: target)
      started = @monotonic_clock.call
      fulfillment = LocalModelEvaluation::ProductionPoolFulfillment.new(
        rpof_client: @rpof_client,
        paid_lock_path: File.join(@root, "output", ".rpof-paid-fulfillment.lock")
      ).fulfill(
        plan:,
        plan_bytes:,
        plan_path: relative_path(plan_path),
        pool:,
        dry_run: false,
        assume_yes: true,
        stream_output: false,
        target_workers: target
      )
      elapsed = [@monotonic_clock.call - started, 0.001].max
      prepared = fulfillment.handoff.fetch("result")
      prepared_indices = normalize_contiguous_worker_prefix(
        prepared.fetch("worker_indices"),
        "prepared execution workers"
      )
      expected_indices = (1..target).to_a
      unless fulfillment.rpof_exit.zero? && prepared["ready"] == true && prepared_indices == expected_indices &&
             prepared["execution_handle"].to_s == execution_handle.to_s
        append_event(output, pool_id, "stop", "worker_preparation_failed", active, target_worker: target)
        close_admissions(execution_handle, output)
        return result("worker_preparation_failed", active)
      end
      append_event(
        output,
        pool_id,
        "prepared",
        decision.fetch("reason"),
        active,
        target_worker: target,
        preparation_elapsed_seconds: elapsed
      )

      unless dispatch_alive.call
        rollback_tail(execution_handle, active.length, max_pool_hourly, max_total_hourly)
        append_event(output, pool_id, "rollback", "dispatch_finished_before_admission", active, target_worker: target)
        return result("dispatch_finished_before_admission", active)
      end

      begin
        @rpof_client.admit_dispatch_worker(
          fleet_key: execution_handle,
          output_dir: output,
          worker_index: target
        )
      rescue LocalModelEvaluation::RpofClient::Error => e
        rollback_tail(execution_handle, active.length, max_pool_hourly, max_total_hourly)
        append_event(
          output,
          pool_id,
          "rollback",
          "dispatch_admission_failed",
          active,
          target_worker: target,
          detail: e.message
        )
        raise Error, "prepared burst_#{target} could not be admitted and was rolled back: #{e.message}"
      end

      active = expected_indices
      bootstrap_samples << elapsed
      append_event(
        output,
        pool_id,
        "admitted",
        decision.fetch("reason"),
        active,
        target_worker: target,
        preparation_elapsed_seconds: elapsed
      )
      @out.puts format(
        "Adaptive expansion: %s admitted burst_%d after %.1fs preparation; %d/%d workers active.",
        pool_id,
        target,
        elapsed,
        active.length,
        desired
      )
      @out.flush if @out.respond_to?(:flush)

      if active.length >= desired
        close_admissions(execution_handle, output)
        append_event(output, pool_id, "stop", "worker_ceiling_reached", active)
        return result("worker_ceiling_reached", active)
      end
    end
  rescue JSON::ParserError, KeyError, ArgumentError, TypeError, RuntimeError, SystemCallError,
         LocalModelEvaluation::RpofClient::Error, ProductionWorkerExpansionPolicy::Error => e
    raise Error, e.message
  end

  private

  def wait_for_dispatch_open(output_dir, execution_handle, dispatch_alive)
    path = File.join(output_dir, "admission-control.json")
    loop do
      return false unless dispatch_alive.call

      if File.file?(path)
        document = JSON.parse(File.read(path))
        if document["status"].to_s == "open"
          unless document["fleet_key"].to_s == execution_handle.to_s
            raise Error,
                  "dispatch admission control belongs to #{document['fleet_key'].inspect}, expected #{execution_handle.inspect}"
          end
          return true
        end
      end
      @sleeper.call(@poll_seconds)
    end
  rescue JSON::ParserError, SystemCallError => e
    raise Error, "could not read dispatch admission control: #{e.message}"
  end

  def recover_active_worker_prefix(output_dir, fallback)
    manifest_path = File.join(output_dir, "manifest.json")
    return fallback unless File.file?(manifest_path)

    manifest = JSON.parse(File.read(manifest_path))
    initial = normalize_contiguous_worker_prefix(
      manifest.fetch("worker_indices"),
      "existing dispatch initial workers"
    )
    unless initial == fallback
      raise Error,
            "existing dispatch initial workers #{initial.inspect} do not match requested #{fallback.inspect}"
    end

    indices = initial.dup
    admissions_path = File.join(output_dir, "worker-admissions.jsonl")
    if File.file?(admissions_path)
      File.readlines(admissions_path, chomp: true).reject(&:empty?).each_with_index do |line, offset|
        event = JSON.parse(line)
        next unless event["status"].to_s == "admitted"
        indices << Integer(event.fetch("worker_index"))
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
        raise Error, "invalid worker admission evidence line #{offset + 1}: #{e.message}"
      end
    end
    normalize_contiguous_worker_prefix(indices, "recovered dispatch worker prefix")
  rescue JSON::ParserError, KeyError, SystemCallError => e
    raise Error, "could not recover dispatch worker prefix: #{e.message}"
  end

  def recovered_bootstrap_samples(output_dir)
    path = File.join(output_dir, EVIDENCE_FILE)
    return [] unless File.file?(path)

    samples = []
    File.readlines(path, chomp: true).reject(&:empty?).each_with_index do |line, offset|
      event = JSON.parse(line)
      value = case event["event"].to_s
              when "controller_start" then event["starter_fulfillment_seconds"]
              when "admitted" then event["preparation_elapsed_seconds"]
              end
      next if value.nil?
      number = Float(value)
      samples << number if number.positive? && number.finite?
    rescue JSON::ParserError, ArgumentError, TypeError => e
      raise Error, "invalid worker expansion evidence line #{offset + 1}: #{e.message}"
    end
    samples
  end

  def workload_observation(output_dir, job_count)
    completed_elapsed = []
    terminal_count = 0
    observed_jobs = 0
    Dir.glob(File.join(output_dir, "jobs", "*", "metadata.json")).sort.each do |path|
      metadata = JSON.parse(File.read(path))
      status = metadata["status"].to_s
      next if status.empty?

      observed_jobs += 1
      next unless %w[completed failed].include?(status)

      terminal_count += 1
      if status == "completed"
        elapsed = Float(metadata["elapsed_seconds"])
        completed_elapsed << elapsed if elapsed.positive? && elapsed.finite?
      end
    rescue JSON::ParserError, ArgumentError, TypeError
      next
    end
    raise Error, "dispatch evidence reports more observed jobs than the frozen pool" if observed_jobs > job_count

    observed = completed_elapsed.empty? ? nil : completed_elapsed.sum / completed_elapsed.length
    {
      "job_count" => job_count,
      "observed_jobs" => observed_jobs,
      "terminal_jobs" => terminal_count,
      "unclaimed_jobs" => job_count - observed_jobs,
      "completed_observations" => completed_elapsed.length,
      "observed_seconds_per_job" => observed
    }
  end

  def close_admissions(execution_handle, output_dir)
    @rpof_client.close_dispatch_admissions(
      fleet_key: execution_handle,
      output_dir:
    )
  rescue LocalModelEvaluation::RpofClient::Error => e
    raise Error, "could not close dynamic worker admissions: #{e.message}"
  end

  def rollback_tail(execution_handle, worker_count, max_pool_hourly, max_total_hourly)
    @rpof_client.scale_fleet(
      fleet_key: execution_handle,
      worker_count:,
      max_hourly_usd: max_pool_hourly,
      max_total_hourly_usd: max_total_hourly
    )
  rescue LocalModelEvaluation::RpofClient::Error => e
    raise Error, "could not roll back unused prepared worker: #{e.message}"
  end

  def append_event(output_dir, pool_id, event, reason, active, **extra)
    FileUtils.mkdir_p(output_dir)
    record = {
      "schema_version" => 1,
      "at_utc" => utc_now.iso8601,
      "pool_id" => pool_id.to_s,
      "event" => event,
      "reason" => reason,
      "active_worker_indices" => active
    }.merge(extra.transform_keys(&:to_s))
    File.open(File.join(output_dir, EVIDENCE_FILE), "a", 0o600) do |file|
      file.write(JSON.generate(record) + "\n")
      file.flush
      file.fsync
    end
  end

  def result(reason, active)
    {
      "status" => "stopped",
      "reason" => reason,
      "worker_indices" => active
    }
  end

  def normalize_contiguous_worker_prefix(values, label)
    indices = Array(values).map { |value| Integer(value) }.uniq.sort
    raise Error, "#{label} cannot be empty" if indices.empty?
    expected = (1..indices.length).to_a
    raise Error, "#{label} must be a contiguous prefix #{expected.inspect}, got #{indices.inspect}" unless indices == expected
    indices
  rescue ArgumentError, TypeError
    raise Error, "#{label} must contain positive integer worker indices"
  end

  def within_root(path)
    expanded = File.expand_path(path.to_s, @root)
    prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
    raise Error, "expansion plan escapes repository root: #{expanded}" unless expanded == @root || expanded.start_with?(prefix)
    expanded
  end

  def relative_path(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
  rescue ArgumentError
    path.to_s
  end

  def positive_integer(value, label)
    integer = Integer(value)
    raise ArgumentError unless integer.positive?
    integer
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a positive integer"
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

  def utc_now
    value = @wall_clock.call
    value = Time.parse(value.to_s) unless value.is_a?(Time)
    value.utc
  rescue ArgumentError
    raise Error, "expansion clock returned invalid time: #{value.inspect}"
  end
end
