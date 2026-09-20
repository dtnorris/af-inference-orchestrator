# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "production_execution_pool_plan"

class ProductionExecutionPoolPlanWriter
  def initialize(root:)
    @root = File.expand_path(root)
  end

  def write(plan:, output:)
    output_path = within_root(output)
    FileUtils.mkdir_p(File.dirname(output_path))
    content = JSON.pretty_generate(plan) + "\n"
    if File.file?(output_path) && File.read(output_path) != content
      raise ProductionExecutionPoolPlan::Error,
            "existing execution-pool plan differs: #{output_path}; use a new --output path or remove it"
    end
    write_atomic(output_path, content) unless File.file?(output_path)
    output_path
  end

  private

  def within_root(path)
    output_path = File.expand_path(path, @root)
    root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
    unless output_path == @root || output_path.start_with?(root_prefix)
      raise ProductionExecutionPoolPlan::Error, "output path escapes repository root: #{output_path}"
    end
    output_path
  end

  def write_atomic(output_path, content)
    tmp = "#{output_path}.tmp.#{$$}"
    begin
      File.write(tmp, content)
      File.rename(tmp, output_path)
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
  end
end
