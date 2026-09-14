# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module LocalModelEvaluation
  class RpofClient
    class Error < StandardError; end

    def initialize(repo_root:, executable: nil)
      @repo_root = File.expand_path(repo_root)
      @executable = File.expand_path(executable || File.join(@repo_root, "bin", "lme-rpof"))
    end

    def capability_check(request)
      with_json_file(request) do |request_path|
        Tempfile.create(["rpof-capability-result", ".json"]) do |result|
          result.close
          stdout, stderr, status = Open3.capture3(
            @executable, "capability-check", "--request", request_path, "--output", result.path,
            chdir: @repo_root
          )
          raise Error, "RPOF capability-check rejected request (exit #{status.exitstatus}): #{stderr.strip}" if status.exitstatus == 2
          raise Error, "RPOF capability-check did not write result: #{stderr.strip}" unless File.file?(result.path) && File.size?(result.path)
          document = JSON.parse(File.read(result.path))
          unless document["contract_version"] == "afio-rpof-capability-check-result/v0.1"
            raise Error, "unsupported RPOF capability result version: #{document['contract_version'].inspect}"
          end
          return document
        end
      end
    rescue JSON::ParserError => e
      raise Error, "RPOF capability result is invalid JSON: #{e.message}"
    end

    def dispatch(request:, workdir:, output_dir:)
      with_json_file(request) do |request_path|
        stdout, stderr, status = Open3.capture3(
          @executable, "dispatch", "--request", request_path,
          "--workdir", File.expand_path(workdir), "--output", File.expand_path(output_dir),
          chdir: @repo_root
        )
        raise Error, "RPOF dispatch rejected request (exit #{status.exitstatus}): #{stderr.strip}" if status.exitstatus == 2
        summary_path = File.join(File.expand_path(output_dir), "summary.json")
        raise Error, "RPOF dispatch did not write summary: #{stderr.strip}" unless File.file?(summary_path)
        summary = JSON.parse(File.read(summary_path))
        unless summary["contract_version"] == "afio-rpof-dispatch-summary/v0.1"
          raise Error, "unsupported RPOF dispatch summary version: #{summary['contract_version'].inspect}"
        end
        [summary, status.exitstatus, stdout, stderr]
      end
    rescue JSON::ParserError => e
      raise Error, "RPOF dispatch summary is invalid JSON: #{e.message}"
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
      raise Error, "worker indices must be positive" unless values.all?(&:positive?)
      values.uniq.sort
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
