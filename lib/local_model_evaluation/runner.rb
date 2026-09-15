# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "thread"
require "time"

module LocalModelEvaluation
  class Runner
    attr_reader :experiment, :workers, :models, :output_dir

    def initialize(experiment:, workers:, models:, output_root:, rerun_failed: false, force: false, io: $stdout)
      @experiment = experiment
      @workers = workers
      @models = models
      @output_dir = File.join(File.expand_path(output_root), experiment.name)
      @rerun_failed = rerun_failed
      @force = force
      @io = io
      @ledger_mutex = Mutex.new
      @cost_mutex = Mutex.new
      @estimated_cost_total = 0.0
    end

    def run(jobs)
      prepare_output
      @estimated_cost_total = existing_cost_total
      pending = jobs.select { |job| should_run?(job) }
      completed_count = jobs.length - pending.length
      @io.puts "#{completed_count} completed/skipped; #{pending.length} pending"
      return if pending.empty?

      if experiment.dispatch == "matrix"
        run_matrix(pending)
      else
        run_pool(pending)
      end
    ensure
      rebuild_ledgers(jobs) if jobs
    end

    private

    def prepare_output
      FileUtils.mkdir_p(File.join(output_dir, "runs"))
      FileUtils.cp(experiment.path, File.join(output_dir, "experiment.yml")) unless File.exist?(File.join(output_dir, "experiment.yml"))
      environment = {
        generated_at: Time.now.iso8601,
        ruby_version: RUBY_VERSION,
        ruby_platform: RUBY_PLATFORM,
        afio_git_commit: git_commit(File.expand_path("../..", __dir__)),
        scorer_git_commit: git_commit(experiment.scorer_repo),
        scorer_repo: experiment.scorer_repo,
        dispatch: experiment.dispatch
      }
      File.write(File.join(output_dir, "environment.json"), JSON.pretty_generate(environment))
    end

    def run_matrix(pending)
      grouped = pending.group_by(&:planned_worker)
      threads = grouped.map do |worker_name, worker_jobs|
        Thread.new do
          worker = workers.fetch(worker_name)
          worker_jobs.each do |job|
            break if budget_exhausted?
            execute(job, worker)
          end
        end
      end
      threads.each(&:join)
    end

    def run_pool(pending)
      queue = Queue.new
      pending.each { |job| queue << job }
      eligible = experiment.worker_names.map { |n| workers.fetch(n) }.select { |w| w.compatible?(experiment.required_worker_labels) }
      raise "no eligible workers" if eligible.empty?

      threads = eligible.map do |worker|
        Thread.new do
          loop do
            job = begin
              queue.pop(true)
            rescue ThreadError
              nil
            end
            break unless job
            break if budget_exhausted?
            execute(job, worker)
          end
        end
      end
      threads.each(&:join)
    end

    def execute(job, worker)
      run_dir = File.join(output_dir, "runs", job.id)
      native_dir = File.join(run_dir, "native")
      FileUtils.mkdir_p(native_dir)
      metadata_path = File.join(run_dir, "metadata.json")

      started = Time.now
      metadata = base_metadata(job, worker).merge(status: "running", started_at: started.iso8601)
      write_json(metadata_path, metadata)
      @io.puts "[#{worker.name}] #{job.model_alias} #{job.adventure} rep#{job.replicate}"

      command = scorer_command(job, native_dir)
      env = worker.scorer_env
      stdout, stderr, status = Open3.capture3(env, *command, chdir: experiment.scorer_repo)
      finished = Time.now

      File.write(File.join(run_dir, "stdout.log"), stdout)
      File.write(File.join(run_dir, "stderr.log"), stderr)
      estimated_cost = (((finished - started) / 3600.0) * worker.hourly_rate_usd).round(6)
      metadata.merge!(
        status: status.success? ? "complete" : "failed",
        completed_at: finished.iso8601,
        elapsed_seconds: (finished - started).round(3),
        exit_status: status.exitstatus,
        command: command,
        scorer_env_keys: env.keys.sort,
        estimated_cost_usd: estimated_cost
      )
      write_json(metadata_path, metadata)
      @cost_mutex.synchronize { @estimated_cost_total += estimated_cost }
    rescue StandardError => e
      finished = Time.now
      File.write(File.join(run_dir, "stderr.log"), "#{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}") rescue nil
      metadata ||= base_metadata(job, worker)
      metadata.merge!(status: "failed", completed_at: finished.iso8601, error: "#{e.class}: #{e.message}")
      write_json(metadata_path, metadata) rescue nil
    end

    def scorer_command(job, native_dir)
      exe = File.join(experiment.scorer_repo, "bin", "af-score")
      raise "scorer executable not found: #{exe}" unless File.file?(exe)

      command = [exe, "--model", job.ollama_model, "--dimension", experiment.dimension, "--output", native_dir]
      case experiment.scorer_mode
      when "regression"
        command += ["--regression", job.adventure]
      when "positional"
        command << job.adventure
      else
        raise ArgumentError, "unsupported scorer mode #{experiment.scorer_mode.inspect}"
      end
      command + experiment.extra_args
    end

    def base_metadata(job, worker)
      {
        job_id: job.id,
        worker: worker.name,
        worker_base_url: worker.base_url,
        worker_labels: worker.labels,
        worker_hourly_rate_usd: worker.hourly_rate_usd,
        model_alias: job.model_alias,
        ollama_model: job.ollama_model,
        adventure: job.adventure,
        replicate: job.replicate,
        dimension: experiment.dimension
      }
    end

    def should_run?(job)
      metadata = read_metadata(job)
      return true if @force || metadata.nil?
      return true if @rerun_failed && metadata["status"] == "failed"
      metadata["status"] != "complete" && metadata["status"] != "failed"
    end

    def read_metadata(job)
      path = File.join(output_dir, "runs", job.id, "metadata.json")
      return nil unless File.file?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def rebuild_ledgers(jobs)
      rows = jobs.filter_map do |job|
        path = File.join(output_dir, "runs", job.id, "metadata.json")
        next unless File.file?(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      CSV.open(File.join(output_dir, "jobs.csv"), "w") do |csv|
        csv << %w[job_id worker model adventure replicate status started_at completed_at elapsed_seconds exit_status estimated_cost_usd output_path]
        rows.each do |r|
          csv << [r["job_id"], r["worker"], r["model_alias"], r["adventure"], r["replicate"], r["status"], r["started_at"], r["completed_at"], r["elapsed_seconds"], r["exit_status"], r["estimated_cost_usd"], File.join("runs", r["job_id"].to_s)]
        end
      end
    end


    def existing_cost_total
      Dir.glob(File.join(output_dir, "runs", "*", "metadata.json")).sum do |path|
        JSON.parse(File.read(path))["estimated_cost_usd"].to_f
      rescue JSON::ParserError
        0.0
      end
    end

    def budget_exhausted?
      cap = experiment.cost_cap_usd
      return false unless cap
      exhausted = @cost_mutex.synchronize { @estimated_cost_total >= cap }
      @io.puts format("Cost cap reached (estimated scoring runtime $%.4f >= $%.4f); no new jobs dispatched.", @estimated_cost_total, cap) if exhausted
      exhausted
    end

    def git_commit(repo)
      return nil unless File.directory?(repo)
      out, _err, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    def write_json(path, value)
      File.write(path, JSON.pretty_generate(value))
    end
  end
end
