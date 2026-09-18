# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "yaml"
require_relative "production_backlog_runner_policy"

class ProductionBurstRunner
  PLAN_CONTRACT = "afio-production-execution-pool-plan/v0.1"
  LEDGER_CONTRACT = "afio-production-burst-ledger/v0.1"
  HANDOFF_CONTRACT = "afio-production-execution-pool-handoff/v0.1"

  Result = Struct.new(:ledger, :exit_status, keyword_init: true)
  Error = Class.new(StandardError)

  class SystemPreflight
    def initialize(root:)
      @root = File.expand_path(root)
    end

    def run!(queue_dir:, contract_type:)
      verifier = File.join(@root, ProductionBacklogRunnerPolicy.verifier_for(contract_type))
      source_preflight = File.join(@root, "bin", "preflight-production-backlog-sources")
      raise Error, "missing/executable verifier #{verifier}" unless File.executable?(verifier)
      raise Error, "missing/executable runtime source preflight #{source_preflight}" unless File.executable?(source_preflight)

      unless system({ "LME_REPO" => @root }, verifier, queue_dir, chdir: @root)
        raise Error, "backlog preflight failed; no paid fulfillment was started"
      end
      unless system({ "LME_REPO" => @root }, source_preflight, queue_dir, chdir: @root)
        raise Error, "runtime source preflight failed; no paid fulfillment was started"
      end
    end
  end

  class SystemFulfillmentLauncher
    def initialize(root:)
      @root = File.expand_path(root)
    end

    def call(plan_path:, pool_id:, handoff_path:, dry_run:)
      command = [
        File.join(@root, "bin", "lme-production-pool-fulfill"),
        relative_path(plan_path),
        "--pool", pool_id,
        "--output", relative_path(handoff_path),
        dry_run ? "--dry-run" : "--yes"
      ]
      system({ "LME_REPO" => @root }, *command, chdir: @root)
    end

    private

    def relative_path(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    rescue ArgumentError
      path.to_s
    end
  end

  class SystemCampaignLauncher
    def initialize(root:)
      @root = File.expand_path(root)
    end

    def launch(pool_id:, workers:, execution_handle:, requirements:, jobs_path:, campaign_dir:, queue_dir:, keep_fleet:)
      command = [
        File.join(@root, "bin", "lme-rpof-campaign"),
        "--workers", workers.join(","),
        "--fleet", execution_handle,
        "--model", requirements.fetch("ollama_model"),
        "--expect-digest", "#{requirements.fetch('ollama_model')}=#{requirements.fetch('expected_digest')}",
        "--context", requirements.fetch("required_context_length").to_s,
        "--jobs", jobs_path,
        "--workdir", @root,
        "--output", campaign_dir,
        "--source-preflight-queue", queue_dir,
        "--dynamic-worker-admission"
      ]
      command << "--keep-fleet" if keep_fleet
      env = {
        "LME_REPO" => @root,
        "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE" => "phase6-v0.3",
        "AF_INVESTIGATION_GUARDRAIL_PROFILE" => "phase6-v0.4"
      }
      log = File.open(File.join(File.dirname(campaign_dir), "campaign.log"), "a")
      Process.spawn(
        env,
        *command,
        chdir: @root,
        in: File::NULL,
        out: log,
        err: [:child, :out],
        pgroup: true
      )
    ensure
      log&.close
    end

    def wait(pid)
      _waited, process_status = Process.wait2(pid)
      process_status.exitstatus
    end

    def alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH, Errno::EPERM, ArgumentError, TypeError
      false
    end

    def interrupt(pid)
      Process.kill("INT", -Integer(pid))
    rescue Errno::ESRCH
      nil
    end

    def wait_after_interrupt(pid)
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def initialize(root:, preflight: nil, fulfillment_launcher: nil, campaign_launcher: nil, out: $stdout, err: $stderr)
    @root = File.expand_path(root)
    @preflight = preflight || SystemPreflight.new(root: @root)
    @fulfillment_launcher = fulfillment_launcher || SystemFulfillmentLauncher.new(root: @root)
    @campaign_launcher = campaign_launcher || SystemCampaignLauncher.new(root: @root)
    @out = out
    @err = err
  end

  def run(plan:, output:, dry_run:, keep_fleets: false)
    plan_path = within_root(plan)
    raise Error, "execution-pool plan not found: #{plan_path}" unless File.file?(plan_path)
    plan_bytes = File.binread(plan_path)
    plan_sha = Digest::SHA256.hexdigest(plan_bytes)
    document = JSON.parse(plan_bytes)
    unless document["contract_version"] == PLAN_CONTRACT
      raise Error, "unsupported execution-pool plan version: #{document['contract_version'].inspect}"
    end

    output_dir = within_root(output)
    FileUtils.mkdir_p(output_dir)
    ledger_path = File.join(output_dir, "production-burst.json")
    ledger = if File.file?(ledger_path)
               load_json(ledger_path, "production-burst ledger")
             else
               initial_ledger(plan_path, plan_sha, document)
             end
    unless ledger["contract_version"] == LEDGER_CONTRACT &&
           ledger.dig("plan", "sha256").to_s == plan_sha
      raise Error, "existing parent output belongs to a different execution-pool plan; use a new --output directory"
    end

    queue_dir, contract_type = validate_queue!(document)
    @preflight.run!(queue_dir:, contract_type:)
    print_header(plan_path:, plan_sha:, plan: document)

    children = {}
    begin
      Array(document.fetch("pools")).each do |pool|
        run_pool(
          pool:,
          plan_path:,
          plan_sha:,
          output_dir:,
          ledger_path:,
          ledger:,
          contract_type:,
          queue_dir:,
          dry_run:,
          keep_fleets:,
          children:
        )
      end
      wait_for_campaigns(children:, ledger:, ledger_path:)
    rescue Interrupt
      children.each_value { |pid| @campaign_launcher.interrupt(pid) }
      children.each_value { |pid| @campaign_launcher.wait_after_interrupt(pid) }
      ledger["status"] = "interrupted"
      write_ledger(ledger_path, ledger)
      raise
    end

    ledger["status"] = final_status(ledger:, dry_run:)
    write_ledger(ledger_path, ledger)
    @out.puts "Production burst: #{ledger.fetch('status')}"
    @out.puts "Ledger: #{ledger_path}"

    Result.new(ledger:, exit_status: exit_status_for(ledger.fetch("status")))
  rescue Error
    raise
  rescue JSON::ParserError, Psych::Exception, KeyError, ArgumentError, TypeError, SystemCallError, RuntimeError => e
    raise Error, e.message
  end

  private

  def run_pool(pool:, plan_path:, plan_sha:, output_dir:, ledger_path:, ledger:, contract_type:, queue_dir:, dry_run:, keep_fleets:, children:)
    pool_id = pool.fetch("pool_id")
    row = ledger.fetch("pools").fetch(pool_id)
    pool_dir = File.join(output_dir, "pools", pool_id)
    FileUtils.mkdir_p(pool_dir)
    campaign_dir = File.join(pool_dir, "campaign")
    summary_path = File.join(campaign_dir, "summary.json")

    existing_status = summary_status(summary_path)
    if existing_status == "completed"
      row["status"] = "completed"
      row["campaign_output"] = relative_path(campaign_dir)
      row["detail"] = "existing completed campaign retained"
      write_ledger(ledger_path, ledger)
      @out.puts "  #{pool_id}: completed — resume skipped."
      return
    end
    if existing_status == "workload_failed" || row["status"] == "workload_failed"
      row["status"] = "workload_failed"
      row["campaign_output"] = relative_path(campaign_dir)
      row["detail"] = "sticky workload failure; automatic rerun suppressed"
      write_ledger(ledger_path, ledger)
      @out.puts "  #{pool_id}: workload_failed — sticky; resume skipped."
      return
    end
    if row["campaign_pid"] && @campaign_launcher.alive?(row["campaign_pid"])
      row["status"] = "running"
      row["detail"] = "existing child campaign process is still alive"
      write_ledger(ledger_path, ledger)
      @out.puts "  #{pool_id}: existing campaign pid #{row['campaign_pid']} is still running; not duplicated."
      return
    end

    jobs_path = File.join(pool_dir, "jobs.json")
    materialize_jobs(jobs_path, manifest_jobs(pool, contract_type))
    handoff_path = File.join(pool_dir, "handoff.json")
    @out.puts "  #{pool_id}: fulfillment starting..."
    flush(@out)
    fulfilled = @fulfillment_launcher.call(
      plan_path:,
      pool_id:,
      handoff_path:,
      dry_run:
    )
    unless File.file?(handoff_path)
      row["status"] = "fulfillment_failed"
      row["detail"] = "fulfillment exited without a handoff artifact"
      write_ledger(ledger_path, ledger)
      @err.puts "WARNING: #{pool_id}: fulfillment produced no handoff; continuing independent lanes."
      return
    end

    handoff = load_json(handoff_path, "#{pool_id} handoff")
    unless handoff["contract_version"] == HANDOFF_CONTRACT &&
           handoff.dig("plan", "sha256").to_s == plan_sha &&
           handoff["pool_id"].to_s == pool_id
      raise Error, "#{pool_id}: fulfillment handoff identity does not match parent plan"
    end
    result = handoff.fetch("result")
    row["handoff_path"] = relative_path(handoff_path)
    row["execution_handle"] = result["execution_handle"]
    row["worker_indices"] = Array(result["worker_indices"])

    if dry_run
      row["status"] = result["status"] == "planned" ? "planned" : "unavailable"
      row["detail"] = result["detail"].to_s
      write_ledger(ledger_path, ledger)
      return
    end

    unless fulfilled && result["ready"] == true
      row["status"] = "fulfillment_failed"
      row["detail"] = result["detail"].to_s
      write_ledger(ledger_path, ledger)
      @err.puts "WARNING: #{pool_id}: execution pool is not ready; continuing independent lanes."
      return
    end

    requirements = pool.fetch("requirements")
    workers = Array(result.fetch("worker_indices")).map { |value| Integer(value) }.uniq.sort
    raise Error, "#{pool_id}: ready fulfillment returned no workers" if workers.empty?
    pid = @campaign_launcher.launch(
      pool_id:,
      workers:,
      execution_handle: result.fetch("execution_handle"),
      requirements:,
      jobs_path:,
      campaign_dir:,
      queue_dir:,
      keep_fleet: keep_fleets
    )
    children[pool_id] = pid
    row["status"] = "running"
    row["campaign_pid"] = pid
    row["campaign_output"] = relative_path(campaign_dir)
    row["detail"] = "campaign launched"
    write_ledger(ledger_path, ledger)
    @out.puts "  #{pool_id}: READY on #{workers.length} worker(s); scoring pid #{pid} launched."
    flush(@out)
  end

  def wait_for_campaigns(children:, ledger:, ledger_path:)
    children.each do |pool_id, pid|
      exit_status = @campaign_launcher.wait(pid)
      row = ledger.fetch("pools").fetch(pool_id)
      campaign_dir = within_root(row.fetch("campaign_output"))
      status = summary_status(File.join(campaign_dir, "summary.json"))
      row["campaign_pid"] = nil
      row["status"] = case status
                      when "completed" then "completed"
                      when "workload_failed" then "workload_failed"
                      when nil then "infrastructure_failed"
                      else status
                      end
      row["detail"] = "campaign exit #{exit_status}; summary #{status.inspect}"
      write_ledger(ledger_path, ledger)
      @out.puts "  #{pool_id}: #{row['status']}."
      flush(@out)
    end
  end

  def validate_queue!(plan)
    queue_dir = within_root(plan.dig("queue", "path"))
    snapshot_path = File.join(queue_dir, "snapshot.yml")
    raise Error, "missing frozen queue snapshot #{snapshot_path}" unless File.file?(snapshot_path)
    actual_snapshot_sha = Digest::SHA256.file(snapshot_path).hexdigest
    expected_snapshot_sha = plan.dig("queue", "snapshot_sha256").to_s
    unless actual_snapshot_sha == expected_snapshot_sha
      raise Error, "frozen queue snapshot changed: expected #{expected_snapshot_sha}, got #{actual_snapshot_sha}"
    end

    order_path = File.join(queue_dir, "run_order.txt")
    actual_order_sha = Digest::SHA256.file(order_path).hexdigest
    expected_order_sha = plan.dig("queue", "run_order_sha256").to_s
    unless actual_order_sha == expected_order_sha
      raise Error, "frozen run order changed: expected #{expected_order_sha}, got #{actual_order_sha}"
    end

    [queue_dir, ProductionBacklogRunnerPolicy.contract_type_from_snapshot(snapshot_path)]
  end

  def manifest_jobs(pool, contract_type)
    Array(pool.fetch("manifests")).each_with_index.map do |entry, index|
      manifest_path = within_root(entry.fetch("path"))
      raise Error, "missing frozen manifest #{manifest_path}" unless File.file?(manifest_path)
      actual_sha = Digest::SHA256.file(manifest_path).hexdigest
      expected_sha = entry.fetch("sha256").to_s.downcase
      unless actual_sha == expected_sha
        raise Error, "frozen manifest changed: #{relative_path(manifest_path)} expected #{expected_sha}, got #{actual_sha}"
      end
      manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
      runtime_max_tokens = ProductionBacklogRunnerPolicy.runtime_max_tokens_for(contract_type:, manifest:)
      env = {}
      env["LME_RUNTIME_MAX_TOKENS"] = runtime_max_tokens.to_s if runtime_max_tokens
      {
        "job_id" => format("production-%04d", index + 1),
        "argv" => ["bin/lme-production-remote-job", entry.fetch("path")],
        "env" => env
      }
    end
  end

  def materialize_jobs(path, jobs)
    content = JSON.pretty_generate("jobs" => jobs) + "\n"
    if File.file?(path) && File.read(path) != content
      raise Error, "existing child jobs differ: #{path}; plan/output identity is not resumable"
    end
    write_atomic(path, content) unless File.file?(path)
  end

  def initial_ledger(plan_path, plan_sha, plan)
    {
      "contract_version" => LEDGER_CONTRACT,
      "plan" => {
        "path" => relative_path(plan_path),
        "sha256" => plan_sha
      },
      "queue" => plan.fetch("queue"),
      "status" => "pending",
      "pools" => Array(plan.fetch("pools")).to_h do |pool|
        [pool.fetch("pool_id"), {
          "pool_id" => pool.fetch("pool_id"),
          "status" => "pending",
          "execution_handle" => nil,
          "worker_indices" => [],
          "handoff_path" => nil,
          "campaign_output" => nil,
          "campaign_pid" => nil,
          "detail" => nil
        }]
      end
    }
  end

  def final_status(ledger:, dry_run:)
    statuses = ledger.fetch("pools").values.map { |row| row.fetch("status") }
    if dry_run
      statuses.all? { |status| %w[planned completed workload_failed unavailable].include?(status) } ? "planned" : "failed"
    elsif statuses.all? { |status| status == "completed" }
      "completed"
    elsif statuses.any? { |status| status == "workload_failed" }
      "workload_failed"
    elsif statuses.any? { |status| %w[fulfillment_failed infrastructure_failed failed unavailable].include?(status) }
      "incomplete"
    else
      "running"
    end
  end

  def exit_status_for(status)
    case status
    when "completed", "planned" then 0
    when "workload_failed" then 2
    else 1
    end
  end

  def print_header(plan_path:, plan_sha:, plan:)
    @out.puts "AFIO production burst"
    @out.puts "  Plan: #{relative_path(plan_path)}"
    @out.puts "  Plan SHA: #{plan_sha}"
    @out.puts "  Pools: #{Array(plan.fetch('pools')).map { |pool| pool.fetch('pool_id') }.join(', ')}"
    Array(plan.fetch("pools")).each do |pool|
      requirements = pool.fetch("requirements")
      @out.puts "  #{pool.fetch('pool_id')}: model_ref=#{pool.fetch('model_ref')} runtime=#{requirements.fetch('ollama_model')} digest=#{requirements.fetch('expected_digest')}"
    end
    @out.puts format("  Aggregate hourly ceiling: $%.4f/hr", Float(plan.dig("capacity", "max_total_hourly_usd")))
    @out.puts "  Failure policy: independent lanes continue; workload failures remain sticky."
    @out.puts "  Acquisition policy: paid pool fulfillment is serialized; ready scoring lanes overlap."
    flush(@out)
  end

  def within_root(path)
    expanded = File.expand_path(path, @root)
    prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
    raise Error, "path escapes repository root: #{expanded}" unless expanded == @root || expanded.start_with?(prefix)
    expanded
  end

  def relative_path(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
  rescue ArgumentError
    path.to_s
  end

  def write_atomic(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
    File.write(tmp, content)
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
  end

  def write_ledger(path, ledger)
    write_atomic(path, JSON.pretty_generate(ledger) + "\n")
  end

  def load_json(path, label)
    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError => e
    raise Error, "#{label} is unreadable: #{e.message}"
  end

  def summary_status(path)
    return nil unless File.file?(path)
    load_json(path, "campaign summary").fetch("status").to_s
  rescue KeyError
    nil
  end

  def flush(io)
    io.flush if io.respond_to?(:flush)
  end
end
