# frozen_string_literal: true
require_relative 'test_helper'
require_relative '../lib/adventure_ingest_verifier'

class AdventureIngestTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  class FixtureBatch < AdventureIngest::Batch
    attr_accessor :rows, :active_sha
    def catalog_path_for(_repo)
      File.join(root, catalog_filename)
    end
    def read_rows(_path)
      Marshal.load(Marshal.dump(rows))
    end
    def git_head(_repo)
      active_sha || 'a' * 40
    end
    def scorer_check!
      git_head(scorer_repo)
    end

    def source_preflight(scorer_repo, catalog_path, adventure_id)
      config = {
        'files' => {'catalog' => File.basename(catalog_path)},
        'source' => {
          'allow_inward_boundary_clamp_adventure_ids' => clamp_ids,
          'inward_boundary_clamp_max_gap_by_adventure' => clamp_gaps
        }
      }
      File.open(File.join(scorer_repo, 'preflight_ids.txt'), 'a') { |f| f.puts adventure_id }
      File.write(File.join(scorer_repo, "preflight-#{adventure_id}.yml"), YAML.dump(config))
      return [false, 'missing canonical page marker'] if File.file?(File.join(scorer_repo, 'fail'))

      [true, '']
    end
  end

  def setup
    @root = Dir.mktmpdir('adventure-ingest-test')
    FileUtils.mkdir_p(File.join(@root, 'production_backlog'))
    paths = AdventureIngest::Batch::QUALIFICATION_PATHS.values + AdventureIngest::Batch::RUNTIME_SOURCE_PATHS.values + ['config/models.yml']
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      FileUtils.cp(File.join(ROOT, path), File.join(@root, path))
    end
    @scorer = File.join(@root, 'scorer')
    FileUtils.mkdir_p(File.join(@scorer, 'bin'))
    File.write(File.join(@scorer, 'bin/af-score'), <<~'SH')
      #!/bin/sh
      set -eu
      config=""
      preflight=0
      adventure_id=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --config) config="${2:?config required}"; shift 2 ;;
          --preflight) preflight=1; shift ;;
          --model|--dimension) shift 2 ;;
          *) adventure_id="$1"; shift ;;
        esac
      done
      [ "$preflight" -eq 1 ] || { echo "inference prohibited in fixture" >&2; exit 2; }
      [ -n "$config" ] || { echo "missing config" >&2; exit 2; }
      [ -n "$adventure_id" ] || { echo "missing adventure id" >&2; exit 2; }
      printf '%s\n' "$adventure_id" >> preflight_ids.txt
      cp "$config" "preflight-$adventure_id.yml"
      if [ -f fail ]; then
        echo "missing canonical page marker" >&2
        exit 1
      fi
    SH
    FileUtils.chmod(0o755, File.join(@scorer, 'bin/af-score'))
    @batch = make_batch
    @rows = make_rows
    @batch.rows = @rows
    File.write(File.join(@root, 'catalog.xlsx'), 'fixture catalog bytes')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def make_batch(**options)
    FixtureBatch.new(root: @root, batch: '020', catalog: 'catalog.xlsx', ids: ['ADV-0001..ADV-0002'], scorer_repo: @scorer, **options)
  end

  def make_rows
    headers = ['Adventure ID', 'Adventure Title', 'Source Book', 'Book Publisher', 'Page Count', 'Start Page', 'End Page', 'Level Start', 'Level End',
               *@batch.dimension_contracts.map { |d| d.fetch('catalog_column') }, *AdventureIngest::Batch::DEFERRED_COLUMNS]
    [headers, ['ADV-0002', 'Second', 'Book', 'Publisher', 2, 3, 4, 1, 2], ['ADV-0001', 'First', 'Book', 'Publisher', 1, 1, 1, nil, nil]]
  end

  def build(**options)
    result = nil
    capture_io { result = @batch.build(**options) }
    result
  end

  def verifier
    v = AdventureIngest::Verifier.new(root: @root, queue_path: @batch.queue_dir)
    v.instance_variable_set(:@batch, @batch)
    v
  end

  def change_yaml(path)
    data = YAML.safe_load_file(path, aliases: true)
    yield data
    File.write(path, YAML.dump(data))
  end

  def test_range_and_exact_ids
    assert_equal %w[ADV-0001 ADV-0002 ADV-0003], AdventureIngest::Batch.parse_ids(['ADV-0001..ADV-0002', 'ADV-0003'])
    assert_equal %w[ADV-0003 ADV-0001], AdventureIngest::Batch.parse_ids('ADV-0003,ADV-0001')
  end

  def test_invalid_duplicate_and_descending_selectors
    ['', 'ADV-1', 'ADV-0002..ADV-0001', 'ADV-0001,ADV-0001', 'ADV-0001..ADV-0002,ADV-0002'].each do |spec|
      assert_raises(AdventureIngest::Error) { AdventureIngest::Batch.parse_ids(spec) }
    end
  end

  def test_catalog_order_is_preserved
    assert_equal %w[ADV-0002 ADV-0001], @batch.select_targets(@rows).map { |r| r.fetch('id') }
  end

  def test_missing_and_duplicate_catalog_ids_fail
    assert_raises(AdventureIngest::Error) { @batch.select_targets(@rows.take(2)) }
    assert_raises(AdventureIngest::Error) { @batch.select_targets(@rows + [@rows.last]) }
  end

  def test_levels_derive_and_preserve
    targets = @batch.select_targets(@rows)
    assert_equal [false, true], targets.map { |t| t.fetch('needs_levels') }
    assert_equal [1, 2], targets.first.values_at('level_start', 'level_end')
    @rows.last[7] = 1
    assert_raises(AdventureIngest::Error) { @batch.select_targets(@rows) }
  end

  def test_scores_and_deferred_fields_must_be_blank
    [9, @rows.first.index(AdventureIngest::Batch::DEFERRED_COLUMNS.first)].each do |column|
      rows = Marshal.load(Marshal.dump(@rows))
      rows.last[column] = 2
      assert_raises(AdventureIngest::Error) { @batch.select_targets(rows) }
    end
  end

  def test_deferred_columns_may_be_absent_from_baseline_catalog
    deferred = AdventureIngest::Batch::DEFERRED_COLUMNS
    headers = @rows.first
    keep_indexes = headers.each_index.reject { |index| deferred.include?(headers[index]) }
    rows = @rows.map do |row|
      keep_indexes.map { |index| row[index] }
    end

    assert_equal %w[ADV-0002 ADV-0001], @batch.select_targets(rows).map { |target| target.fetch('id') }
  end

  def test_page_envelope_remains_frozen
    @rows.last[4] = 100
    assert_raises(AdventureIngest::Error) { @batch.select_targets(@rows) }
  end

  def test_call_calculation_and_snapshot
    snapshot = build
    assert_equal [22, 1, 23], snapshot.values_at('expected_ordinary_calls', 'expected_levels_calls', 'expected_calls')
    assert_equal 2, snapshot.fetch('expected_adventure_count')
    assert_equal ['ADV-0001'], snapshot.fetch('levels_inference_adventure_ids')
    assert_equal ['ADV-0002'], snapshot.fetch('preserved_levels_adventure_ids')
    assert_equal Digest::SHA256.hexdigest('fixture catalog bytes'), snapshot.fetch('catalog_sha256')
    assert_equal 'a' * 40, snapshot.fetch('scorer_commit')
    assert_equal 'a' * 40, snapshot.fetch('local_model_eval_commit')
    snapshot.fetch('qualification_files').each { |path, sha| assert_equal Digest::SHA256.file(File.join(@root, path)).hexdigest, sha }
    snapshot.fetch('runtime_files').each_value { |info| assert_equal Digest::SHA256.file(File.join(@root, info.fetch('path'))).hexdigest, info.fetch('sha256') }
    assert_equal snapshot.fetch('manifest_order'), File.readlines(File.join(@batch.queue_dir, 'run_order.txt'), chomp: true)
  end

  def test_preflight_reports_all_failures_without_materializing
    File.write(File.join(@scorer, 'fail'), '')
    error = assert_raises(AdventureIngest::Error) { build }
    assert_match(/ADV-0001 — First:.*missing canonical page marker/m, error.message)
    assert_match(/ADV-0002 — Second:.*missing canonical page marker/m, error.message)
    refute File.exist?(@batch.queue_dir)
    refute File.exist?(@batch.experiment_dir)
    assert_equal %w[ADV-0002 ADV-0001], File.readlines(File.join(@scorer, 'preflight_ids.txt'), chomp: true)
  end

  def test_force_failure_preserves_existing_package
    build
    snapshot_path = File.join(@batch.queue_dir, 'snapshot.yml')
    before = File.binread(snapshot_path)
    File.write(File.join(@scorer, 'fail'), '')
    assert_raises(AdventureIngest::Error) { build(force: true) }
    assert_equal before, File.binread(snapshot_path)
    assert_equal 23, Dir.glob(File.join(@batch.experiment_dir, '*.yml')).length
  end

  def test_force_refuses_any_prior_output
    build
    assert_raises(AdventureIngest::Error) { build }
    partial = File.join(@root, 'output', 'production-backlog-020-qwen-test', 'runs', 'partial')
    FileUtils.mkdir_p(partial)
    assert_raises(AdventureIngest::Error) { build(force: true) }
  end

  def test_dry_run_preflights_but_writes_no_queue
    snapshot = build(dry_run: true)
    assert_equal 23, snapshot.fetch('expected_calls')
    assert File.file?(File.join(@scorer, 'preflight_ids.txt'))
    refute File.exist?(@batch.queue_dir)
    refute File.exist?(@batch.experiment_dir)
  end

  def test_clamp_default_and_explicit_exception_do_not_leak
    @batch = make_batch(clamp_ids: %w[ADV-0001 ADV-0002], clamp_gaps: {'ADV-0001' => 2})
    @batch.rows = @rows
    snapshot = build
    assert_equal %w[ADV-0001 ADV-0002], snapshot.fetch('source_boundary_clamp_adventure_ids')
    assert_equal({'ADV-0001' => 2}, snapshot.fetch('source_boundary_clamp_max_gaps'))
    snapshot.fetch('runtime_files').each_value do |info|
      source = YAML.safe_load_file(File.join(@root, info.fetch('path'))).fetch('source')
      assert_equal({'ADV-0001' => 2}, source.fetch('inward_boundary_clamp_max_gap_by_adventure'))
      refute source.key?('inward_boundary_clamp_max_gap')
      refute source.fetch('inward_boundary_clamp_max_gap_by_adventure').key?('ADV-0002')
    end
    preflights = Dir.glob(File.join(@scorer, 'preflight-*.yml')).sort.map { |path| YAML.safe_load_file(path) }
    assert_equal 2, preflights.length
    preflights.each { |config| assert_equal({'ADV-0001' => 2}, config.dig('source', 'inward_boundary_clamp_max_gap_by_adventure')) }
  end

  def test_unapproved_or_global_clamp_override_fails
    assert_raises(AdventureIngest::Error) { make_batch(clamp_gaps: {'ADV-0001' => 2}) }
    assert_raises(AdventureIngest::Error) { make_batch(clamp_ids: ['ADV-0099']) }
    assert_raises(AdventureIngest::Error) { make_batch(clamp_ids: ['ADV-0001'], clamp_gaps: {'ADV-0001' => '2'}) }
  end

  def test_manifest_order_is_adventure_major_with_conditional_levels_last
    snapshot = build
    manifests = snapshot.fetch('manifest_order').map { |p| YAML.safe_load_file(File.join(@root, p)) }
    assert_equal ['ADV-0002'] * 11 + ['ADV-0001'] * 12, manifests.map { |m| m.fetch('adventures').first }
    names = @batch.dimension_contracts.map { |d| d.fetch('name') }
    assert_equal names + names + ['Levels'], manifests.map { |m| m.fetch('dimension') }
  end

  def test_verifier_accepts_valid_generated_fixture
    build
    assert_equal 23, verifier.verify_artifacts!.fetch('expected_calls')
  end

  def test_verifier_rejects_runtime_content_even_if_hash_is_updated
    snapshot = build
    info = snapshot.fetch('runtime_files').fetch('base')
    path = File.join(@root, info.fetch('path'))
    change_yaml(path) { |s| s['llm'] = {'max_tokens' => 16_384} }
    change_yaml(File.join(@batch.queue_dir, 'snapshot.yml')) { |s| s['runtime_files']['base']['sha256'] = Digest::SHA256.file(path).hexdigest }
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
  end

  def test_verifier_rejects_catalog_and_qualification_drift
    build
    File.write(File.join(@root, 'catalog.xlsx'), 'changed bytes')
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
    File.write(File.join(@root, 'catalog.xlsx'), 'fixture catalog bytes')
    path = File.join(@root, AdventureIngest::Batch::QUALIFICATION_PATHS.fetch('nos'))
    File.open(path, 'a') { |f| f.puts '# changed' }
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
  end

  def test_verifier_rejects_manifest_contract_mutations
    snapshot = build
    path = File.join(@root, snapshot.fetch('manifest_order').first)
    original = File.read(path)
    mutations = [
      ->(m) { m['replicates'] = 2 },
      ->(m) { m['production_contract']['catalog_sha256'] = 'bad' },
      ->(m) { m['production_contract']['candidate_model'] = 'gemma' },
      ->(m) { m['production_contract']['replicate_count'] = 2 },
      ->(m) { m['production_contract']['no_favorable_rerun'] = false },
      ->(m) { m['scorer']['extra_args'] << '--full-source' },
      ->(m) { m['scorer']['repo'] = '/different/scorer' },
      ->(m) { m['temperature'] = 1 }
    ]
    mutations.each do |mutate|
      File.write(path, original)
      change_yaml(path, &mutate)
      assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
    end
  end

  def test_verifier_rejects_wrong_counts_order_and_extra_manifests
    snapshot = build
    path = File.join(@batch.queue_dir, 'snapshot.yml')
    original = File.read(path)
    change_yaml(path) { |s| s['expected_calls'] = 22 }
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
    File.write(path, original)
    order_path = File.join(@batch.queue_dir, 'run_order.txt')
    order = File.read(order_path)
    File.write(order_path, order.lines.reverse.join)
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
    File.write(order_path, order)
    FileUtils.cp(File.join(@root, snapshot['manifest_order'].first), File.join(@batch.experiment_dir, 'extra.yml'))
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
  end

  def test_verifier_rejects_scorer_sha_drift_before_planning
    build
    v = verifier
    v.verify_artifacts!
    @batch.active_sha = 'b' * 40
    error = assert_raises(AdventureIngest::Error) { v.verify_host! }
    assert_match(/scorer HEAD/, error.message)
  end

  def test_verifier_plans_every_manifest_and_checks_each_model_without_inference
    build
    v = verifier
    v.verify_artifacts!
    calls = []
    v.define_singleton_method(:command!) { |*command| calls << command; '' }
    capture_io { v.verify_host! }
    assert_equal 23, calls.count { |c| c[1] == 'plan' }
    assert_equal 4, calls.count { |c| c[1] == 'worker-check' }
    assert calls.all? { |c| %w[plan worker-check].include?(c[1]) }
  end

  def test_real_source_preflight_executes_scorer_and_preserves_clamp_contract
    batch = make_batch(clamp_ids: %w[ADV-0001 ADV-0002], clamp_gaps: {'ADV-0001' => 2})
    real_preflight = AdventureIngest::Batch.instance_method(:source_preflight).bind(batch)

    ok, detail = real_preflight.call(@scorer, File.join(@root, 'catalog.xlsx'), 'ADV-0001')
    assert ok, detail
    config = YAML.safe_load_file(File.join(@scorer, 'preflight-ADV-0001.yml'))
    assert_equal %w[ADV-0001 ADV-0002], config.dig('source', 'allow_inward_boundary_clamp_adventure_ids')
    assert_equal({'ADV-0001' => 2}, config.dig('source', 'inward_boundary_clamp_max_gap_by_adventure'))

    File.write(File.join(@scorer, 'fail'), '')
    ok, detail = real_preflight.call(@scorer, File.join(@root, 'catalog.xlsx'), 'ADV-0002')
    refute ok
    assert_match(/missing canonical page marker/, detail)
  end

  def test_legacy_snapshot_without_conditional_metadata_accepts_only_preserved_levels
    @rows.last[7] = 3
    @rows.last[8] = 4
    build
    path = File.join(@batch.queue_dir, 'snapshot.yml')
    change_yaml(path) do |s|
      %w[conditional_dimension_order levels_contract levels_inference_adventure_ids].each { |key| s.delete(key) }
      s['selected_adventures'].each { |a| a.delete('needs_levels') }
    end
    assert_equal 22, verifier.verify_artifacts!.fetch('expected_calls')
    @rows.last[7] = @rows.last[8] = nil
    assert_raises(AdventureIngest::Error) { verifier.verify_artifacts! }
  end
end
