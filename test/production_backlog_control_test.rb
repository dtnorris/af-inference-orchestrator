# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_control"

class ProductionBacklogControlTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("production-backlog-control-test")
    @queue_rel = "production_backlog/production-backlog-037"
    @queue_dir = File.join(@root, @queue_rel)
    FileUtils.mkdir_p(@queue_dir)
    FileUtils.mkdir_p(File.join(@root, "experiments", "production-backlog-037"))
    @rows = []
    6.times do |index|
      id = format("ADV-%04d", index + 1)
      manifest_rel = "experiments/production-backlog-037/case-#{index + 1}.yml"
      @rows << {
        "case_index" => index + 1,
        "pack_index" => 1,
        "pack_case_index" => index + 1,
        "adventure_index" => index + 1,
        "adventure_id" => id,
        "adventure_title" => "Adventure #{index + 1}",
        "source_book" => "Book",
        "publisher" => "Publisher",
        "page_count" => [5, 8, 12, 20, 40, 10][index],
        "dimension" => index == 5 ? "Social Interaction Emphasis" : "Combat Emphasis",
        "profile" => "production-base",
        "model_alias" => "qwen",
        "runtime_key" => "base",
        "manifest_path" => manifest_rel
      }
      File.write(File.join(@root, manifest_rel), YAML.dump("name" => "case-#{index + 1}"))
    end
    CSV.open(File.join(@queue_dir, "case_index.csv"), "w") do |csv|
      csv << @rows.first.keys
      @rows.each { |row| csv << row.values }
    end
    File.write(File.join(@queue_dir, "run_order.txt"), @rows.map { |row| row.fetch("manifest_path") }.join("\n") + "\n")
    File.write(
      File.join(@queue_dir, "snapshot.yml"),
      YAML.dump("queue" => "production-backlog-037", "expected_calls" => 6, "local_model_eval_commit" => "a" * 40)
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_metadata(case_number, status:, elapsed_seconds: nil, started_at: nil, completed_at: nil)
    dir = File.join(@root, "output", "case-#{case_number}", "runs", "job")
    FileUtils.mkdir_p(dir)
    data = { "status" => status }
    data["elapsed_seconds"] = elapsed_seconds if elapsed_seconds
    data["started_at"] = started_at if started_at
    data["completed_at"] = completed_at if completed_at
    File.write(File.join(dir, "metadata.json"), JSON.dump(data))
  end


  GIT_IDENTITY = {
    "GIT_AUTHOR_NAME" => "Fixture",
    "GIT_AUTHOR_EMAIL" => "fixture@example.com",
    "GIT_COMMITTER_NAME" => "Fixture",
    "GIT_COMMITTER_EMAIL" => "fixture@example.com"
  }.freeze

  def git!(*args, env: {})
    out, err, status = Open3.capture3(GIT_IDENTITY.merge(env), "git", "-C", @root, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
    out.strip
  end

  def initialize_git_repo!
    git!("init", "-q")
    git!("commit", "--allow-empty", "-qm", "queue provenance base")
    queue_commit = git!("rev-parse", "HEAD")

    File.write(File.join(@root, "tracked.txt"), "clean\n")
    snapshot = YAML.safe_load_file(File.join(@queue_dir, "snapshot.yml"))
    snapshot["local_model_eval_commit"] = queue_commit
    File.write(File.join(@queue_dir, "snapshot.yml"), YAML.dump(snapshot))
    git!("add", ".")
    git!("commit", "-qm", "fixture checkout")

    { "queue_commit" => queue_commit, "head" => git!("rev-parse", "HEAD") }
  end

  def test_queue_rejects_nonfinite_or_mismatched_scope
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    assert_equal 6, queue.expected_calls

    File.write(File.join(@queue_dir, "run_order.txt"), @rows.take(5).map { |row| row.fetch("manifest_path") }.join("\n") + "\n")
    error = assert_raises(ProductionBacklogControl::Error) do
      ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    end
    assert_match(/run_order count changed/, error.message)
  end

  def test_status_preserves_sticky_terminal_failures
    4.times { |index| write_metadata(index + 1, status: "complete", elapsed_seconds: 60 + index * 10, completed_at: Time.now.iso8601) }
    write_metadata(5, status: "failed", elapsed_seconds: 5, completed_at: Time.now.iso8601)
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)

    assert_equal({"complete" => 4, "failed" => 1, "pending" => 1}, queue.counts)
    assert_equal 4, queue.timing_samples.length
    refute_includes queue.timing_samples.map { |sample| sample.fetch("index") }, 5
  end

  def test_eta_uses_completed_measurements_and_remaining_composition
    [50, 70, 95, 140, 260].each_with_index do |elapsed, index|
      write_metadata(index + 1, status: "complete", elapsed_seconds: elapsed, completed_at: Time.now.iso8601)
    end
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    eta = ProductionBacklogControl::EtaEstimator.new(records: queue.records, samples: queue.timing_samples).estimate

    refute_nil eta
    assert_equal 5, eta.fetch("samples")
    assert_equal 1, eta.fetch("targets")
    assert_equal({"same model" => 1}, eta.fetch("tiers"))
    assert_operator eta.fetch("seconds"), :>, 0
  end

  def test_eta_withholds_estimate_until_enough_completed_timings_exist
    4.times { |index| write_metadata(index + 1, status: "complete", elapsed_seconds: 60, completed_at: Time.now.iso8601) }
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    assert_nil ProductionBacklogControl::EtaEstimator.new(records: queue.records, samples: queue.timing_samples).estimate
  end

  def test_eta_refuses_unknown_metadata_state
    5.times { |index| write_metadata(index + 1, status: "complete", elapsed_seconds: 60, completed_at: Time.now.iso8601) }
    dir = File.join(@root, "output", "case-6", "runs", "job")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "metadata.json"), "{not-json")
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)

    assert_equal 1, queue.counts.fetch("unknown")
    assert_nil ProductionBacklogControl::EtaEstimator.new(records: queue.records, samples: queue.timing_samples).estimate
  end

  def test_pause_reuses_existing_graceful_pause_contract
    controller = ProductionBacklogControl::Controller.new(root: @root, expected_root: @root)
    result = controller.pause(@queue_rel)

    assert_equal @queue_rel, result.fetch("queue")
    assert File.file?(File.join(@root, "output", "production-backlog-control", "pause"))
  end

  def test_wrong_production_root_is_a_launch_blocker
    controller = ProductionBacklogControl::Controller.new(root: @root, expected_root: File.join(@root, "different"))
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    error = assert_raises(ProductionBacklogControl::Error) { controller.verify_launch_readiness!(queue) }
    assert_match(/production commands must run from/, error.message)
  end
  def test_launch_readiness_requires_clean_expected_production_checkout_and_queue_ancestor
    git_state = initialize_git_repo!
    controller = ProductionBacklogControl::Controller.new(root: @root, expected_root: @root)
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)

    readiness = controller.verify_launch_readiness!(queue)
    assert_equal git_state.fetch("head"), readiness.fetch("head")
    assert_equal git_state.fetch("queue_commit"), readiness.fetch("queue_commit")
    assert_equal 6, readiness.fetch("calls")

    File.write(File.join(@root, "tracked.txt"), "dirty\n")
    error = assert_raises(ProductionBacklogControl::Error) { controller.verify_launch_readiness!(queue) }
    assert_match(/uncommitted changes/, error.message)
  end

  def test_launch_readiness_rejects_queue_commit_outside_current_history
    initialize_git_repo!
    snapshot_path = File.join(@queue_dir, "snapshot.yml")
    snapshot = YAML.safe_load_file(snapshot_path)
    snapshot["local_model_eval_commit"] = "f" * 40
    File.write(snapshot_path, YAML.dump(snapshot))
    git!("add", File.join(@queue_rel, "snapshot.yml"))
    git!("commit", "-qm", "invalid provenance")

    controller = ProductionBacklogControl::Controller.new(root: @root, expected_root: @root)
    queue = ProductionBacklogControl::Queue.new(root: @root, queue: @queue_rel)
    error = assert_raises(ProductionBacklogControl::Error) { controller.verify_launch_readiness!(queue) }
    assert_match(/not an ancestor/, error.message)
  end

  def test_start_detaches_the_existing_runner_and_records_launch_provenance
    runner = File.join(@root, "run_production_backlog.sh")
    File.write(runner, <<~SH)
      #!/bin/sh
      echo "fixture runner $1"
    SH
    FileUtils.chmod(0o755, runner)

    readiness_head = "b" * 40
    readiness_calls = 0
    controller = ProductionBacklogControl::Controller.new(root: @root, expected_root: @root)
    controller.define_singleton_method(:verify_launch_readiness!) do |queue|
      readiness_calls += 1
      { "head" => readiness_head, "queue_commit" => queue.queue_commit, "calls" => queue.expected_calls }
    end

    state = controller.start(@queue_rel)
    assert_equal 1, readiness_calls
    assert_equal @queue_rel, state.fetch("queue")
    assert_operator state.fetch("pid"), :>, 0
    assert_equal readiness_head, state.fetch("repo_head")

    deadline = Time.now + 2
    log = state.fetch("log_path")
    sleep 0.02 until File.file?(log) || Time.now >= deadline
    sleep 0.02 until (File.file?(log) && File.read(log).include?("fixture runner")) || Time.now >= deadline
    assert File.file?(log)
    assert_match(/fixture runner production_backlog\/production-backlog-037/, File.read(log))
  end

end
