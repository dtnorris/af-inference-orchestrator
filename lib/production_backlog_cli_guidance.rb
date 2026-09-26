# frozen_string_literal: true

require "shellwords"

module AdventureIngest
  module ProductionBacklogCliGuidance
    module_function

    def after_build(root:, invocation_cwd:, original_argv:, dry_run:, queue:)
      if dry_run
        {
          cwd: File.expand_path(invocation_cwd),
          argv: [
            File.join(File.expand_path(root), "bin", "build-production-backlog"),
            *Array(original_argv).reject { |arg| arg == "--dry-run" }
          ]
        }
      else
        {
          cwd: File.expand_path(root),
          argv: [
            "./run_production_backlog.sh",
            File.join("production_backlog", queue)
          ]
        }
      end
    end

    def after_run(root:, queue:, contract_type:, data_pipeline_root: nil)
      return nil unless contract_type.to_s == "adventure_ingest_v1"

      queue_name = File.basename(queue.to_s)
      match = /\Aproduction-backlog-(\d+)\z/.match(queue_name)
      raise ArgumentError, "cannot derive production batch number from #{queue.inspect}" unless match

      batch = Integer(match[1], 10)
      raise ArgumentError, "production batch number must be positive" unless batch.positive?

      inference_root = File.expand_path(root)
      pipeline_root = File.expand_path(
        data_pipeline_root || File.join(File.dirname(inference_root), "af-data-pipeline")
      )

      {
        cwd: pipeline_root,
        argv: [
          File.join(pipeline_root, "bin", "af-data"),
          "production-ingest-prepare",
          "--batch", batch.to_s,
          "--inference-root", inference_root
        ]
      }
    end

    def render_after_run(root:, queue:, contract_type:, data_pipeline_root: nil, io: $stdout)
      step = after_run(
        root:,
        queue:,
        contract_type:,
        data_pipeline_root:
      )
      render(step, io:) if step
      step
    end

    def render(step, io: $stdout)
      io.puts
      io.puts "Next command:"
      io.puts "  cd #{Shellwords.escape(step.fetch(:cwd))}"
      io.puts "  #{Shellwords.join(step.fetch(:argv))}"
    end
  end
end
