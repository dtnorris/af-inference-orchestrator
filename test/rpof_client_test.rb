# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/local_model_evaluation/rpof_client"

class RpofClientTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rpof-client-")
    @fake = File.join(@tmp, "rpof")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_capability_check_reads_versioned_result
    File.write(@fake, <<~'SH')
      #!/bin/sh
      set -eu
      output=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --output)
            output=$2
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      cat >"$output" <<'JSON'
      {"contract_version":"afio-rpof-capability-check-result/v0.1","ready":true,"fleet_key":"fixture","fleet_id":"fixture-fleet","selected_worker_indices":[1],"capabilities":null,"diagnostics":[]}
      JSON
    SH
    FileUtils.chmod(0o755, @fake)
    client = LocalModelEvaluation::RpofClient.new(repo_root: @tmp, executable: @fake)
    result = client.capability_check({ "fleet_key" => "fixture" })
    assert result.fetch("ready")
    assert_equal "fixture-fleet", result.fetch("fleet_id")
  end

  def test_worker_selector_expands_ranges_without_sixteen_worker_ceiling
    assert_equal [1, 2, 3, 32], LocalModelEvaluation::RpofClient.expand_worker_selector("1-3,32")
  end
end
