# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require "digest"
require_relative "../lib/production_worker_expansion_controller"

class ProductionWorkerExpansionControllerTest < Minitest::Test
  DIGEST = "a" * 64

  class FakeRpofClient
    attr_reader :fulfill_requests, :admissions, :closes, :scales
    attr_accessor :after_fulfill

    def initialize
      @fulfill_requests = []
      @admissions = []
      @closes = []
      @scales = []
      @after_fulfill = nil
    end

    def fulfill_execution_pool(request:, dry_run:, assume_yes:, stream_output:)
      @fulfill_requests << request
      target = request.dig("capacity", "desired_workers")
      @after_fulfill&.call(target)
      result = {
        "contract_version" => "afio-rpof-execution-pool-fulfill-result/v0.1",
        "ready" => true,
        "status" => "ready",
        "plan_sha256" => request.fetch("plan_sha256"),
        "pool_id" => request.fetch("pool_id"),
        "execution_handle" => "ep-qwen35",
        "worker_indices" => (1..target).to_a
      }
      [result, 0, "", ""]
    end

    def admit_dispatch_worker(fleet_key:, output_dir:, worker_index:)
      @admissions << [fleet_key, output_dir, worker_index]
      "admitted"
    end

    def close_dispatch_admissions(fleet_key:, output_dir:)
      @closes << [fleet_key, output_dir]
      "closed"
    end

    def scale_fleet(fleet_key:, worker_count:, max_hourly_usd:, max_total_hourly_usd:)
      @scales << [fleet_key, worker_count, max_hourly_usd, max_total_hourly_usd]
      "scaled"
    end
  end

  def setup
    @root = Dir.mktmpdir("afio-expansion-controller-")
    @output = File.join(@root, "output", "campaign")
    FileUtils.mkdir_p(@output)
    File.write(
      File.join(@output, "admission-control.json"),
      JSON.generate("status" => "open", "fleet_key" => "ep-qwen35")
    )
    @plan_path = File.join(@root, "plan.json")
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
    @client = FakeRpofClient.new
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_uses_live_unclaimed_job_evidence_to_prepare_and_admit_one_worker_then_stops_on_cost_policy
    write_job(1, "completed", 100)
    write_job(2, "completed", 100)
    controller = build_controller

    result = controller.run(
      plan_path: @plan_path,
      pool_id: "qwen35",
      execution_handle: "ep-qwen35",
      output_dir: @output,
      initial_worker_indices: [1],
      initial_fulfillment_seconds: 100,
      dispatch_alive: -> { true }
    )

    assert_equal "cost_per_hour_saved_exceeds_limit", result.fetch("reason")
    assert_equal [1, 2], result.fetch("worker_indices")
    assert_equal [2], @client.fulfill_requests.map { |request| request.dig("capacity", "desired_workers") }
    request_budget = @client.fulfill_requests.fetch(0).fetch("budget")
    assert_equal "budget-fixture", request_budget.fetch("budget_id")
    assert_equal Digest::SHA256.file(@plan_path).hexdigest, request_budget.fetch("plan_sha256")
    assert_equal [["ep-qwen35", @output, 2]], @client.admissions
    assert_equal 1, @client.closes.length
    assert_empty @client.scales

    events = expansion_events
    assert events.all? { |event| event.fetch("budget") == budget_identity }
    first_decision = events.find { |event| event["event"] == "decision" }
    assert_equal 18, first_decision.dig("observation", "unclaimed_jobs")
    assert_in_delta 100.0, first_decision.dig("observation", "observed_seconds_per_job"), 0.001
    assert_equal "budgeted_per_worker_rate_from_pool_ceiling", first_decision.dig("rate_estimate", "source")
    assert events.any? { |event| event["event"] == "preparing" && event["target_worker"] == 2 }
    assert events.any? { |event| event["event"] == "prepared" && event["target_worker"] == 2 }
    assert events.any? { |event| event["event"] == "admitted" && event["target_worker"] == 2 }
  end

  def test_grows_to_frozen_minimum_after_dispatch_starts_even_without_completed_timings
    document = plan
    document.dig("pools", 0, "capacity")["desired_workers"] = 2
    document.dig("pools", 0, "capacity")["minimum_workers"] = 2
    File.write(@plan_path, JSON.pretty_generate(document) + "\n")
    write_job(1, "running")
    controller = build_controller

    result = controller.run(
      plan_path: @plan_path,
      pool_id: "qwen35",
      execution_handle: "ep-qwen35",
      output_dir: @output,
      initial_worker_indices: [1],
      initial_fulfillment_seconds: 100,
      dispatch_alive: -> { true }
    )

    assert_equal "worker_ceiling_reached", result.fetch("reason")
    assert_equal [1, 2], result.fetch("worker_indices")
    assert_equal [2], @client.fulfill_requests.map { |request| request.dig("capacity", "desired_workers") }
    assert_equal [["ep-qwen35", @output, 2]], @client.admissions
    assert_equal 1, @client.closes.length
    assert_equal "below_minimum_capacity", expansion_events.find { |event| event["event"] == "decision" }.fetch("reason")
  end

  def test_rolls_back_prepared_tail_when_dispatch_finishes_before_admission
    write_job(1, "completed", 100)
    write_job(2, "completed", 100)
    alive = true
    @client.after_fulfill = ->(_target) { alive = false }
    controller = build_controller(maximum_incremental_cost_per_hour_saved_usd: 10.0)

    result = controller.run(
      plan_path: @plan_path,
      pool_id: "qwen35",
      execution_handle: "ep-qwen35",
      output_dir: @output,
      initial_worker_indices: [1],
      initial_fulfillment_seconds: 100,
      dispatch_alive: -> { alive }
    )

    assert_equal "dispatch_finished_before_admission", result.fetch("reason")
    assert_empty @client.admissions
    assert_equal [["ep-qwen35", 1, 3.0, 6.0]], @client.scales
    assert expansion_events.any? { |event| event["event"] == "rollback" && event["target_worker"] == 2 }
  end

  def test_does_not_expand_without_enough_completed_timing_observations_above_minimum
    write_job(1, "completed", 100)
    alive_checks = 0
    controller = build_controller(
      sleeper: ->(_seconds) { alive_checks += 1 },
      minimum_completed_observations: 2
    )

    result = controller.run(
      plan_path: @plan_path,
      pool_id: "qwen35",
      execution_handle: "ep-qwen35",
      output_dir: @output,
      initial_worker_indices: [1],
      initial_fulfillment_seconds: 100,
      dispatch_alive: -> { alive_checks < 1 }
    )

    assert_equal "dispatch_finished", result.fetch("reason")
    assert_empty @client.fulfill_requests
    assert_empty @client.admissions
  end

  def test_resume_recovers_admitted_prefix_and_prior_bootstrap_samples_before_requesting_next_worker
    document = plan
    document.dig("pools", 0, "capacity")["desired_workers"] = 4
    document.dig("pools", 0, "capacity")["max_pool_hourly_usd"] = 4.0
    File.write(@plan_path, JSON.pretty_generate(document) + "\n")
    File.write(File.join(@output, "manifest.json"), JSON.generate("worker_indices" => [1]))
    File.write(
      File.join(@output, "worker-admissions.jsonl"),
      [2, 3].map { |index| JSON.generate("status" => "admitted", "worker_index" => index) }.join("\n") + "\n"
    )
    File.write(
      File.join(@output, ProductionWorkerExpansionController::EVIDENCE_FILE),
      [
        JSON.generate("event" => "controller_start", "budget" => budget_identity, "starter_fulfillment_seconds" => 100),
        JSON.generate("event" => "admitted", "budget" => budget_identity, "target_worker" => 2, "preparation_elapsed_seconds" => 120),
        JSON.generate("event" => "admitted", "budget" => budget_identity, "target_worker" => 3, "preparation_elapsed_seconds" => 130)
      ].join("\n") + "\n"
    )
    write_job(1, "completed", 100)
    write_job(2, "completed", 100)
    controller = build_controller(maximum_incremental_cost_per_hour_saved_usd: 100.0)

    result = controller.run(
      plan_path: @plan_path,
      pool_id: "qwen35",
      execution_handle: "ep-qwen35",
      output_dir: @output,
      initial_worker_indices: [1],
      initial_fulfillment_seconds: 1,
      dispatch_alive: -> { true }
    )

    assert_equal "worker_ceiling_reached", result.fetch("reason")
    assert_equal [1, 2, 3, 4], result.fetch("worker_indices")
    assert_equal [4], @client.fulfill_requests.map { |request| request.dig("capacity", "desired_workers") }
    assert_equal [["ep-qwen35", @output, 4]], @client.admissions
    resume = expansion_events.find { |event| event["event"] == "controller_resume" }
    assert_equal [1, 2, 3], resume.fetch("active_worker_indices")
    assert_equal 3, resume.fetch("recovered_bootstrap_samples")
  end

  def test_resume_rejects_worker_expansion_evidence_from_different_budget
    write_job(1, "completed", 100)
    write_job(2, "completed", 100)
    File.write(
      File.join(@output, ProductionWorkerExpansionController::EVIDENCE_FILE),
      JSON.generate(
        "event" => "controller_start",
        "budget" => { "budget_id" => "other-budget", "plan_sha256" => "f" * 64 },
        "starter_fulfillment_seconds" => 100
      ) + "\n"
    )

    error = assert_raises(ProductionWorkerExpansionController::Error) do
      build_controller.run(
        plan_path: @plan_path,
        pool_id: "qwen35",
        execution_handle: "ep-qwen35",
        output_dir: @output,
        initial_worker_indices: [1],
        initial_fulfillment_seconds: 100,
        dispatch_alive: -> { true }
      )
    end
    assert_includes error.message, "budget identity does not match frozen parent budget"
    assert_empty @client.fulfill_requests
  end

  private

  def build_controller(**overrides)
    clock = 0.0
    ProductionWorkerExpansionController.new(
      **{
        root: @root,
        rpof_client: @client,
        out: StringIO.new,
        sleeper: ->(_seconds) {},
        poll_seconds: 0.01,
        minimum_completed_observations: 2,
        minimum_time_saved_seconds: 60,
        maximum_incremental_cost_per_hour_saved_usd: 1.0,
        monotonic_clock: -> { clock += 100.0 }
      }.merge(overrides)
    )
  end

  def write_job(index, status, elapsed = nil)
    dir = File.join(@output, "jobs", format("production-%04d", index))
    FileUtils.mkdir_p(dir)
    document = { "status" => status }
    document["elapsed_seconds"] = elapsed if elapsed
    File.write(File.join(dir, "metadata.json"), JSON.generate(document))
  end

  def budget_identity
    document = JSON.parse(File.read(@plan_path))
    {
      "budget_id" => document.dig("budget", "budget_id"),
      "plan_sha256" => Digest::SHA256.file(@plan_path).hexdigest
    }
  end

  def expansion_events
    File.readlines(File.join(@output, ProductionWorkerExpansionController::EVIDENCE_FILE), chomp: true)
        .map { |line| JSON.parse(line) }
  end

  def plan
    {
      "contract_version" => "afio-production-execution-pool-plan/v0.1",
      "capacity" => { "max_total_hourly_usd" => 6.0 },
      "budget" => {
        "contract_version" => "afio-production-burst-budget/v0.1",
        "budget_id" => "budget-fixture",
        "max_cumulative_compute_usd" => 5.0,
        "max_runtime_seconds" => 2700.0,
        "guardian_poll_seconds" => 5.0,
        "orchestrator_heartbeat_timeout_seconds" => 30.0,
        "teardown_reserve_seconds" => 60.0
      },
      "pools" => [{
        "pool_id" => "qwen35",
        "requirements" => {
          "ollama_model" => "qwen3.6:35b-a3b",
          "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
          "expected_digest" => DIGEST,
          "required_context_length" => 131_072,
          "require_fully_gpu_resident" => true
        },
        "capacity" => {
          "desired_workers" => 3,
          "minimum_workers" => 1,
          "max_pool_hourly_usd" => 3.0
        },
        "job_count" => 20,
        "manifests" => []
      }]
    }
  end
end
