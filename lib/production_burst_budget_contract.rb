# frozen_string_literal: true

require "digest"

module ProductionBurstBudgetContract
  CONTRACT_VERSION = "afio-production-burst-budget/v0.1"
  DECLARATION_KEYS = %w[
    contract_version
    budget_id
    max_cumulative_compute_usd
    max_runtime_seconds
    guardian_poll_seconds
    orchestrator_heartbeat_timeout_seconds
    teardown_reserve_seconds
  ].freeze
  LIMIT_KEYS = %w[
    max_cumulative_compute_usd
    max_runtime_seconds
    guardian_poll_seconds
    orchestrator_heartbeat_timeout_seconds
    teardown_reserve_seconds
  ].freeze
  IDENTITY_KEYS = %w[budget_id plan_sha256].freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/i

  class Error < StandardError; end

  module_function

  def build(budget_id:, max_cumulative_compute_usd:, max_runtime_seconds:, guardian_poll_seconds:,
            orchestrator_heartbeat_timeout_seconds:, teardown_reserve_seconds:)
    validate_declaration!(
      "contract_version" => CONTRACT_VERSION,
      "budget_id" => budget_id,
      "max_cumulative_compute_usd" => max_cumulative_compute_usd,
      "max_runtime_seconds" => max_runtime_seconds,
      "guardian_poll_seconds" => guardian_poll_seconds,
      "orchestrator_heartbeat_timeout_seconds" => orchestrator_heartbeat_timeout_seconds,
      "teardown_reserve_seconds" => teardown_reserve_seconds
    )
  end

  def validate_declaration!(budget)
    raise Error, "production burst budget must be a mapping" unless budget.is_a?(Hash)

    data = budget.transform_keys(&:to_s)
    missing = DECLARATION_KEYS - data.keys
    unknown = data.keys - DECLARATION_KEYS
    raise Error, "production burst budget is missing field(s): #{missing.join(', ')}" unless missing.empty?
    raise Error, "production burst budget has unknown field(s): #{unknown.join(', ')}" unless unknown.empty?
    unless data.fetch("contract_version").to_s == CONTRACT_VERSION
      raise Error, "production burst budget contract must be #{CONTRACT_VERSION.inspect}"
    end

    budget_id = data.fetch("budget_id").to_s
    raise Error, "production burst budget_id must be non-empty" if budget_id.strip.empty?

    normalized = {
      "contract_version" => CONTRACT_VERSION,
      "budget_id" => budget_id
    }
    LIMIT_KEYS.each do |key|
      normalized[key] = positive_number(data.fetch(key), "budget.#{key}")
    end

    if normalized.fetch("orchestrator_heartbeat_timeout_seconds") <
       (2.0 * normalized.fetch("guardian_poll_seconds"))
      raise Error,
            "budget.orchestrator_heartbeat_timeout_seconds must be at least 2 * budget.guardian_poll_seconds"
    end

    normalized
  rescue KeyError => e
    raise Error, "production burst budget is missing required field: #{e.message}"
  end

  def plan_sha256(plan_bytes)
    Digest::SHA256.hexdigest(plan_bytes)
  end

  def identity_for(budget:, plan_sha256:)
    declaration = validate_declaration!(budget)
    {
      "budget_id" => declaration.fetch("budget_id"),
      "plan_sha256" => normalize_plan_sha(plan_sha256)
    }
  end

  def request_budget(budget:, plan_sha256:)
    declaration = validate_declaration!(budget)
    identity = identity_for(budget: declaration, plan_sha256:)
    {
      "contract_version" => CONTRACT_VERSION,
      "budget_id" => identity.fetch("budget_id"),
      "plan_sha256" => identity.fetch("plan_sha256"),
      "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
      "max_runtime_seconds" => declaration.fetch("max_runtime_seconds"),
      "guardian_poll_seconds" => declaration.fetch("guardian_poll_seconds"),
      "orchestrator_heartbeat_timeout_seconds" => declaration.fetch("orchestrator_heartbeat_timeout_seconds"),
      "teardown_reserve_seconds" => declaration.fetch("teardown_reserve_seconds")
    }
  end

  def validate_identity!(identity, budget:, plan_sha256:, label: "production burst budget identity")
    raise Error, "#{label} must be a mapping" unless identity.is_a?(Hash)

    data = identity.transform_keys(&:to_s)
    missing = IDENTITY_KEYS - data.keys
    unknown = data.keys - IDENTITY_KEYS
    raise Error, "#{label} is missing field(s): #{missing.join(', ')}" unless missing.empty?
    raise Error, "#{label} has unknown field(s): #{unknown.join(', ')}" unless unknown.empty?

    expected = identity_for(budget:, plan_sha256:)
    actual = {
      "budget_id" => data.fetch("budget_id").to_s,
      "plan_sha256" => normalize_plan_sha(data.fetch("plan_sha256"))
    }
    raise Error, "#{label} does not match frozen (budget_id, plan_sha256)" unless actual == expected

    expected
  end

  def positive_number(value, label)
    number = Float(value)
    raise ArgumentError unless number.positive? && number.finite?
    number
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a strictly positive finite number"
  end
  private_class_method :positive_number

  def normalize_plan_sha(value)
    sha = value.to_s
    raise Error, "plan_sha256 must be an exact 64-hex digest" unless sha.match?(DIGEST_PATTERN)
    sha.downcase
  end
  private_class_method :normalize_plan_sha
end
