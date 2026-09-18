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
    FileUtils.mkdir_p(File.join(@root, "scorer", "config"))
    File.write(File.join(@root, "scorer", "bin", "af-score"), "#!/bin/sh\n")
    File.write(
      File.join(@root, "scorer", "config", "default.yml"),
      YAML.dump(
        "paths" => {
          "xlsx_root" => File.join(@root, "xlsx"),
          "source_root" => File.join(@root, "sources")
        },
        "files" => {
          "catalog" => "catalog.xlsx",
          "source_registry" => "source_registry.yml"
        },
        "source" => { "allow_full_source_fallback" => false }
      )
    )
    File.write(
      File.join(@root, "config", "models.yml"),
      YAML.dump(
        "models" => {
          "qwen" => { "ollama_model" => "qwen3.6:35b-a3b" },
          "gptoss" => { "ollama_model" => "gpt-oss:20b" },
          "gemma" => { "ollama_model" => "gemma4:26b" }
        }
      )
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_deduplicates_ordinary_source_across_dimension_model_and_runtime_variants
    write_runtime("a", catalog: "catalog.xlsx", llm: { "reasoning_effort" => "high", "max_tokens" => 8192 })
    write_runtime("b", catalog: "catalog.xlsx", llm: { "reasoning_effort" => "low", "max_tokens" => 4096 })
    write_runtime("c", catalog: "catalog.xlsx", llm: { "reasoning_effort" => "medium", "max_tokens" => 16_384 })
    first = write_manifest(
      "combat", "Combat Emphasis", "ADV-0059",
      model: "qwen", extra_args: ["--config", "${LME_REPO}/runtime-a.yml"]
    )
    second = write_manifest(
      "exploration", "Exploration Emphasis", "ADV-0059",
      model: "gptoss", extra_args: ["--config", "${LME_REPO}/runtime-b.yml"]
    )
    third = write_manifest(
      "seriousness", "Seriousness", "ADV-0059",
      model: "gemma", extra_args: ["--config", "${LME_REPO}/runtime-c.yml"]
    )
    write_order(first, second, third)

    calls = []
    out = StringIO.new
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: StringIO.new,
      command_runner: lambda do |env, command, chdir|
        calls << [env, command, chdir]
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_equal 1, calls.length
    assert_match(/1 unique adventure source checked/, out.string)
  end

  def test_prompt_profile_environment_does_not_split_ordinary_source_identity
    plain = write_manifest("combat", "Combat Emphasis", "ADV-0060")
    profiled = write_manifest(
      "social", "Social Interaction Emphasis", "ADV-0060",
      phase6: {
        "prompt_profile" => {
          "version" => "phase6-v0.3",
          "env_name" => "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE",
          "env_value" => "phase6-v0.3"
        }
      }
    )
    write_order(plain, profiled)

    calls = []
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: StringIO.new,
      err: StringIO.new,
      command_runner: lambda do |*args|
        calls << args
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_equal 1, calls.length
  end

  def test_different_adventure_ids_get_separate_source_checks
    first = write_manifest("first", "Combat Emphasis", "ADV-0061")
    second = write_manifest("second", "Combat Emphasis", "ADV-0062")
    write_order(first, second)

    calls = []
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: StringIO.new,
      err: StringIO.new,
      command_runner: lambda do |*args|
        calls << args
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_equal 2, calls.length
  end

  def test_source_changing_catalog_input_gets_separate_check
    write_runtime("catalog-a", catalog: "catalog-a.xlsx")
    write_runtime("catalog-b", catalog: "catalog-b.xlsx")
    first = write_manifest(
      "first", "Combat Emphasis", "ADV-0063",
      extra_args: ["--config", "${LME_REPO}/runtime-catalog-a.yml"]
    )
    second = write_manifest(
      "second", "Exploration Emphasis", "ADV-0063",
      extra_args: ["--config", "${LME_REPO}/runtime-catalog-b.yml"]
    )
    write_order(first, second)

    calls = []
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: StringIO.new,
      err: StringIO.new,
      command_runner: lambda do |*args|
        calls << args
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_equal 2, calls.length
  end

  def test_levels_keeps_a_distinct_source_context_for_precanonical_material
    ordinary = write_manifest("combat", "Combat Emphasis", "ADV-0064")
    levels = write_manifest("levels", "Levels", "ADV-0064")
    write_order(ordinary, levels)

    calls = []
    out = StringIO.new
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: StringIO.new,
      command_runner: lambda do |env, command, chdir|
        calls << [env, command, chdir]
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue")

    assert ok
    assert_equal 2, calls.length
    assert_equal ["Combat Emphasis", "Levels"], calls.map { |_env, command, _chdir| command.fetch(4) }
    assert_match(/2 unique adventure sources checked/, out.string)
  end

  def test_explicit_manifest_selection_checks_only_selected_entries_in_frozen_order
    first = write_manifest("first", "Combat Emphasis", "ADV-0401")
    second = write_manifest("second", "Combat Emphasis", "ADV-0402")
    third = write_manifest("third", "Combat Emphasis", "ADV-0403")
    write_order(first, second, third)

    calls = []
    out = StringIO.new
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: out,
      err: StringIO.new,
      command_runner: lambda do |env, command, chdir|
        calls << [env, command, chdir]
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue", manifest_entries: [third, first])

    assert ok
    assert_equal %w[ADV-0401 ADV-0403], calls.map { |_env, command, _chdir| command.fetch(6) }
    refute_includes out.string, File.basename(second)
    assert_match(/2 unique adventure sources checked/, out.string)
  end

  def test_explicit_manifest_selection_rejects_entries_outside_frozen_run_order
    included = write_manifest("included", "Combat Emphasis", "ADV-0411")
    outside = write_manifest("outside", "Combat Emphasis", "ADV-0412")
    write_order(included)

    calls = []
    err = StringIO.new
    ok = LocalModelEvaluation::ProductionBacklogSourcePreflight.new(
      root: @root,
      io: StringIO.new,
      err: err,
      command_runner: lambda do |*args|
        calls << args
        ["ok", "", FakeStatus.new(true)]
      end
    ).run("production_backlog/queue", manifest_entries: [outside])

    refute ok
    assert_empty calls
    assert_match(/not present in frozen run order/, err.string)
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
    assert_match(/1 unique adventure source checked/, out.string)
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
    assert_match(/3 unique adventure sources checked/, out.string)
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
    assert_match(/0 unique adventure sources checked/, out.string)
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

  def write_manifest(slug, dimension, adventure, model: "qwen", extra_args: [], phase6: nil)
    path = File.join(@root, "experiments", "queue", "#{slug}.yml")
    data = {
      "name" => "queue-#{slug}",
      "dispatch" => "pool",
      "models" => [model],
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

  def write_runtime(slug, catalog:, llm: {})
    File.write(
      File.join(@root, "runtime-#{slug}.yml"),
      YAML.dump(
        "llm" => llm,
        "files" => { "catalog" => catalog },
        "source" => {
          "allow_inward_boundary_clamp_adventure_ids" => [],
          "inward_boundary_clamp_max_gap_by_adventure" => {}
        }
      )
    )
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
