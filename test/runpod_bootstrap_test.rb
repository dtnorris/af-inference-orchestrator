# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "fileutils"
require "json"
require_relative "../lib/local_model_evaluation/runpod_bootstrap"

module LocalModelEvaluation
  class RunpodFleetState
    class Error < StandardError; end
  end unless const_defined?(:RunpodFleetState)
end

class RunpodBootstrapTest < Minitest::Test
  DIGEST = "a" * 64
  OTHER_DIGEST = "b" * 64

  class FakeFleetState
    attr_reader :root

    def initialize(root:, fleet:)
      @root = root
      @fleet = fleet
    end

    def current
      Marshal.load(Marshal.dump(@fleet))
    end

    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == @fleet.fetch("fleet_id")
      raise "wrong artifact" unless name.to_s == "bootstrap"

      File.join(@root, fleet_id, "bootstrap")
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-bootstrap-")
    @repo_root = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@repo_root)
    @state_root = File.join(@repo_root, "output", "runpod-fleets")
    @fleet = {
      "fleet_id" => "20260829T200000Z-podabc",
      "status" => "active",
      "fleet_hourly_rate_usd" => 2.20,
      "gpu" => { "id" => "NVIDIA A40", "count_per_worker" => 1 },
      "workers" => (1..3).map do |index|
        {
          "index" => index,
          "name" => "af-lme-burst-#{index}",
          "pod_id" => "pod_#{index}",
          "host" => "198.51.100.#{index}",
          "ssh_port" => 22_000 + index,
          "hourly_rate_usd" => 0.44,
          "status" => "active"
        }
      end
    }
    @fleet_state = FakeFleetState.new(root: @state_root, fleet: @fleet)
    @out = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_parallel_bootstrap_emits_heartbeats_and_writes_only_current_fleet_run
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "[1/4] Loading worker #{worker} connection settings"
      STDOUT.flush
      sleep 0.03
      puts "Direct SSH PASS."
      puts "[1/8] Preflight host, GPU, and required utilities"
      puts "Pulling gemma4:26b to fast local/root disk."
      puts "pulling blob: 42%"
      STDOUT.flush
      sleep 0.03
      puts "Copying completed Ollama store into /workspace/ollama-models."
      puts "10.0G 61%"
      puts "[6/8] Warm each model and verify context plus full GPU residency"
      STDOUT.flush
      sleep 0.03
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "[16:09:59] LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "[16:09:59] LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "[16:10:00] Worker #{worker} remote setup PASS."
    RUBY

    stale = File.join(@state_root, "old-fleet", "bootstrap", "old-run")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "burst_1.log"), "qwen3.6:27b old stale log\n")

    runner = build_runner(script)
    record = runner.run(
      worker_indices: [1, 2, 3],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      clean: true,
      heartbeat_seconds: 0.02,
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    assert_equal 3, record.fetch("workers").count { |worker| worker["status"] == "passed" }
    assert_includes @out.string, "Starting gemma4:26b bootstrap on burst_1"
    assert_includes @out.string, "heartbeat:"
    assert_includes @out.string, "PASS: burst_1 bootstrap"
    assert_includes @out.string, "PASS: burst_2 bootstrap"
    assert_includes @out.string, "PASS: burst_3 bootstrap"
    refute_includes @out.string, "qwen3.6:27b"

    bootstrap_root = File.join(@state_root, @fleet.fetch("fleet_id"), "bootstrap")
    run_id = File.read(File.join(bootstrap_root, "current")).strip
    run_dir = File.join(bootstrap_root, run_id)
    assert File.directory?(run_dir)
    assert_equal "passed", JSON.parse(File.read(File.join(run_dir, "bootstrap.json"))).fetch("status")
    (1..3).each do |index|
      log = File.read(File.join(run_dir, "burst_#{index}.log"))
      assert_includes log, "gemma4:26b"
      assert_includes log, "remote setup PASS"
    end
  end

  def test_failure_is_visible_and_preserved_without_hiding_successful_workers
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "Pulling gemma4:26b to fast local/root disk."
      STDOUT.flush
      sleep 0.02
      if worker == "2"
        warn "simulated worker failure"
        exit 7
      end
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1, 2, 3],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        heartbeat_seconds: 0.01,
        poll_seconds: 0.005
      )
    end

    assert_includes error.message, "1 worker(s)"
    assert_includes @out.string, "PASS: burst_1 bootstrap"
    assert_includes @out.string, "FAIL: burst_2 bootstrap (exit 7)"
    assert_includes @out.string, "PASS: burst_3 bootstrap"

    bootstrap_root = File.join(@state_root, @fleet.fetch("fleet_id"), "bootstrap")
    run_id = File.read(File.join(bootstrap_root, "current")).strip
    record = JSON.parse(File.read(File.join(bootstrap_root, run_id, "bootstrap.json")))
    assert_equal "failed", record.fetch("status")
    statuses = record.fetch("workers").to_h { |worker| [worker.fetch("index"), worker.fetch("status")] }
    assert_equal({ 1 => "passed", 2 => "failed", 3 => "passed" }, statuses)
  end

  def test_arguments_are_passed_without_a_shell_and_stdin_is_detached
    script = fake_remote_script(<<~'RUBY')
      puts "ARGS=#{ARGV.join('|')}"
      input = STDIN.read
      puts "STDIN_BYTES=#{input.bytesize}"
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t262144\t2566893074\t2566893074"
      puts "Worker setup PASS."
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "Worker #{worker} remote setup PASS."
    RUBY

    record = build_runner(script).run(
      worker_indices: [2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      clean: true,
      context: 262_144,
      heartbeat_seconds: 1,
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    bootstrap_root = File.join(@state_root, @fleet.fetch("fleet_id"), "bootstrap")
    run_id = File.read(File.join(bootstrap_root, "current")).strip
    log = File.read(File.join(bootstrap_root, run_id, "burst_2.log"))
    assert_includes log, "ARGS=--worker|2|--expect-gpu|NVIDIA A40|--min-vram-gb|40|--clean|--model|gemma4:26b|--expect-digest|gemma4:26b=#{DIGEST}|--context|262144"
    assert_includes log, "STDIN_BYTES=0"
  end

  def test_bootstrap_addresses_worker_twelve
    @fleet.fetch("workers") << {
      "index" => 12,
      "name" => "af-lme-burst-12",
      "pod_id" => "pod_12",
      "host" => "198.51.100.12",
      "ssh_port" => 22_012,
      "hourly_rate_usd" => 0.44,
      "status" => "active"
    }
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    record = build_runner(script).run(
      worker_indices: [12],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    assert_equal 12, record.fetch("workers").first.fetch("index")
    assert_includes @out.string, "burst_12"
  end

  def test_refuses_non_active_or_unknown_workers_before_spawning
    @fleet["workers"][1]["status"] = "destroyed"
    script = fake_remote_script("raise 'must not run'\n")
    runner = build_runner(script)

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [2], models: ["gemma4:26b"])
    end
    assert_includes error.message, "not active"

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [5], models: ["gemma4:26b"])
    end
    assert_includes error.message, "does not contain worker"
  end

  def test_interrupt_stops_spawned_process_group_and_records_interrupted_state
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "[1/8] Preflight host, GPU, and required utilities"
      STDOUT.flush
      sleep 30
      puts "Worker #{worker} remote setup PASS."
    RUBY

    runner = build_runner(script)
    outcome = nil
    thread = Thread.new do
      begin
        runner.run(
          worker_indices: [1],
          models: ["gemma4:26b"],
          expected_digests: ["gemma4:26b=#{DIGEST}"],
          heartbeat_seconds: 0.05,
          poll_seconds: 0.005
        )
      rescue Interrupt
        outcome = :interrupted
      end
    end

    bootstrap_root = File.join(@state_root, @fleet.fetch("fleet_id"), "bootstrap")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    run_id = nil
    pid = nil
    until pid || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      if File.file?(File.join(bootstrap_root, "current"))
        run_id = File.read(File.join(bootstrap_root, "current")).strip
        state_path = File.join(bootstrap_root, run_id, "bootstrap.json")
        if File.file?(state_path)
          state = JSON.parse(File.read(state_path))
          pid = state.fetch("workers").first["pid"]
        end
      end
      sleep 0.005 unless pid
    end
    refute_nil pid, "bootstrap child pid was not recorded"

    thread.raise Interrupt
    thread.join(5)
    refute thread.alive?, "bootstrap thread did not exit after Interrupt"
    assert_equal :interrupted, outcome
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }

    state = JSON.parse(File.read(File.join(bootstrap_root, run_id, "bootstrap.json")))
    assert_equal "interrupted", state.fetch("status")
    assert_equal "interrupted", state.fetch("workers").first.fetch("status")
    assert_includes @out.string, "Interrupt received; stopping 1 bootstrap process group(s)"
    assert_includes @out.string, "Local bootstrap/SSH process groups stopped"
  end

  def test_requires_exact_digest_for_every_model_before_spawning
    script = fake_remote_script("raise 'must not run'\n")
    runner = build_runner(script)

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [1], models: ["gemma4:26b"])
    end
    assert_includes error.message, "exact expected digest required"

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=deadbeef"]
      )
    end
    assert_includes error.message, "exactly 64 hexadecimal"
  end

  def test_successful_remote_exit_fails_closed_when_provenance_mismatches
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"b" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        poll_seconds: 0.005
      )
    end

    assert_includes error.message, "1 worker(s)"
    assert_includes @out.string, "provenance: gemma4:26b digest mismatch"
  end


  private

  def build_runner(script)
    LocalModelEvaluation::RunpodBootstrap.new(
      fleet_state: @fleet_state,
      remote_setup_path: script,
      repo_root: @repo_root,
      out: @out
    )
  end

  def fake_remote_script(body)
    scenario =
      if body.include?("ARGS=#{'#{'}ARGV.join('|')}")
        :echo_args
      elsif body.include?('sleep 30')
        :interrupt
      elsif body.include?('simulated worker failure')
        :worker_failure
      elsif body.include?('"b" * 64')
        :bad_provenance
      elsif body.include?("raise 'must not run'")
        :must_not_run
      elsif body.include?('[1/4] Loading worker')
        :parallel
      else
        :success
      end

    shell = case scenario
            when :parallel
              <<~SH
                printf '[1/4] Loading worker %s connection settings\n' "$worker"
                printf 'Direct SSH PASS.\n'
                printf '[1/8] Preflight host, GPU, and required utilities\n'
                printf 'Pulling gemma4:26b to fast local/root disk.\n'
                printf 'pulling blob: 42%%\n'
                sleep 0.06
                printf 'Copying completed Ollama store into /workspace/ollama-models.\n'
                printf '10.0G 61%%\n'
                printf '[6/8] Warm each model and verify context plus full GPU residency\n'
                printf 'gemma4:26b verification PASS: context=131072 and 100%% model residency in VRAM.\n'
                printf '[16:09:59] LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
                printf '[16:09:59] LME_PROVENANCE_MODEL\tgemma4:26b\t#{DIGEST}\t131072\t2566893074\t2566893074\n'
                printf 'Worker setup PASS.\n'
                printf '[16:10:00] Worker %s remote setup PASS.\n' "$worker"
              SH
            when :worker_failure
              <<~SH
                printf 'Pulling gemma4:26b to fast local/root disk.\n'
                sleep 0.02
                if [ "$worker" = "2" ]; then
                  printf 'simulated worker failure\n' >&2
                  exit 7
                fi
                printf 'gemma4:26b verification PASS: context=131072 and 100%% model residency in VRAM.\n'
                printf 'LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
                printf 'LME_PROVENANCE_MODEL\tgemma4:26b\t#{DIGEST}\t131072\t2566893074\t2566893074\n'
                printf 'Worker setup PASS.\n'
                printf 'Worker %s remote setup PASS.\n' "$worker"
              SH
            when :echo_args
              <<~SH
                args=""
                for arg in "$@"; do
                  if [ -z "$args" ]; then args="$arg"; else args="$args|$arg"; fi
                done
                printf 'ARGS=%s\n' "$args"
                stdin_bytes="$(wc -c | tr -d '[:space:]')"
                printf 'STDIN_BYTES=%s\n' "$stdin_bytes"
                printf 'LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
                printf 'LME_PROVENANCE_MODEL\tgemma4:26b\t#{DIGEST}\t262144\t2566893074\t2566893074\n'
                printf 'Worker setup PASS.\n'
                printf 'Worker %s remote setup PASS.\n' "$worker"
              SH
            when :interrupt
              <<~SH
                printf '[1/8] Preflight host, GPU, and required utilities\n'
                sleep 30
                printf 'Worker %s remote setup PASS.\n' "$worker"
              SH
            when :bad_provenance
              <<~SH
                printf 'gemma4:26b verification PASS: context=131072 and 100%% model residency in VRAM.\n'
                printf 'LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
                printf 'LME_PROVENANCE_MODEL\tgemma4:26b\t#{OTHER_DIGEST}\t131072\t2566893074\t2566893074\n'
                printf 'Worker setup PASS.\n'
                printf 'Worker %s remote setup PASS.\n' "$worker"
              SH
            when :must_not_run
              "exit 99\n"
            else
              <<~SH
                printf 'LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
                printf 'LME_PROVENANCE_MODEL\tgemma4:26b\t#{DIGEST}\t131072\t2566893074\t2566893074\n'
                printf 'Worker setup PASS.\n'
                printf 'Worker %s remote setup PASS.\n' "$worker"
              SH
            end

    path = File.join(@repo_root, "fake-remote-#{rand(1_000_000)}.sh")
    File.write(path, <<~SH)
      #!/bin/sh
      set -eu
      worker=""
      previous=""
      for arg in "$@"; do
        if [ "$previous" = "--worker" ]; then
          worker="$arg"
          break
        fi
        previous="$arg"
      done
      #{shell}
    SH
    File.chmod(0o755, path)
    path
  end
end
