# frozen_string_literal: true

require "local_model_evaluation/config"
require "local_model_evaluation/worker"
require "local_model_evaluation/worker_check"

module ProductionBacklogDispatch
  class QualificationError < StandardError; end

  class LocalQualifiedArtifactGuard
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/i

    def initialize(repo_root:, worker_checker: LocalModelEvaluation::WorkerCheck.new)
      @repo_root = File.expand_path(repo_root)
      @worker_checker = worker_checker
    end

    def verify!(manifest:)
      manifest_path = File.expand_path(manifest, @repo_root)
      document = LocalModelEvaluation::Config.load_yaml(manifest_path)
      requirements = qualified_model_requirements(document, manifest)
      workers = configured_workers(document, manifest)

      workers.each do |worker|
        result = @worker_checker.check(
          worker,
          required_models: requirements.keys,
          required_model_digests: requirements
        )
        if result.error
          raise QualificationError,
                "qualified artifact check could not inspect worker #{worker.name}: #{result.error}"
        end
        unless result.missing_models.empty?
          raise QualificationError,
                "qualified artifact check missing model(s) on worker #{worker.name}: #{result.missing_models.join(', ')}"
        end
        next if result.digest_mismatches.empty?

        details = result.digest_mismatches.map do |model, mismatch|
          actual = mismatch["actual"] || "missing digest"
          "#{model} expected #{mismatch.fetch('expected')}, got #{actual}"
        end
        raise QualificationError,
              "qualified artifact digest mismatch on worker #{worker.name}: #{details.join('; ')}"
      end

      true
    rescue QualificationError
      raise
    rescue KeyError, Errno::ENOENT, ArgumentError, TypeError, Psych::Exception => e
      raise QualificationError, "production qualification input is incomplete: #{e.message}"
    end

    private

    def qualified_model_requirements(document, manifest)
      model_refs = Array(document["models"]).map(&:to_s).reject(&:empty?)
      if model_refs.empty?
        raise QualificationError, "production manifest has no model aliases: #{manifest}"
      end

      models_path = File.join(@repo_root, "config", "models.yml")
      models = LocalModelEvaluation::Config.load_yaml(models_path).fetch("models")
      model_refs.each_with_object({}) do |model_ref, out|
        attrs = models.fetch(model_ref)
        ollama_model = attrs["ollama_model"].to_s.strip
        digest = attrs["qualified_manifest_sha256"].to_s.strip.downcase
        if ollama_model.empty?
          raise QualificationError, "qualified model #{model_ref.inspect} has no ollama_model"
        end
        unless digest.match?(DIGEST_PATTERN)
          raise QualificationError,
                "qualified model #{model_ref.inspect} has no exact 64-hex qualified_manifest_sha256"
        end
        if out.key?(ollama_model) && out.fetch(ollama_model) != digest
          raise QualificationError,
                "qualified model aliases disagree on digest for #{ollama_model.inspect}"
        end
        out[ollama_model] = digest
      end
    end

    def configured_workers(document, manifest)
      worker_names = Array(document["workers"]).map(&:to_s).reject(&:empty?)
      if worker_names.empty?
        raise QualificationError, "production manifest has no workers: #{manifest}"
      end

      workers_path = ENV["LME_WORKERS_CONFIG"].to_s.strip
      workers_path = File.join("config", "workers.yml") if workers_path.empty?
      workers_path = File.expand_path(workers_path, @repo_root)
      workers = LocalModelEvaluation::Config.load_yaml(workers_path).fetch("workers")
      worker_names.map do |worker_name|
        LocalModelEvaluation::Worker.new(worker_name, workers.fetch(worker_name))
      end
    end
  end

  class SystemCommandAdapter
    def initialize(repo_root:)
      @repo_root = File.expand_path(repo_root)
    end

    def run(environment:, argv:)
      system(environment, *argv, chdir: @repo_root)
    end
  end

  class Runner
    def initialize(command_adapter:, lme_path: "bin/lme", artifact_guard: nil)
      @command_adapter = command_adapter
      @lme_path = lme_path
      @artifact_guard = artifact_guard
    end

    def dispatch(manifest:, runtime_max_tokens:)
      @artifact_guard&.verify!(manifest:)
      environment = {
        "AF_LLM_MAX_TOKENS" => runtime_max_tokens.to_s == "8192" ? "8192" : nil
      }
      @command_adapter.run(
        environment:,
        argv: [@lme_path, "run", manifest]
      )
    end
  end
end
