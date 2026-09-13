# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "pathname"
require "stringio"
require "yaml"

class ProductionBacklogSourcePreflightTest < Minitest::Test
  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def setup
    @root = Dir.mktmpdir("lme-source-preflight")
    FileUtils.mkdir_p(File.join(@root, "config"))
    FileUtils.mkdir_p(File.join(@root, "experiments", "queue"))
    FileUtils.mkdir_p(File.join(@root, "production_backlog", "queue"))
    FileUtils.mkdir_p(File.join(@root, "scorer", "bin"))
    File.write(File.join(@root, "scorer", "bin", "af-score"), "#!/bin/sh\n")
    File.write(
      File.join(@root, "config", "models.yml"),
      YAML.dump("models" => { "qwen" => { "ollama_model" => "qwen3.6:35b-a3b" } })
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_preflights_each_unique_runtime_source_context_once
    first = write_manifest("levels", "Levels", "ADV-0059")
    second = write_manifest("combat", "Combat Emphasis", "ADV-0059")
    write_order(first, second)

    calls = []
    runner = lambda do |env, command, chdir|
      calls << [env, command, chdir]
      ["ok", "", FakeStatus.new(true)]
    end
    out = StringIO.new
    err = StringIO.new

    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: err,
      command_runner: runner
    ).run("production_backlog/queue")

    assert ok
    assert_equal 1, calls.length
    _env, command, chdir = calls.fetch(0)
    assert_equal File.join(@root, "scorer"), chdir
    assert_equal File.join(@root, "scorer", "bin", "af-score"), command.fetch(0)
    assert_includes command, "qwen3.6:35b-a3b"
    assert_includes command, "--preflight"
    assert_includes command, "ADV-0059"
    assert_match(/Runtime source preflight: PASS/, out.string)
    assert_empty err.string
  end

  def test_fails_closed_when_active_scorer_cannot_resolve_a_source
    first = write_manifest("levels", "Levels", "ADV-0059")
    write_order(first)

    runner = lambda do |_env, _command, _chdir|
      ["", 'ERROR: No Markdown source resolved for "Rise of the Ice Dragons Trilogy"', FakeStatus.new(false)]
    end
    out = StringIO.new
    err = StringIO.new

    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: err,
      command_runner: runner
    ).run("production_backlog/queue")

    refute ok
    assert_match(/SOURCE FAIL/, err.string)
    assert_match(/No Markdown source resolved/, err.string)
    assert_match(/No inference is authorized/, err.string)
  end

  def test_skips_complete_and_failed_manifests_before_source_preflight
    complete = write_manifest("complete", "Combat Emphasis", "ADV-0101")
    failed = write_manifest("failed", "Combat Emphasis", "ADV-0102")
    pending = write_manifest("pending", "Combat Emphasis", "ADV-0103")
    write_status("complete", "complete")
    write_status("failed", "complete", "failed")
    write_order(complete, failed, pending)

    calls = []
    runner = lambda do |env, command, chdir|
      calls << [env, command, chdir]
      ["ok", "", FakeStatus.new(true)]
    end
    out = StringIO.new

    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: StringIO.new,
      command_runner: runner
    ).run("production_backlog/queue")

    assert ok
    assert_equal 1, calls.length
    assert_includes calls.fetch(0).fetch(1), "ADV-0103"
    assert_match(/1 unique source context checked/, out.string)
    assert_match(/2 terminal manifests skipped/, out.string)
    assert_match(/1 nonterminal manifest considered/, out.string)
  end

  def test_preflights_pending_running_and_unknown_manifests
    pending = write_manifest("pending", "Combat Emphasis", "ADV-0201")
    running = write_manifest("running", "Combat Emphasis", "ADV-0202")
    unknown = write_manifest("unknown", "Combat Emphasis", "ADV-0203")
    write_status("running", "running")
    write_malformed_status("unknown")
    write_order(pending, running, unknown)

    calls = []
    runner = lambda do |env, command, chdir|
      calls << [env, command, chdir]
      ["ok", "", FakeStatus.new(true)]
    end
    out = StringIO.new

    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: StringIO.new,
      command_runner: runner
    ).run("production_backlog/queue")

    assert ok
    assert_equal 3, calls.length
    assert_equal %w[ADV-0201 ADV-0202 ADV-0203], calls.map { |_env, command, _chdir| command.fetch(6) }
    assert_match(/3 unique source contexts checked/, out.string)
    assert_match(/0 terminal manifests skipped/, out.string)
    assert_match(/3 nonterminal manifests considered/, out.string)
  end

  def test_all_terminal_queue_passes_without_source_checks
    complete = write_manifest("complete", "Combat Emphasis", "ADV-0301")
    failed = write_manifest("failed", "Combat Emphasis", "ADV-0302")
    write_status("complete", "complete")
    write_status("failed", "failed")
    write_order(complete, failed)

    calls = []
    out = StringIO.new
    err = StringIO.new

    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: err,
      command_runner: lambda do |*args|
        calls << args
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_empty calls
    assert_match(/0 unique source contexts checked/, out.string)
    assert_match(/2 terminal manifests skipped/, out.string)
    assert_match(/0 nonterminal manifests considered/, out.string)
    assert_empty err.string
  end

  def test_applies_manifest_prompt_profile_environment_and_runtime_config
    manifest = write_manifest(
      "social",
      "Social Interaction Emphasis",
      "ADV-0122",
      extra_args: ["--config", "${LME_REPO}/runtime.yml"],
      phase6: {
        "prompt_profile" => {
          "version" => "phase6-v0.3",
          "env_name" => "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE",
          "env_value" => "phase6-v0.3"
        }
      }
    )
    write_order(manifest)
    File.write(File.join(@root, "runtime.yml"), "--- {}\n")

    calls = []
    runner = lambda do |env, command, chdir|
      calls << [env, command, chdir]
      ["ok", "", FakeStatus.new(true)]
    end

    old_lme_repo = ENV.delete("LME_REPO")
    begin
      ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
        root: @root,
        io: StringIO.new,
        err: StringIO.new,
        command_runner: runner
      ).run("production_backlog/queue")
      assert ok
    ensure
      ENV["LME_REPO"] = old_lme_repo if old_lme_repo
    end

    env, command, = calls.fetch(0)
    assert_equal "phase6-v0.3", env.fetch("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
    assert_equal ["--config", File.join(@root, "runtime.yml")], command.last(2)
  end

  private

  def write_manifest(slug, dimension, adventure, extra_args: [], phase6: nil)
    path = File.join(@root, "experiments", "queue", "#{slug}.yml")
    data = {
      "name" => "queue-#{slug}",
      "dispatch" => "pool",
      "models" => ["qwen"],
      "dimension" => dimension,
      "adventures" => [adventure],
      "replicates" => 1,
      "workers" => ["mac"],
      "scorer" => {
        "repo" => "../../scorer",
        "mode" => "positional",
        "extra_args" => extra_args
      }
    }
    data["phase6_contract"] = phase6 if phase6
    File.write(path, YAML.dump(data))
    Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
  end

  def write_status(slug, *statuses)
    statuses.each_with_index do |status, index|
      dir = File.join(@root, "output", "queue-#{slug}", "runs", "run-#{index + 1}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "metadata.json"), JSON.dump("status" => status))
    end
  end

  def write_malformed_status(slug)
    dir = File.join(@root, "output", "queue-#{slug}", "runs", "run-1")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "metadata.json"), "{not-json")
  end

  def write_order(*entries)
    File.write(
      File.join(@root, "production_backlog", "queue", "run_order.txt"),
      entries.join("\n") + "\n"
    )
  end
end
