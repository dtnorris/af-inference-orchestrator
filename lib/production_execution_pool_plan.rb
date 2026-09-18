# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "yaml"
require_relative "production_burst_budget_contract"

class ProductionExecutionPoolPlan
  CONTRACT_VERSION = "afio-production-execution-pool-plan/v0.1"
  POLICY_CONTRACT_VERSION = "afio-production-execution-pool-policy/v0.1"
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/i
  POOL_ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/

  class Error < StandardError; end

  def initialize(root:, model_config_path: nil, policy_path: nil)
    @root = File.expand_path(root)
    @model_config_path = expand_config_path(model_config_path || File.join("config", "models.yml"))
    @policy_path = expand_config_path(policy_path || File.join("config", "production_execution_pools.yml"))
  end

  def build(queue_path:, budget_id:, desired_workers: {}, minimum_workers: {}, max_pool_hourly_usd: {},
            max_total_hourly_usd: nil, required_context_length: nil,
            max_cumulative_compute_usd: nil, max_runtime_seconds: nil, guardian_poll_seconds: nil,
            orchestrator_heartbeat_timeout_seconds: nil, teardown_reserve_seconds: nil)
    policy = load_policy
    models = load_models
    overrides = normalize_overrides(
      desired_workers:,
      minimum_workers:,
      max_pool_hourly_usd:
    )
    validate_override_pool_ids!(overrides, policy.fetch("pools"))

    context = positive_integer(
      required_context_length || policy.fetch("required_context_length"),
      "required context length"
    )
    total_cap = positive_float(
      max_total_hourly_usd || policy.fetch("max_total_hourly_usd"),
      "max total hourly cost"
    )
    budget_policy = policy.fetch("budget")
    budget = ProductionBurstBudgetContract.build(
      budget_id:,
      max_cumulative_compute_usd: value_or_default(
        max_cumulative_compute_usd, budget_policy.fetch("max_cumulative_compute_usd")
      ),
      max_runtime_seconds: value_or_default(
        max_runtime_seconds, budget_policy.fetch("max_runtime_seconds")
      ),
      guardian_poll_seconds: value_or_default(
        guardian_poll_seconds, budget_policy.fetch("guardian_poll_seconds")
      ),
      orchestrator_heartbeat_timeout_seconds: value_or_default(
        orchestrator_heartbeat_timeout_seconds,
        budget_policy.fetch("orchestrator_heartbeat_timeout_seconds")
      ),
      teardown_reserve_seconds: value_or_default(
        teardown_reserve_seconds, budget_policy.fetch("teardown_reserve_seconds")
      )
    )

    queue_dir = expand_queue(queue_path)
    order_path = File.join(queue_dir, "run_order.txt")
    snapshot_path = File.join(queue_dir, "snapshot.yml")
    require_file!(order_path, "frozen run order")
    require_file!(snapshot_path, "frozen queue snapshot")

    entries = File.readlines(order_path, chomp: true).map(&:strip).reject(&:empty?)
    raise Error, "frozen queue is empty: #{relative_path(order_path)}" if entries.empty?

    policy_by_model_ref = policy.fetch("pools").to_h do |pool_id, attrs|
      [attrs.fetch("model_ref"), [pool_id, attrs]]
    end
    manifests_by_pool = Hash.new { |hash, key| hash[key] = [] }

    entries.each do |manifest_entry|
      manifest_path = expand_manifest(manifest_entry)
      require_file!(manifest_path, "frozen manifest")
      manifest = load_yaml(manifest_path, "frozen manifest")

      workers = Array(manifest["workers"]).map(&:to_s)
      unless workers == ["mac"]
        raise Error,
              "execution-pool planning requires workers: [mac]: #{relative_path(manifest_path)}"
      end

      model_refs = Array(manifest["models"]).map(&:to_s).reject(&:empty?)
      unless model_refs.length == 1
        raise Error,
              "execution-pool planning requires exactly one frozen manifest model: #{relative_path(manifest_path)}"
      end
      model_ref = model_refs.fetch(0)
      pool = policy_by_model_ref[model_ref]
      unless pool
        raise Error,
              "no execution pool maps frozen model #{model_ref.inspect}: #{relative_path(manifest_path)}"
      end

      pool_id, = pool
      manifests_by_pool[pool_id] << {
        "path" => relative_path(manifest_path),
        "sha256" => Digest::SHA256.file(manifest_path).hexdigest
      }
    end

    pools = manifests_by_pool.keys.sort.map do |pool_id|
      attrs = policy.fetch("pools").fetch(pool_id)
      model_ref = attrs.fetch("model_ref")
      model = qualified_model!(models, model_ref)
      desired = positive_integer(
        overrides.fetch(:desired_workers).fetch(pool_id, attrs.fetch("desired_workers")),
        "#{pool_id} desired workers"
      )
      minimum = positive_integer(
        overrides.fetch(:minimum_workers).fetch(pool_id, attrs.fetch("minimum_workers")),
        "#{pool_id} minimum workers"
      )
      if minimum > desired
        raise Error, "#{pool_id} minimum workers #{minimum} exceeds desired workers #{desired}"
      end
      pool_cap = positive_float(
        overrides.fetch(:max_pool_hourly_usd).fetch(pool_id, attrs.fetch("max_pool_hourly_usd")),
        "#{pool_id} max pool hourly cost"
      )

      manifests = manifests_by_pool.fetch(pool_id)
      {
        "pool_id" => pool_id,
        "model_ref" => model_ref,
        "requirements" => {
          "ollama_model" => model.fetch("ollama_model"),
          "pull_model" => model.fetch("pull_model"),
          "expected_digest" => model.fetch("qualified_manifest_sha256").downcase,
          "required_context_length" => context,
          "require_fully_gpu_resident" => true
        },
        "capacity" => {
          "desired_workers" => desired,
          "minimum_workers" => minimum,
          "max_pool_hourly_usd" => pool_cap
        },
        "job_count" => manifests.length,
        "manifests" => manifests
      }
    end

    {
      "contract_version" => CONTRACT_VERSION,
      "queue" => {
        "path" => relative_path(queue_dir),
        "run_order_sha256" => Digest::SHA256.file(order_path).hexdigest,
        "snapshot_sha256" => Digest::SHA256.file(snapshot_path).hexdigest,
        "manifest_count" => entries.length
      },
      "capacity" => {
        "max_total_hourly_usd" => total_cap
      },
      "budget" => budget,
      "pools" => pools
    }
  rescue ProductionBurstBudgetContract::Error => e
    raise Error, e.message
  rescue KeyError => e
    raise Error, "execution-pool configuration is missing required key: #{e.message}"
  end

  private

  def load_policy
    policy = load_yaml(@policy_path, "execution-pool policy")
    unless policy["contract_version"] == POLICY_CONTRACT_VERSION
      raise Error,
            "execution-pool policy contract must be #{POLICY_CONTRACT_VERSION.inspect}"
    end
    positive_integer(policy["required_context_length"], "required context length")
    positive_float(policy["max_total_hourly_usd"], "max total hourly cost")
    budget_policy = policy["budget"]
    raise Error, "execution-pool policy budget must be a mapping" unless budget_policy.is_a?(Hash)
    budget_policy = budget_policy.transform_keys(&:to_s)
    unless budget_policy["contract_version"].to_s == ProductionBurstBudgetContract::CONTRACT_VERSION
      raise Error,
            "execution-pool policy budget contract must be #{ProductionBurstBudgetContract::CONTRACT_VERSION.inspect}"
    end
    ProductionBurstBudgetContract.build(
      budget_id: "policy-validation",
      max_cumulative_compute_usd: budget_policy.fetch("max_cumulative_compute_usd"),
      max_runtime_seconds: budget_policy.fetch("max_runtime_seconds"),
      guardian_poll_seconds: budget_policy.fetch("guardian_poll_seconds"),
      orchestrator_heartbeat_timeout_seconds: budget_policy.fetch("orchestrator_heartbeat_timeout_seconds"),
      teardown_reserve_seconds: budget_policy.fetch("teardown_reserve_seconds")
    )
    pools = policy["pools"]
    raise Error, "execution-pool policy pools must be a non-empty mapping" unless pools.is_a?(Hash) && !pools.empty?

    seen_model_refs = {}
    normalized = pools.each_with_object({}) do |(raw_pool_id, raw_attrs), out|
      pool_id = raw_pool_id.to_s
      raise Error, "invalid execution pool id #{pool_id.inspect}" unless pool_id.match?(POOL_ID_PATTERN)
      raise Error, "execution pool #{pool_id} must be a mapping" unless raw_attrs.is_a?(Hash)

      attrs = raw_attrs.transform_keys(&:to_s)
      model_ref = attrs.fetch("model_ref").to_s.strip
      raise Error, "execution pool #{pool_id} has an empty model_ref" if model_ref.empty?
      if (other = seen_model_refs[model_ref])
        raise Error,
              "model_ref #{model_ref.inspect} is mapped by multiple execution pools: #{other}, #{pool_id}"
      end
      seen_model_refs[model_ref] = pool_id

      desired = positive_integer(attrs.fetch("desired_workers"), "#{pool_id} desired workers")
      minimum = positive_integer(attrs.fetch("minimum_workers"), "#{pool_id} minimum workers")
      raise Error, "#{pool_id} minimum workers #{minimum} exceeds desired workers #{desired}" if minimum > desired
      positive_float(attrs.fetch("max_pool_hourly_usd"), "#{pool_id} max pool hourly cost")

      out[pool_id] = attrs.merge("model_ref" => model_ref)
    end

    policy.merge("budget" => budget_policy, "pools" => normalized)
  end

  def load_models
    data = load_yaml(@model_config_path, "model config")
    models = data["models"]
    raise Error, "model config models must be a non-empty mapping" unless models.is_a?(Hash) && !models.empty?
    models.transform_keys(&:to_s)
  end

  def qualified_model!(models, model_ref)
    model = models[model_ref]
    raise Error, "execution pool references unknown model #{model_ref.inspect}" unless model.is_a?(Hash)
    model = model.transform_keys(&:to_s)

    ollama_model = model["ollama_model"].to_s.strip
    pull_model = model["pull_model"].to_s.strip
    digest = model["qualified_manifest_sha256"].to_s.strip
    raise Error, "qualified model #{model_ref.inspect} has no ollama_model" if ollama_model.empty?
    raise Error, "qualified model #{model_ref.inspect} has no pull_model" if pull_model.empty?
    unless digest.match?(DIGEST_PATTERN)
      raise Error, "qualified model #{model_ref.inspect} has no exact 64-hex qualified_manifest_sha256"
    end

    {
      "ollama_model" => ollama_model,
      "pull_model" => pull_model,
      "qualified_manifest_sha256" => digest
    }
  end

  def normalize_overrides(desired_workers:, minimum_workers:, max_pool_hourly_usd:)
    {
      desired_workers: stringify_keys(desired_workers),
      minimum_workers: stringify_keys(minimum_workers),
      max_pool_hourly_usd: stringify_keys(max_pool_hourly_usd)
    }
  end

  def validate_override_pool_ids!(overrides, pools)
    known = pools.keys
    overrides.each_value do |values|
      unknown = values.keys - known
      next if unknown.empty?
      raise Error, "override references unknown execution pool(s): #{unknown.sort.join(', ')}"
    end
  end

  def stringify_keys(hash)
    Hash(hash).to_h { |key, value| [key.to_s, value] }
  rescue TypeError
    raise Error, "execution-pool overrides must be mappings"
  end

  def expand_config_path(path)
    expanded = File.expand_path(path.to_s, @root)
    ensure_within_root!(expanded, "configuration path")
    expanded
  end

  def expand_queue(path)
    expanded = File.expand_path(path.to_s, @root)
    ensure_within_root!(expanded, "queue path")
    raise Error, "queue directory not found: #{relative_path(expanded)}" unless File.directory?(expanded)
    expanded
  end

  def expand_manifest(path)
    expanded = File.expand_path(path.to_s, @root)
    ensure_within_root!(expanded, "manifest path")
    expanded
  end

  def ensure_within_root!(path, label)
    root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
    return if path == @root || path.start_with?(root_prefix)
    raise Error, "#{label} escapes repository root: #{path}"
  end

  def relative_path(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
  rescue ArgumentError
    path.to_s
  end

  def require_file!(path, label)
    raise Error, "missing #{label}: #{relative_path(path)}" unless File.file?(path)
  end

  def load_yaml(path, label)
    require_file!(path, label)
    data = YAML.safe_load_file(path, aliases: true)
    raise Error, "#{label} must contain a mapping: #{relative_path(path)}" unless data.is_a?(Hash)
    data.transform_keys(&:to_s)
  rescue Psych::Exception => e
    raise Error, "invalid YAML in #{relative_path(path)}: #{e.message}"
  end

  def value_or_default(value, default)
    value.nil? ? default : value
  end

  def positive_integer(value, label)
    integer = Integer(value)
    raise ArgumentError unless integer.positive?
    integer
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a positive integer"
  end

  def positive_float(value, label)
    number = Float(value)
    raise ArgumentError unless number.positive? && number.finite?
    number
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be a positive finite number"
  end
end
