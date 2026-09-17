# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "digest"

class ProductionBurstStatusTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("production-burst-status-")
    @plan_path = File.join(@tmp, "output", "plan.json")
    @ledger_path = File.join(@tmp, "output", "burst", "production-burst.json")
    FileUtils.mkdir_p(File.dirname(@plan_path))
    FileUtils.mkdir_p(File.dirname(@ledger_path))
    write_plan
    write_ledger
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_reports_failed_burst_and_exact_frozen_model_identity_without_mutation
    plan_before = File.binread(@plan_path)
    ledger_before = File.binread(@ledger_path)

    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(ROOT, "bin", "lme-production-burst-status"),
      "output/burst/production-burst.json"
    )

    assert status.success?, out + err
    assert_includes out, "Status: workload_failed"
    assert_includes out, "qwen35: workload_failed"
    assert_includes out, "model_ref: qwen"
    assert_includes out, "runtime_model: qwen3.6:35b-a3b"
    assert_includes out, "qualified_digest: #{DIGEST}"
    assert_includes out, "workers: 1, 3"
    assert_includes out, "detail: fixture workload failure"
    assert_equal plan_before, File.binread(@plan_path)
    assert_equal ledger_before, File.binread(@ledger_path)
  end

  def test_rejects_ledger_when_referenced_plan_sha_no_longer_matches
    ledger = JSON.parse(File.read(@ledger_path))
    ledger.fetch("plan")["sha256"] = "b" * 64
    File.write(@ledger_path, JSON.pretty_generate(ledger) + "\n")

    out, err, status = Open3.capture3(
      { "LME_REPO" => @tmp },
      RbConfig.ruby,
      File.join(ROOT, "bin", "lme-production-burst-status"),
      "output/burst/production-burst.json"
    )

    refute status.success?, out
    assert_includes err, "execution-pool plan SHA mismatch"
  end

  private

  def write_plan
    plan = {
      "contract_version" => "afio-production-execution-pool-plan/v0.1",
      "queue" => { "path" => "production_backlog/fixture" },
      "capacity" => { "max_total_hourly_usd" => 3.0 },
      "pools" => [{
        "pool_id" => "qwen35",
        "model_ref" => "qwen",
        "requirements" => {
          "ollama_model" => "qwen3.6:35b-a3b",
          "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
          "expected_digest" => DIGEST,
          "required_context_length" => 131_072,
          "require_fully_gpu_resident" => true
        }
      }]
    }
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
  end

  def write_ledger
    ledger = {
      "contract_version" => "afio-production-burst-ledger/v0.1",
      "plan" => {
        "path" => "output/plan.json",
        "sha256" => Digest::SHA256.file(@plan_path).hexdigest
      },
      "queue" => { "path" => "production_backlog/fixture" },
      "status" => "workload_failed",
      "pools" => {
        "qwen35" => {
          "pool_id" => "qwen35",
          "status" => "workload_failed",
          "execution_handle" => "ep-qwen35",
          "worker_indices" => [1, 3],
          "handoff_path" => "output/burst/pools/qwen35/handoff.json",
          "campaign_output" => "output/burst/pools/qwen35/campaign",
          "campaign_pid" => nil,
          "detail" => "fixture workload failure"
        }
      }
    }
    File.write(@ledger_path, JSON.pretty_generate(ledger) + "\n")
  end
end
