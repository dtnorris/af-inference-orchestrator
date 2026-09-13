# frozen_string_literal: true

require_relative 'adventure_ingest'

module AdventureIngest
  class Verifier
    attr_reader :root, :queue_dir, :snapshot, :batch

    def initialize(root:, queue_path:)
      @root = File.expand_path(root)
      @queue_dir = File.expand_path(queue_path, @root)
      @snapshot = YAML.safe_load_file(File.join(@queue_dir, 'snapshot.yml'), aliases: true)
      equal!('contract type', 'adventure_ingest_v1', snapshot.fetch('contract_type'))
      equal!('version', 1, snapshot.fetch('version'))
      @batch = Batch.new(root: @root, batch: snapshot.fetch('queue'), catalog: snapshot.fetch('catalog_filename'),
                         ids: snapshot.fetch('adventure_order'), scorer_repo: snapshot.fetch('scorer_repo_path'),
                         clamp_ids: snapshot.fetch('source_boundary_clamp_adventure_ids'),
                         clamp_gaps: snapshot.fetch('source_boundary_clamp_max_gaps', {}))
      equal!('queue identity', batch.queue, snapshot.fetch('queue'))
      equal!('queue path', batch.queue_dir, @queue_dir)
      if ENV['AF_SCORER_REPO']
        equal!('active scorer path', batch.scorer_repo, File.expand_path(ENV.fetch('AF_SCORER_REPO'), @root))
      end
    end

    def equal!(label, expected, actual)
      raise Error, "#{label} changed: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
    end

    def hash_file!(path, digest)
      raise Error, "missing file: #{path}" unless File.file?(path)
      equal!("SHA256 #{path}", digest, batch.sha256(path))
    end

    # All artifact checks are separate from host readiness for regression tests.
    # The CLI always runs BOTH; there is no readiness bypass in the runner.
    def verify_artifacts!
      derived = batch.interpretation(snapshot.fetch('catalog_path'))
      %w[catalog_filename catalog_sha256 expected_adventure_count expected_calls adventure_order
         dimension_order dimension_contracts deferred_columns qualification_files].each do |key|
        equal!(key, derived.fetch(key), snapshot.fetch(key))
      end
      %w[expected_ordinary_calls expected_levels_calls preserved_levels_adventure_ids].each do |key|
        equal!(key, derived.fetch(key), snapshot.fetch(key)) if snapshot.key?(key)
      end
      if snapshot.key?('levels_contract')
        %w[conditional_dimension_order levels_contract levels_inference_adventure_ids].each do |key|
          equal!(key, derived.fetch(key), snapshot.fetch(key))
        end
      else
        # B16/B17 freeze only populated Levels. Missing metadata never authorizes new calls.
        equal!('legacy Levels inference IDs', [], derived.fetch('levels_inference_adventure_ids'))
        raise Error, 'incomplete conditional Levels metadata' if snapshot.key?('conditional_dimension_order') || snapshot.key?('levels_inference_adventure_ids')
      end
      selected = snapshot.fetch('selected_adventures').map do |adventure|
        adventure.merge('needs_levels' => adventure.fetch('needs_levels', false))
      end
      equal!('selected adventure metadata/Levels', derived.fetch('selected_adventures'), selected)
      raise Error, 'invalid adventures_per_pack' unless snapshot.fetch('adventures_per_pack').is_a?(Integer) && snapshot.fetch('adventures_per_pack').positive?
      verify_runtime!
      models = batch.load_yaml(File.join(root, 'config/models.yml')).fetch('models')
      (derived.fetch('dimension_contracts') + [derived.fetch('levels_contract')]).each do |d|
        equal!("model #{d.fetch('model_alias')}", d.fetch('ollama_model'), models.fetch(d.fetch('model_alias')).fetch('ollama_model'))
      end
      verify_manifests!(derived)
      derived
    end

    def verify_runtime!
      expected = batch.runtime_payloads
      equal!('runtime keys', expected.keys.sort, snapshot.fetch('runtime_files').keys.sort)
      expected.each do |key, payload|
        info = snapshot.fetch('runtime_files').fetch(key)
        equal!("runtime #{key} path", "production_backlog/#{batch.queue}/runtime-#{key}.yml", info.fetch('path'))
        path = File.join(root, info.fetch('path'))
        hash_file!(path, info.fetch('sha256'))
        source = Batch::RUNTIME_SOURCE_PATHS[key]
        equal!("runtime #{key} source", source, info.fetch('source_path'))
        if source
          hash_file!(File.join(root, source), info.fetch('source_sha256'))
        else
          equal!('base source SHA', nil, info.fetch('source_sha256'))
        end
        # Historical snapshots do not contain the max-gap key: scorer default remains 1.
        payload.fetch('source').delete('inward_boundary_clamp_max_gap_by_adventure') unless snapshot.key?('source_boundary_clamp_max_gaps')
        equal!("runtime #{key} content", payload, batch.load_yaml(path))
      end
    end

    def verify_manifests!(derived)
      rows = CSV.read(File.join(queue_dir, 'case_index.csv'), headers: true)
      order = File.readlines(File.join(queue_dir, 'run_order.txt'), chomp: true)
      operations = batch.operations(derived)
      expected_order = operations.map { |adv, d| batch.manifest_relative(adv, d) }
      equal!('manifest order', expected_order, snapshot.fetch('manifest_order')) if snapshot.key?('manifest_order')
      equal!('run-order count/order', expected_order, order)
      equal!('case-index headers', Batch::CASE_HEADERS, rows.headers)
      equal!('case-index count', expected_order.length, rows.length)
      equal!('case-index manifest order', order, rows.map { |row| row.fetch('manifest_path') })
      equal!('manifest file set', expected_order.map { |path| File.join(root, path) }.sort,
             Dir.glob(File.join(batch.experiment_dir, '*.yml')).sort)
      scorer_rel = Pathname.new(batch.scorer_repo).relative_path_from(Pathname.new(batch.experiment_dir)).to_s
      adventure_indexes = derived.fetch('adventure_order').each_with_index.to_h
      pack_counts = Hash.new(0)
      operations.each_with_index do |(adv, dimension), index|
        row = rows[index]
        adv_index = adventure_indexes.fetch(adv.fetch('id'))
        pack = adv_index / snapshot.fetch('adventures_per_pack') + 1
        pack_counts[pack] += 1
        expected_row = [index + 1, pack, pack_counts[pack], adv_index + 1, *adv.values_at('id', 'title', 'source_book', 'publisher', 'page_count'),
                        *dimension.values_at('name', 'profile', 'model_alias', 'runtime_key'), order.fetch(index)].map(&:to_s)
        equal!("case-index row #{index + 1}", expected_row, row.fields)
        relative = order.fetch(index)
        runtime = snapshot.fetch('runtime_files').fetch(dimension.fetch('runtime_key')).fetch('path')
        expected = batch.manifest_hash(queue: batch.queue, adv: adv, dimension: dimension,
                                      scorer_rel: scorer_rel, runtime_portable: "${LME_REPO}/#{runtime}")
        actual = batch.load_yaml(File.join(root, relative))
        # Historical editorial descriptions mention their batch number. Execution fields
        # (including full production/phase6 contracts and all extra keys) must match.
        prose = %w[purpose success_criteria stop_conditions]
        equal!("manifest #{relative}", expected.reject { |key, _| prose.include?(key) },
               actual.reject { |key, _| prose.include?(key) })
      end
      @order = order
      @derived = derived
    end

    def command!(*command)
      out, err, status = Open3.capture3(*command, chdir: root)
      raise Error, "#{command.join(' ')} failed:\n#{out}\n#{err}" unless status.success?
      out
    end

    def verify_host!
      equal!('scorer HEAD', snapshot.fetch('scorer_commit'), batch.scorer_check!)
      # Planner does not execute scorer calls. Plan every manifest, not just a sample.
      @order.each { |path| command!(File.join(root, 'bin/lme'), 'plan', path) }
      puts "LME manifest planning: PASS (#{@order.length}/#{@order.length})"
      representatives = @order.group_by { |path| batch.load_yaml(File.join(root, path)).fetch('models').first }.values.map(&:first)
      representatives.each { |path| puts command!(File.join(root, 'bin/lme'), 'worker-check', path) }
      puts "Local worker/models: PASS (#{representatives.length})"
    end

    def verify!
      data = verify_artifacts!
      puts "Frozen #{batch.queue} artifact semantics: PASS"
      verify_host!
      puts "#{batch.queue} PREFLIGHT: PASS — #{data.fetch('expected_adventure_count')} adventures; #{data.fetch('expected_ordinary_calls')} ordinary + #{data.fetch('expected_levels_calls')} Levels = #{data.fetch('expected_calls')} calls"
      puts "Levels preserved: #{data.fetch('preserved_levels_adventure_ids').length}; no inference; API cost $0"
      data
    end
  end
end
