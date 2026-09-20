# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

class ProductionBurstStatus
  LEDGER_CONTRACT = "afio-production-burst-ledger/v0.1"
  PLAN_CONTRACT = "afio-production-execution-pool-plan/v0.1"

  def initialize(root:)
    @root = File.expand_path(root)
  end

  def render(ledger_arg)
    ledger_path = within_root(ledger_arg)
    raise "production-burst ledger not found: #{ledger_path}" unless File.file?(ledger_path)

    ledger = JSON.parse(File.read(ledger_path))
    unless ledger["contract_version"] == LEDGER_CONTRACT
      raise "unsupported production-burst ledger version: #{ledger['contract_version'].inspect}"
    end

    plan_ref = ledger.fetch("plan")
    plan_path = within_root(plan_ref.fetch("path"))
    raise "execution-pool plan not found: #{plan_path}" unless File.file?(plan_path)

    plan_bytes = File.binread(plan_path)
    actual_plan_sha = Digest::SHA256.hexdigest(plan_bytes)
    expected_plan_sha = plan_ref.fetch("sha256").to_s.downcase
    unless actual_plan_sha == expected_plan_sha
      raise "execution-pool plan SHA mismatch: expected #{expected_plan_sha}, got #{actual_plan_sha}"
    end

    plan = JSON.parse(plan_bytes)
    unless plan["contract_version"] == PLAN_CONTRACT
      raise "unsupported execution-pool plan version: #{plan['contract_version'].inspect}"
    end

    ledger_pools = ledger.fetch("pools")
    raise "production-burst ledger pools must be a mapping" unless ledger_pools.is_a?(Hash)

    lines = [
      "AFIO production burst status",
      "  Ledger: #{relative_path(ledger_path)}",
      "  Status: #{ledger.fetch('status')}",
      "  Plan: #{relative_path(plan_path)}",
      "  Plan SHA: #{actual_plan_sha}",
      "  Queue: #{ledger.dig('queue', 'path') || plan.dig('queue', 'path')}"
    ]

    Array(plan.fetch("pools")).each do |pool|
      pool_id = pool.fetch("pool_id").to_s
      row = ledger_pools.fetch(pool_id)
      requirements = pool.fetch("requirements")
      workers = Array(row["worker_indices"]).map(&:to_s)
      detail = row["detail"].to_s

      lines << "  #{pool_id}: #{row.fetch('status')}"
      lines << "    model_ref: #{pool.fetch('model_ref')}"
      lines << "    runtime_model: #{requirements.fetch('ollama_model')}"
      lines << "    qualified_digest: #{requirements.fetch('expected_digest')}"
      lines << "    workers: #{workers.empty? ? '-' : workers.join(', ')}"
      lines << "    execution_handle: #{row['execution_handle'] || '-'}"
      lines << "    campaign_pid: #{row['campaign_pid'] || '-'}"
      lines << "    detail: #{detail.empty? ? '-' : detail}"
    end

    lines.join("\n") + "\n"
  end

  private

  def within_root(path)
    expanded = File.expand_path(path, @root)
    prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
    raise "path escapes repository root: #{expanded}" unless expanded == @root || expanded.start_with?(prefix)
    expanded
  end

  def relative_path(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
  rescue ArgumentError
    path.to_s
  end
end
