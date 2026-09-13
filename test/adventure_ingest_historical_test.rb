# frozen_string_literal: true
require_relative 'test_helper'
require_relative '../lib/adventure_ingest_verifier'

class AdventureIngestHistoricalTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # Uses the real committed snapshots, runtime bytes, indices and every manifest.
  # Catalog IO and host checks are separate integration gates, not mocked PASSes here.
  def test_all_historical_packages_keep_their_frozen_execution_semantics
    %w[016 017 018 019].each do |number|
      verifier = AdventureIngest::Verifier.new(root: ROOT, queue_path: "production_backlog/production-backlog-#{number}")
      batch = verifier.batch
      snapshot = verifier.snapshot
      assert_equal batch.dimension_contracts, snapshot.fetch('dimension_contracts')
      assert_equal AdventureIngest::Batch::DEFERRED_COLUMNS, snapshot.fetch('deferred_columns')
      verifier.verify_runtime!
      derived = snapshot.merge(
        'levels_contract' => batch.levels_contract,
        'selected_adventures' => snapshot.fetch('selected_adventures').map { |a| a.merge('needs_levels' => a.fetch('needs_levels', false)) }
      )
      batch.instance_variable_set(:@catalog_sha256, snapshot.fetch('catalog_sha256'))
      verifier.verify_manifests!(derived)
      operations = batch.operations(derived)
      assert_equal snapshot.fetch('expected_calls'), operations.length
      next unless number == '019'
      assert_equal 36, snapshot.fetch('expected_adventure_count')
      assert_equal 432, operations.length
      assert_equal (429..464).map { |id| format('ADV-%04d', id) }, snapshot.fetch('adventure_order')
      assert_equal snapshot.fetch('adventure_order'), snapshot.fetch('levels_inference_adventure_ids')
      assert_equal %w[ADV-0447 ADV-0460], snapshot.fetch('source_boundary_clamp_adventure_ids')
      assert_equal({'ADV-0447' => 2}, snapshot.fetch('source_boundary_clamp_max_gaps'))
    end
  end
end
