# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module LocalModelEvaluation
  class RpofClient
    class Error < StandardError; end

    CAPABILITY_RESULT_CONTRACT = "afio-rpof-capability-check-result/v0.1"
    EXECUTION_POOL_RESULT_CONTRACT = "afio-rpof-execution-pool-fulfill-result/v0.1"
    DISPATCH_SUMMARY_CONTRACT = "afio-rpof-dispatch-summary/v0.1"

    def initialize(repo_root:, executable: nil)
      @repo_root = File.expand_path(repo_root)
      @executable = File.expand_path(executable || File.join(@repo_root, "bin", "lme-rpof"))
    end

    def capability_check(request)
      with_json_file(request) do |request_path|
        Tempfile.create(["rpof-capability-result", ".json"]) do |result|
          result.close
          _stdout, stderr, status = Open3.capture3(
            *self.class.capability_command(
              executable: @executable,
              request_path:,
              output_path: result.path
            ),
            chdir: @repo_root
          )
          raise Error, "RPOF capability-check rejected request (exit #{status.exitstatus}): #{stderr.strip}" if status.exitstatus == 2
          raise Error, "RPOF capability-check did not write result: #{stderr.strip}" unless File.file?(result.path) && File.size?(result.path)
          document = JSON.parse(File.read(result.path))
          return self.class.validate_result_contract!(
            document,
            expected: CAPABILITY_RESULT_CONTRACT,
            label: "RPOF capability result"
          )
        end
      end
    rescue JSON::ParserError => e
      raise Error, "RPOF capability result is invalid JSON: #{e.message}"
    end

    def fulfill_execution_pool(request:, dry_run: false, assume_yes: false, stream_output: false)
      with_json_file(request) do |request_path|
        Tempfile.create(["rpof-execution-pool-result", ".json"]) do |result|
          result.close
          command = self.class.fulfillment_command(
            executable: @executable,
            request_path:,
            output_path: result.path,
            dry_run:,
            assume_yes:
          )

          if stream_output
            system(*command, chdir: @repo_root)
            status = $?
            raise Error, "RPOF execution-pool fulfillment did not start" unless status
            stdout = ""
            stderr = ""
          else
            stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
          end

          if status.exitstatus == 2
            raise Error, "RPOF execution-pool fulfillment rejected request: #{stderr.strip}"
          end
          unless File.file?(result.path) && File.size?(result.path)
            raise Error, "RPOF execution-pool fulfillment did not write result: #{stderr.strip}"
          end
          document = JSON.parse(File.read(result.path))
          self.class.validate_result_contract!(
            document,
            expected: EXECUTION_POOL_RESULT_CONTRACT,
            label: "RPOF execution-pool result"
          )
          return [document, status.exitstatus, stdout, stderr]
        end
      end
    rescue JSON::ParserError => e
      raise Error, "RPOF execution-pool result is invalid JSON: #{e.message}"
    end

    def dispatch(request:, workdir:, output_dir:, stream_output: false, dynamic_worker_admission: false)
      with_json_file(request) do |request_path|
        command = self.class.dispatch_command(
          executable: @executable,
          request_path:,
          workdir:,
          output_dir:,
          dynamic_worker_admission:
        )
        if stream_output
          system(*command, chdir: @repo_root)
          status = $?
          raise Error, "RPOF dispatch did not start" unless status

          stdout = ""
          stderr = ""
        else
          stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
        end
        raise Error, "RPOF dispatch rejected request (exit #{status.exitstatus}): #{stderr.strip}" if status.exitstatus == 2
        summary_path = File.join(File.expand_path(output_dir), "summary.json")
        raise Error, "RPOF dispatch did not write summary: #{stderr.strip}" unless File.file?(summary_path)
        summary = JSON.parse(File.read(summary_path))
        self.class.validate_result_contract!(
          summary,
          expected: DISPATCH_SUMMARY_CONTRACT,
          label: "RPOF dispatch summary"
        )
        [summary, status.exitstatus, stdout, stderr]
      end
    rescue JSON::ParserError => e
      raise Error, "RPOF dispatch summary is invalid JSON: #{e.message}"
    end

    def admit_dispatch_worker(fleet_key:, output_dir:, worker_index:)
      command = self.class.dispatch_admit_command(
        executable: @executable,
        fleet_key:,
        output_dir:,
        worker_index:
      )
      stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
      unless status.success?
        detail = stderr.to_s.strip
        detail = stdout.to_s.strip if detail.empty?
        raise Error, "RPOF dispatch admission failed (exit #{status.exitstatus}): #{detail}"
      end
      stdout.to_s.strip
    end

    def scale_fleet(fleet_key:, worker_count:, max_hourly_usd:, max_total_hourly_usd:)
      command = self.class.scale_command(
        executable: @executable,
        fleet_key:,
        worker_count:,
        max_hourly_usd:,
        max_total_hourly_usd:
      )
      stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
      unless status.success?
        detail = stderr.to_s.strip
        detail = stdout.to_s.strip if detail.empty?
        raise Error, "RPOF fleet rollback failed (exit #{status.exitstatus}): #{detail}"
      end
      stdout.to_s.strip
    rescue ArgumentError, TypeError => e
      raise Error, "invalid RPOF fleet rollback request: #{e.message}"
    end

    def close_dispatch_admissions(fleet_key:, output_dir:)
      command = self.class.dispatch_close_command(
        executable: @executable,
        fleet_key:,
        output_dir:
      )
      stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
      unless status.success?
        detail = stderr.to_s.strip
        detail = stdout.to_s.strip if detail.empty?
        raise Error, "RPOF dispatch admission close failed (exit #{status.exitstatus}): #{detail}"
      end
      stdout.to_s.strip
    end

    def terminal_shutdown(fleet_key:, worker_indices:, inactivity_minutes: 5.0, drain_timeout_minutes: 10.0, reason: "afio_campaign_terminal")
      command = self.class.terminal_shutdown_command(
        executable: @executable,
        fleet_key:,
        worker_indices:,
        inactivity_minutes:,
        drain_timeout_minutes:,
        reason:
      )
      stdout, stderr, status = Open3.capture3(*command, chdir: @repo_root)
      unless status.success?
        detail = stderr.to_s.strip
        detail = stdout.to_s.strip if detail.empty?
        raise Error, "RPOF terminal shutdown handoff failed (exit #{status.exitstatus}): #{detail}"
      end
      stdout.to_s.strip
    rescue ArgumentError, TypeError => e
      raise Error, "invalid terminal shutdown request: #{e.message}"
    end

    def self.capability_command(executable:, request_path:, output_path:)
      [executable, "capability-check", "--request", request_path, "--output", output_path]
    end

    def self.fulfillment_command(executable:, request_path:, output_path:, dry_run: false, assume_yes: false)
      command = [executable, "execution-pool-fulfill", "--request", request_path, "--output", output_path]
      command << "--dry-run" if dry_run
      command << "--yes" if assume_yes
      command
    end

    def self.dispatch_command(executable:, request_path:, workdir:, output_dir:, dynamic_worker_admission: false)
      command = [
        executable, "dispatch", "--request", request_path,
        "--workdir", File.expand_path(workdir), "--output", File.expand_path(output_dir)
      ]
      command << "--dynamic-worker-admission" if dynamic_worker_admission
      command
    end

    def self.dispatch_admit_command(executable:, fleet_key:, output_dir:, worker_index:)
      [
        executable, "dispatch-admit",
        "--fleet", fleet_key.to_s,
        "--output", File.expand_path(output_dir),
        "--worker", Integer(worker_index).to_s
      ]
    end

    def self.scale_command(executable:, fleet_key:, worker_count:, max_hourly_usd:, max_total_hourly_usd:)
      [
        executable, "scale",
        "--fleet", fleet_key.to_s,
        "--workers", Integer(worker_count).to_s,
        "--max-hourly-usd", Float(max_hourly_usd).to_s,
        "--max-total-hourly-usd", Float(max_total_hourly_usd).to_s,
        "--yes"
      ]
    end

    def self.dispatch_close_command(executable:, fleet_key:, output_dir:)
      [
        executable, "dispatch-close",
        "--fleet", fleet_key.to_s,
        "--output", File.expand_path(output_dir)
      ]
    end

    def self.terminal_shutdown_command(executable:, fleet_key:, worker_indices:, inactivity_minutes:, drain_timeout_minutes:, reason:)
      indices = normalize_worker_indices(worker_indices)
      raise Error, "terminal shutdown requires at least one worker" if indices.empty?

      [
        executable, "shutdown",
        "--fleet", fleet_key.to_s,
        "--workers", indices.join(","),
        "--terminal",
        "--inactive-minutes", Float(inactivity_minutes).to_s,
        "--drain-timeout-minutes", Float(drain_timeout_minutes).to_s,
        "--reason", reason.to_s
      ]
    end

    def self.validate_result_contract!(document, expected:, label:)
      return document if document["contract_version"] == expected

      raise Error, "unsupported #{label} version: #{document['contract_version'].inspect}"
    end

    def self.normalize_worker_indices(values)
      Array(values).map { |value| Integer(value) }.uniq.sort
    end

    def self.expand_worker_selector(value)
      text = value.to_s.strip
      raise Error, "worker selector cannot be empty" if text.empty?
      values = text.split(",").flat_map do |part|
        if part.match?(/\A\d+\z/)
          [Integer(part)]
        elsif (match = part.match(/\A(\d+)-(\d+)\z/))
          first = Integer(match[1])
          last = Integer(match[2])
          raise Error, "invalid descending worker range #{part.inspect}" if last < first
          (first..last).to_a
        else
          raise Error, "invalid worker selector component #{part.inspect}"
        end
      end
      values = normalize_worker_indices(values)
      raise Error, "worker indices must be positive" unless values.all?(&:positive?)
      values
    end

    private

    def with_json_file(document)
      Tempfile.create(["rpof-request", ".json"]) do |file|
        file.write(JSON.pretty_generate(document) + "\n")
        file.flush
        yield file.path
      end
    end
  end
end
