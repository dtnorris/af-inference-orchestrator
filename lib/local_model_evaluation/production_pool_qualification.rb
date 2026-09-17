# frozen_string_literal: true

require "yaml"

module LocalModelEvaluation
  module ProductionPoolQualification
    module_function

    def verify_current_qualification!(pool, models_path:)
      model_ref = pool.fetch("model_ref").to_s.strip
      raise "execution pool has an empty model_ref" if model_ref.empty?

      requirements = pool.fetch("requirements")
      planned = {
        "ollama_model" => requirements.fetch("ollama_model").to_s,
        "pull_model" => requirements.fetch("pull_model").to_s,
        "expected_digest" => requirements.fetch("expected_digest").to_s.downcase
      }

      document = YAML.safe_load_file(models_path, aliases: true) || {}
      models = document.fetch("models")
      raise "current model config models must be a mapping" unless models.is_a?(Hash)
      current_attrs = models[model_ref]
      unless current_attrs.is_a?(Hash)
        raise "current qualification does not match execution-pool plan: model_ref #{model_ref.inspect} is not currently qualified"
      end

      current = {
        "ollama_model" => current_attrs["ollama_model"].to_s.strip,
        "pull_model" => current_attrs["pull_model"].to_s.strip,
        "expected_digest" => current_attrs["qualified_manifest_sha256"].to_s.strip.downcase
      }
      %w[ollama_model pull_model].each do |field|
        if current.fetch(field).empty?
          raise "current qualification for model_ref #{model_ref.inspect} is incomplete: #{field}"
        end
      end
      unless current.fetch("expected_digest").match?(/\A[0-9a-f]{64}\z/)
        raise "current qualification for model_ref #{model_ref.inspect} is incomplete: qualified_manifest_sha256"
      end

      mismatches = planned.each_with_object([]) do |(field, planned_value), rows|
        current_value = current.fetch(field)
        next if current_value == planned_value

        rows << "#{field} plan=#{planned_value.inspect} current=#{current_value.inspect}"
      end
      unless mismatches.empty?
        raise "current qualification does not match execution-pool plan for model_ref #{model_ref.inspect}: #{mismatches.join('; ')}"
      end

      current
    rescue Psych::Exception, SystemCallError => e
      raise "cannot verify current qualified model configuration: #{e.message}"
    end
  end
end
