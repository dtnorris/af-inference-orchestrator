# frozen_string_literal: true
require_relative "test_helper"

class WorkerCheckTest < Minitest::Test
  class StubWorkerCheck < LocalModelEvaluation::WorkerCheck
    def initialize(version: "0.33.2", models: ["qwen3.6:27b"])
      @version = version
      @models = models
    end

    private

    def get_json(_base_url, path)
      return { "version" => @version } if path == "/api/version"
      if path == "/api/tags"
        rows = @models.map { |model| model.is_a?(Hash) ? model : { "name" => model } }
        return { "models" => rows }
      end
      raise "unexpected path #{path}"
    end
  end

  def test_required_worker_labels_make_an_otherwise_healthy_worker_ineligible
    worker = LocalModelEvaluation::Worker.new(
      "burst_1",
      "base_url" => "http://127.0.0.1:11441",
      "labels" => %w[remote burst a40]
    )

    result = StubWorkerCheck.new.check(
      worker,
      required_models: ["qwen3.6:27b"],
      required_labels: %w[remote burst nvidia a40 48gb]
    )

    refute result.ok
    assert_equal %w[nvidia 48gb], result.missing_labels
    assert_empty result.missing_models
    assert_nil result.error
  end

  def test_required_model_and_labels_pass_when_worker_satisfies_both
    worker = LocalModelEvaluation::Worker.new(
      "burst_1",
      "base_url" => "http://127.0.0.1:11441",
      "labels" => %w[remote burst nvidia a40 48gb]
    )

    result = StubWorkerCheck.new.check(
      worker,
      required_models: ["qwen3.6:27b"],
      required_labels: %w[remote burst nvidia a40 48gb]
    )

    assert result.ok
    assert_empty result.missing_labels
    assert_empty result.missing_models
    assert_equal "0.33.2", result.version
  end

  def test_required_model_digest_is_retained_and_compared_exactly
    digest = "a" * 64
    worker = LocalModelEvaluation::Worker.new(
      "mac",
      "base_url" => "http://127.0.0.1:11434"
    )
    checker = StubWorkerCheck.new(
      models: [{ "name" => "qwen3.6:27b", "digest" => digest }]
    )

    result = checker.check(
      worker,
      required_model_digests: { "qwen3.6:27b" => digest }
    )

    assert result.ok
    assert_equal digest, result.model_digests.fetch("qwen3.6:27b")
    assert_empty result.missing_models
    assert_empty result.digest_mismatches
  end

  def test_required_model_digest_mismatch_fails_even_when_model_name_is_present
    expected = "a" * 64
    actual = "b" * 64
    worker = LocalModelEvaluation::Worker.new(
      "mac",
      "base_url" => "http://127.0.0.1:11434"
    )
    checker = StubWorkerCheck.new(
      models: [{ "name" => "qwen3.6:27b", "digest" => actual }]
    )

    result = checker.check(
      worker,
      required_model_digests: { "qwen3.6:27b" => expected }
    )

    refute result.ok
    assert_empty result.missing_models
    assert_equal(
      { "qwen3.6:27b" => { "expected" => expected, "actual" => actual } },
      result.digest_mismatches
    )
  end
end
