# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'
require_relative '../lib/production_backlog_runtime_contract'

class AdventureIngestRunnerTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def setup
    @root = Dir.mktmpdir('ingest-runner-routing')
    %w[
      run_production_backlog.sh
      lib/batch_failure_policy.sh
      lib/production_backlog_runner_policy.rb
      lib/production_backlog_runtime_contract.rb
      bin/production-backlog-policy
    ].each do |path|
      target = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(ROOT, path), target)
    end
    executable('bin/preflight-production-backlog-sources', "#!/bin/sh\nexit 0\n")
    executable('bin/classify-production-failure', "#!/bin/sh\nexit 1\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def executable(path, text)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, text)
    FileUtils.chmod(0o755, target)
  end

  def queue(contract, manifests = [])
    path = File.join(@root, 'production_backlog/production-backlog-020')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'snapshot.yml'), YAML.dump('contract_type' => contract))
    File.write(File.join(path, 'run_order.txt'), manifests.join("\n") + "\n")
    path
  end

  def run_queue(path)
    Open3.capture3(
      {'LME_REPO' => @root, 'AF_LLM_MAX_TOKENS' => '99999'},
      'bash',
      File.join(@root, 'run_production_backlog.sh'),
      path
    )
  end

  def test_runner_uses_policy_selected_verifier_and_stops_at_source_gate
    executable(
      'bin/verify-production-backlog',
      "#!/bin/sh\ntouch \"$LME_REPO/verifier-called\"\nexit 0\n"
    )
    executable(
      'bin/preflight-production-backlog-sources',
      "#!/bin/sh\ntouch \"$LME_REPO/source-preflight-called\"\nexit 1\n"
    )
    executable(
      'bin/lme',
      "#!/bin/sh\ntouch \"$LME_REPO/inference-called\"\nexit 0\n"
    )

    out, err, status = run_queue(queue('adventure_ingest_v1'))

    refute status.success?
    assert File.exist?(File.join(@root, 'verifier-called'))
    assert File.exist?(File.join(@root, 'source-preflight-called'))
    refute File.exist?(File.join(@root, 'inference-called'))
    assert_match(/runtime source preflight failed\. No inference launched\./, out + err)
  end

  def test_runtime_amendment_reaches_lme_and_caller_override_is_cleared
    executable('bin/verify-production-backlog', "#!/bin/sh\nexit 0\n")
    executable('bin/lme', <<~'SCRIPT')
      #!/bin/sh
      set -eu
      [ "${1:-}" = "run" ] || { echo "only fixture run allowed" >&2; exit 2; }
      manifest="${2:?manifest required}"
      case_name="$(basename "$manifest" .yml)"
      printf '%s\t%s\n' "$case_name" "${AF_LLM_MAX_TOKENS-}" >> dispatch.tsv
      mkdir -p "output/$case_name/runs/fixture"
      printf '{"status":"complete"}\n' > "output/$case_name/runs/fixture/metadata.json"
    SCRIPT

    core = ProductionBacklogRuntimeContract::QWEN35_CORE_DIMENSIONS.first
    cases = [
      ['core', core, '8192'],
      ['excluded', 'Levels', nil]
    ]
    FileUtils.mkdir_p(File.join(@root, 'experiments'))
    paths = cases.map do |name, dimension, _expected_tokens|
      path = "experiments/#{name}.yml"
      File.write(
        File.join(@root, path),
        YAML.dump(
          'name' => name,
          'dimension' => dimension,
          'models' => ['qwen'],
          'production_contract' => {'contract_type' => 'adventure_ingest_v1'}
        )
      )
      path
    end

    out, err, status = run_queue(queue('adventure_ingest_v1', paths))
    assert status.success?, out + err
    calls = File.readlines(File.join(@root, 'dispatch.tsv'), chomp: true).map do |line|
      name, tokens = line.split("\t", -1)
      [name, tokens.empty? ? nil : tokens]
    end
    assert_equal cases.map { |name, _dimension, expected_tokens| [name, expected_tokens] }, calls
  end
end
