# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_cli_guidance"
require "stringio"

class ProductionBacklogCliGuidanceTest < Minitest::Test
  def test_dry_run_continuation_removes_only_dry_run_and_preserves_original_arguments
    root = "/Users/example/code/af-inference-orchestrator-production"
    report = "/Users/example/code/af-data-pipeline/audits/pre-scoring/apply report.json"
    argv = [
      "--batch", "37",
      "--from-boundary-apply", report,
      "--dry-run"
    ]

    step = AdventureIngest::ProductionBacklogCliGuidance.after_build(
      root: root,
      invocation_cwd: root,
      original_argv: argv,
      dry_run: true,
      queue: "production-backlog-037"
    )

    assert_equal root, step.fetch(:cwd)
    assert_equal(
      [
        File.join(root, "bin", "build-production-backlog"),
        "--batch", "37",
        "--from-boundary-apply", report
      ],
      step.fetch(:argv)
    )

    output = StringIO.new
    AdventureIngest::ProductionBacklogCliGuidance.render(step, io: output)
    assert_includes output.string, "Next command:"
    assert_includes output.string, "build-production-backlog --batch 37"
    assert_includes output.string, Shellwords.escape(report)
    refute_includes output.string, "--dry-run"
  end

  def test_prepared_continuation_runs_the_materialized_queue
    root = "/Users/example/code/af-inference-orchestrator-production"

    step = AdventureIngest::ProductionBacklogCliGuidance.after_build(
      root: root,
      invocation_cwd: "/tmp/irrelevant",
      original_argv: ["--batch", "37"],
      dry_run: false,
      queue: "production-backlog-037"
    )

    assert_equal root, step.fetch(:cwd)
    assert_equal(
      [
        "./run_production_backlog.sh",
        "production_backlog/production-backlog-037"
      ],
      step.fetch(:argv)
    )

    output = StringIO.new
    AdventureIngest::ProductionBacklogCliGuidance.render(step, io: output)
    assert_includes output.string, "Next command:"
    assert_includes output.string, "./run_production_backlog.sh production_backlog/production-backlog-037"
  end
end
