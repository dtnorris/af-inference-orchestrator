# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

class AdventureIngestRunnerTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def setup
    @root = Dir.mktmpdir('ingest-runner-routing')
    %w[
      run_production_backlog.sh
      lib/batch_failure_policy.sh
      lib/production_backlog_runner_policy.rb
      lib/production_backlog_runtime_contract.rb
      lib/production_backlog_dispatch.rb
      lib/production_backlog_cli_guidance.rb
      bin/production-backlog-policy
      bin/production-backlog-dispatch
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
      {
        'LME_REPO' => @root,
        'AF_LLM_MAX_TOKENS' => '99999',
        'AF_DATA_PIPELINE_ROOT' => File.join(@root, 'af-data-pipeline')
      },
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
  def test_finished_adventure_ingest_queue_prints_catalog_ingest_continuation
    executable('bin/verify-production-backlog', "#!/bin/sh\nexit 0\n")

    out, err, status = run_queue(queue('adventure_ingest_v1'))

    assert status.success?, err
    assert_includes out, "BACKGROUND PRODUCTION QUEUE FINISHED"
    assert_includes out, "Next command:"
    assert_includes out, File.join(@root, 'af-data-pipeline')
    assert_includes out, "production-ingest-prepare --batch 20"
    assert_includes out, "--inference-root #{@root}"
  end

end
