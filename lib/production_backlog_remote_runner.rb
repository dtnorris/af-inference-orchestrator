# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "production_backlog_runner_policy"
require_relative "production_backlog_remote_campaign"
require_relative "local_model_evaluation/rpof_client"

module ProductionBacklogRemoteRunner
  class Error < StandardError; end

  class ProcessPreflight
    def initialize(repo_root:)
      @repo_root = File.expand_path(repo_root)
    end

    def call(queue_arg:, contract_type:)
      verifier = File.join(@repo_root, ProductionBacklogRunnerPolicy.verifier_for(contract_type))
      source_preflight = File.join(@repo_root, "bin", "preflight-production-backlog-sources")
      raise Error, "missing/executable verifier #{verifier}" unless File.executable?(verifier)
      raise Error, "missing/executable runtime source preflight #{source_preflight}" unless File.executable?(source_preflight)

      unless system({ "LME_REPO" => @repo_root }, verifier, queue_arg, chdir: @repo_root)
        raise Error, "backlog preflight failed. No remote inference launched."
      end
      unless system({ "LME_REPO" => @repo_root }, source_preflight, queue_arg, chdir: @repo_root)
        raise Error, "runtime source preflight failed. No remote inference launched."
      end
    end
  end

  class Runner
    def initialize(repo_root:, preflight:, client:, env: ENV, stdout: $stdout, stderr: $stderr)
      @repo_root = File.expand_path(repo_root)
      @preflight = preflight
      @client = client
      @env = env
      @stdout = stdout
      @stderr = stderr
    end

    def run(queue_arg:, workers:, all:, output:, fleet:, group_by_model:, context:)
      queue_dir = File.expand_path(queue_arg, @repo_root)
      order_path = File.join(queue_dir, "run_order.txt")
      snapshot_path = File.join(queue_dir, "snapshot.yml")
      raise Error, "missing #{order_path}" unless File.file?(order_path)
      raise Error, "missing #{snapshot_path}" unless File.file?(snapshot_path)

      contract_type = ProductionBacklogRunnerPolicy.contract_type_from_snapshot(snapshot_path)
      @preflight.call(queue_arg:, contract_type:)

      manifests = File.readlines(order_path, chomp: true).reject { |line| line.strip.empty? }
      raise Error, "frozen queue is empty: #{order_path}" if manifests.empty?

      fleet_key = fleet || @env.fetch("LME_RUNPOD_FLEET", "default")
      worker_selector = if all
                          { "mode" => "all" }
                        else
                          {
                            "mode" => "indices",
                            "indices" => LocalModelEvaluation::RpofClient.expand_worker_selector(workers)
                          }
                        end

      plan = ProductionBacklogRemoteCampaign.build_plan(
        repo_root: @repo_root,
        contract_type:,
        manifests:,
        group_by_model:,
        fleet_key:,
        worker_selector:,
        required_context: context
      )
      jobs = plan.fetch("jobs")
      qualified_models = plan.fetch("qualified_models")

      output_dir = File.expand_path(output, @repo_root)
      jobs_path = "#{output_dir}.jobs.json"
      write_jobs_ledger(jobs_path:, jobs:)

      @env["AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE"] = "phase6-v0.3"
      @env["AF_INVESTIGATION_GUARDRAIL_PROFILE"] = "phase6-v0.4"

      capability = capability_check(plan.fetch("capability_request"))
      unless capability.fetch("ready")
        details = capability.fetch("diagnostics").select { |row| row["status"] == "FAIL" }.map { |row| "#{row['code']}: #{row['detail']}" }
        raise Error, "RPOF capability check failed: #{details.join('; ')}"
      end

      dispatch_request = ProductionBacklogRemoteCampaign.build_dispatch_request(plan:, capability:)
      report_campaign(
        queue_arg:,
        jobs:,
        output_dir:,
        jobs_path:,
        group_by_model:,
        qualified_models:,
        fleet_key:,
        capability:
      )

      summary = dispatch(dispatch_request:, output_dir:)
      case summary.fetch("status")
      when "completed" then 0
      when "workload_failed" then 2
      else 1
      end
    rescue ProductionBacklogRemoteCampaign::Error => e
      raise Error, e.message
    end

    private

    def write_jobs_ledger(jobs_path:, jobs:)
      FileUtils.mkdir_p(File.dirname(jobs_path))
      jobs_content = JSON.pretty_generate("jobs" => jobs) + "\n"
      if File.file?(jobs_path) && File.read(jobs_path) != jobs_content
        raise Error, "existing remote campaign jobs differ: #{jobs_path}; use a new --output path"
      end
      return if File.file?(jobs_path)

      tmp = "#{jobs_path}.tmp.#{$$}"
      begin
        File.write(tmp, jobs_content)
        File.rename(tmp, jobs_path)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    end

    def capability_check(request)
      @client.capability_check(request)
    rescue LocalModelEvaluation::RpofClient::Error => e
      raise Error, "RPOF capability bridge failed: #{e.message}"
    end

    def dispatch(dispatch_request:, output_dir:)
      summary, _rpof_exit, stdout, stderr = @client.dispatch(
        request: dispatch_request,
        workdir: @repo_root,
        output_dir:
      )
      @stdout.write(stdout) unless stdout.empty?
      @stderr.write(stderr) unless stderr.empty?
      summary
    rescue LocalModelEvaluation::RpofClient::Error => e
      raise Error, "RPOF dispatch bridge failed: #{e.message}"
    end

    def report_campaign(queue_arg:, jobs:, output_dir:, jobs_path:, group_by_model:, qualified_models:, fleet_key:, capability:)
      @stdout.puts "Remote production campaign"
      @stdout.puts "  Queue: #{queue_arg}"
      @stdout.puts "  Frozen manifests: #{jobs.length}"
      @stdout.puts "  Dispatch evidence: #{output_dir}"
      @stdout.puts "  Job ledger: #{jobs_path}"
      @stdout.puts "  Model grouping: #{group_by_model ? 'enabled' : 'disabled (FIFO)'}"
      @stdout.puts "  Qualified artifacts:"
      qualified_models.each do |model|
        @stdout.puts "    #{model.fetch('model_ref')}: runtime=#{model.fetch('ollama_model')} pull=#{model.fetch('pull_model')} digest=#{model.fetch('expected_digest')}"
      end
      @stdout.puts "  RPOF fleet: #{fleet_key} / #{capability.fetch('fleet_id')}"
      @stdout.puts "  RPOF workers: #{capability.fetch('selected_worker_indices').join(', ')}"
      @stdout.puts "  Frozen manifests are read-only; remote routing is execution-time only."
    end
  end
end
