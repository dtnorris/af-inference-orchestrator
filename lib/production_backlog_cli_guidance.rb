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

    def render(step, io: $stdout)
      io.puts
      io.puts "Next command:"
      io.puts "  cd #{Shellwords.escape(step.fetch(:cwd))}"
      io.puts "  #{Shellwords.join(step.fetch(:argv))}"
    end
  end
end
