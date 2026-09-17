# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module LocalModelEvaluation
  class WorkerCheck
    Result = Struct.new(
      :worker,
      :ok,
      :version,
      :models,
      :model_digests,
      :error,
      :missing_models,
      :missing_labels,
      :digest_mismatches,
      keyword_init: true
    )

    def initialize(open_timeout: 3, read_timeout: 10)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def check(worker, required_models: [], required_labels: [], required_model_digests: {})
      required_digests = required_model_digests.to_h.each_with_object({}) do |(model, digest), out|
        out[model.to_s] = digest.to_s.strip.downcase
      end
      required_model_names = (Array(required_models).map(&:to_s) + required_digests.keys).uniq
      missing_labels = Array(required_labels).map(&:to_s) - worker.labels
      version_data = get_json(worker.base_url, "/api/version")
      tags_data = get_json(worker.base_url, "/api/tags")
      tag_rows = Array(tags_data["models"])
      models = tag_rows.map { |row| row["name"] || row["model"] }.compact.map(&:to_s)
      model_digests = tag_rows.each_with_object({}) do |row, out|
        digest = row["digest"].to_s.strip.downcase
        next if digest.empty?

        [row["name"], row["model"]].compact.map(&:to_s).reject(&:empty?).uniq.each do |name|
          out[name] = digest
        end
      end
      missing_models = required_model_names.reject do |model|
        models.include?(model) || models.any? { |available| available.start_with?("#{model}:") }
      end
      digest_mismatches = required_digests.each_with_object({}) do |(model, expected), out|
        actual = digest_for(model_digests, model)
        next if actual == expected

        out[model] = { "expected" => expected, "actual" => actual }
      end
      Result.new(
        worker:,
        ok: missing_models.empty? && missing_labels.empty? && digest_mismatches.empty?,
        version: version_data["version"],
        models:,
        model_digests:,
        missing_models:,
        missing_labels:,
        digest_mismatches:
      )
    rescue StandardError => e
      Result.new(
        worker:,
        ok: false,
        error: "#{e.class}: #{e.message}",
        models: [],
        model_digests: {},
        missing_models: [],
        missing_labels: missing_labels || [],
        digest_mismatches: {}
      )
    end

    private

    def digest_for(model_digests, model)
      return model_digests[model] if model_digests.key?(model)

      normalized = model.sub(/:latest\z/, "")
      match = model_digests.find do |available, _digest|
        available.sub(/:latest\z/, "") == normalized
      end
      match&.last
    end

    def get_json(base_url, path)
      uri = URI.join("#{base_url}/", path.sub(%r{^/}, ""))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      response = http.get(uri.request_uri)
      raise "HTTP #{response.code} from #{uri}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end
  end
end
