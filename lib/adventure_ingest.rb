# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "tmpdir"
require "time"
require "yaml"


module AdventureIngest
  class Error < StandardError; end

  class Batch
    DEFERRED_COLUMNS = [
      "Rules / System-Master Demand",
      "Tactical Complexity",
      "Lethality / Failure Severity",
      "Puzzle / Problem-Solving Emphasis",
      "Consequential Player Agency",
      "Fantastic Weirdness",
      "GM Improvisation Demand"
    ].freeze

    QUALIFICATION_PATHS = {
      "core" => "production_backlog/qualified_dimensions.yml",
      "nos" => "production_backlog/qualified_number_of_sessions.yml",
      "ee" => "production_backlog/qualified_exploration_emphasis.yml",
      "gmbs" => "production_backlog/qualified_gm_beginner_suitability.yml",
      "gmpb" => "production_backlog/qualified_gm_preparation_burden.yml",
      "seriousness" => "production_backlog/qualified_seriousness.yml"
    }.freeze

    RUNTIME_SOURCE_PATHS = {
      "ee" => "production_backlog/ee-v0.5-runtime.yml",
      "gmpb" => "production_backlog/gmpb-v0.6-runtime.yml",
      "seriousness" => "production_backlog/seriousness-reset-runtime.yml"
    }.freeze


    attr_reader :root, :scorer_repo, :queue, :catalog_filename, :catalog_sha256, :clamp_ids, :clamp_gaps

    def abort_with(message)
      raise Error, message
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def canonical_header(value)
      header = value.to_s.strip
      header == "ADV - ID" ? "Adventure ID" : header
    end

    def integer_or_nil(value)
      return nil if blank?(value)
      Integer(Float(value))
    rescue ArgumentError, TypeError
      nil
    end

    def git_head(repo)
      out, _err, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      abort_with("cannot read Git HEAD: #{repo}") unless status.success?
      out.strip
    end

    def load_yaml(path)
      YAML.safe_load_file(path, aliases: true) || {}
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def deep_merge(base, other)
      merged = Marshal.load(Marshal.dump(base))
      other.each do |key, value|
        if merged[key].is_a?(Hash) && value.is_a?(Hash)
          merged[key] = deep_merge(merged[key], value)
        else
          merged[key] = value
        end
      end
      merged
    end

    def qualification_path(key)
      File.join(root, QUALIFICATION_PATHS.fetch(key))
    end

    def load_qualifications
      QUALIFICATION_PATHS.each_value do |relative|
        path = File.join(root, relative)
        abort_with("missing qualification contract #{path}") unless File.file?(path)
      end
      RUNTIME_SOURCE_PATHS.each_value do |relative|
        path = File.join(root, relative)
        abort_with("missing qualified runtime config #{path}") unless File.file?(path)
      end

      core = load_yaml(qualification_path("core"))
      abort_with("qualified core model alias changed") unless core.fetch("model_alias") == "qwen"
      abort_with("qualified core Ollama model changed") unless core.fetch("ollama_model") == "qwen3.6:35b-a3b"
      core_by_name = core.fetch("dimensions").to_h { |d| [d.fetch("name"), d] }

      nos = load_yaml(qualification_path("nos"))
      ee = load_yaml(qualification_path("ee"))
      gmbs = load_yaml(qualification_path("gmbs"))
      gmpb = load_yaml(qualification_path("gmpb"))
      seriousness = load_yaml(qualification_path("seriousness"))

      expected_individual = {
        nos => ["nos_local_qualified_v1", "# of Sessions", "qwen27", "qwen3.6:27b", "nos-clean-blind-v1"],
        ee => ["ee_local_qualified_v1", "Exploration Emphasis", "gptoss", "gpt-oss:20b", "ee-clean-reset-v0.5"],
        gmbs => ["gmbs_local_qualified_v1", "GM Beginner Suitability", "qwen", "qwen3.6:35b-a3b", "gmbs-clean-blind-v0.3"],
        gmpb => ["gmpb_local_qualified_v1", "GM Preparation Burden", "gemma", "gemma4:26b", "gmpb-v0.6-dependency-fan-out"],
        seriousness => ["seriousness_local_qualified_v1", "Seriousness", "qwen", "qwen3.6:35b-a3b", "seriousness-reset-only"]
      }
      expected_individual.each do |contract, expected|
        actual = [contract["contract_type"], contract["dimension"], contract["model_alias"], contract["ollama_model"], contract["profile"]]
        abort_with("qualified contract changed: expected #{expected.inspect}, got #{actual.inspect}") unless actual == expected
        abort_with("qualified contract no longer uses one replicate") unless Integer(contract.fetch("replicates")) == 1
        abort_with("qualified contract permits favorable reruns or external API cost") unless contract.fetch("no_favorable_rerun") == true && contract.fetch("external_api_cost_usd") == 0.0
        abort_with("qualified temperature changed") if contract.key?("temperature") && contract.fetch("temperature") != 0
      end

      core_expected = {
        "Levels" => ["levels", "levels-v2.1"],
        "Combat Emphasis" => ["combat", "production-base"],
        "Social Interaction Emphasis" => ["social", "phase6-v0.3"],
        "Investigation Emphasis" => ["investigation", "phase6-v0.4"],
        "Structural Openness" => ["structural-openness", "production-base"],
        "Darkness / Horror Intensity" => ["darkness", "production-base"],
        "Player Beginner Suitability" => ["player-beginner", "production-base"]
      }
      core_expected.each do |name, (slug, profile)|
        d = core_by_name.fetch(name)
        abort_with("qualified #{name} slug/profile changed") unless d.fetch("slug") == slug && d.fetch("profile") == profile
      end

      [core, core_by_name, nos, ee, gmbs, gmpb, seriousness]
    end

    def dimension_contracts
      core, core_by_name, nos, ee, gmbs, gmpb, seriousness = load_qualifications
      core_sha = sha256(qualification_path("core"))

      build_core = lambda do |name|
        d = core_by_name.fetch(name)
        {
          "name" => name,
          "slug" => d.fetch("slug"),
          "catalog_column" => name,
          "model_alias" => core.fetch("model_alias"),
          "ollama_model" => core.fetch("ollama_model"),
          "profile" => d.fetch("profile"),
          "qualification_path" => QUALIFICATION_PATHS.fetch("core"),
          "qualification_sha256" => core_sha,
          "runtime_key" => "base",
          "env_name" => d["env_name"],
          "env_value" => d["env_value"],
          "qualified_scorer_baseline" => %w[Social\ Interaction\ Emphasis Investigation\ Emphasis].include?(name) ? core.fetch("social_investigation_qualified_scorer_baseline") : nil
        }
      end

      individual = lambda do |key, contract, runtime_key, catalog_column = nil|
        {
          "name" => contract.fetch("dimension"),
          "slug" => contract.fetch("slug"),
          "catalog_column" => catalog_column || contract.fetch("catalog_column"),
          "model_alias" => contract.fetch("model_alias"),
          "ollama_model" => contract.fetch("ollama_model"),
          "profile" => contract.fetch("profile"),
          "qualification_path" => QUALIFICATION_PATHS.fetch(key),
          "qualification_sha256" => sha256(qualification_path(key)),
          "runtime_key" => runtime_key,
          "qualified_scorer_baseline" => contract["qualified_scorer_baseline"]
        }
      end

      [
        individual.call("nos", nos, "base", "Number of Sessions"),
        individual.call("ee", ee, "ee"),
        individual.call("gmpb", gmpb, "gmpb"),
        build_core.call("Combat Emphasis"),
        build_core.call("Social Interaction Emphasis"),
        build_core.call("Investigation Emphasis"),
        build_core.call("Structural Openness"),
        build_core.call("Darkness / Horror Intensity"),
        build_core.call("Player Beginner Suitability"),
        individual.call("gmbs", gmbs, "base"),
        individual.call("seriousness", seriousness, "seriousness")
      ]
    end

    def levels_contract
      core, core_by_name, *_rest = load_qualifications
      d = core_by_name.fetch("Levels")
      columns = d.fetch("catalog_columns")
      abort_with("qualified Levels catalog columns changed") unless columns == ["Level Start", "Level End"]

      {
        "name" => "Levels",
        "slug" => d.fetch("slug"),
        "catalog_columns" => columns,
        "model_alias" => core.fetch("model_alias"),
        "ollama_model" => core.fetch("ollama_model"),
        "profile" => d.fetch("profile"),
        "qualification_path" => QUALIFICATION_PATHS.fetch("core"),
        "qualification_sha256" => sha256(qualification_path("core")),
        "runtime_key" => "base"
      }
    end

    def catalog_path_for(scorer_repo)
      require File.join(scorer_repo, "lib", "af_scoring", "errors")
      require File.join(scorer_repo, "lib", "af_scoring", "config")
      AFScoring::Config.new(
        project_root: scorer_repo,
        overrides: { "files" => { "catalog" => catalog_filename } }
      ).catalog_path
    end

    def source_preflight(scorer_repo, catalog_path, adventure_id)
      Dir.mktmpdir("af-ingest-preflight") do |dir|
        runtime = File.join(dir, "catalog.yml")
        File.write(
          runtime,
          YAML.dump(
            "files" => { "catalog" => File.basename(catalog_path) },
            "source" => {
              "allow_inward_boundary_clamp_adventure_ids" => clamp_ids,
              "inward_boundary_clamp_max_gap_by_adventure" => clamp_gaps
            }
          )
        )
        command = [
          File.join(scorer_repo, "bin", "af-score"),
          "--config", runtime,
          "--model", "qwen3.6:35b-a3b",
          "--dimension", "Combat Emphasis",
          "--preflight",
          adventure_id
        ]
        stdout, stderr, status = Open3.capture3(*command, chdir: scorer_repo)
        [status.success?, [stdout, stderr].join("\n").strip]
      end
    end

    def runtime_payloads
      payloads = { "base" => {} }
      RUNTIME_SOURCE_PATHS.each do |key, relative|
        payloads[key] = load_yaml(File.join(root, relative))
        qualification = load_yaml(qualification_path(key))
        expected = { "llm" => {
          "provider" => "ollama", "model" => qualification.fetch("ollama_model"),
          "reasoning_effort" => qualification.fetch("reasoning_effort"),
          "max_tokens" => qualification.fetch("max_tokens")
        } }
        abort_with("qualified runtime content changed: #{relative}") unless payloads[key] == expected
      end
      payloads.transform_values do |payload|
        deep_merge(
          payload,
          {
            "files" => { "catalog" => catalog_filename },
            "source" => {
              "allow_inward_boundary_clamp_adventure_ids" => clamp_ids,
              "inward_boundary_clamp_max_gap_by_adventure" => clamp_gaps
            }
          }
        )
      end
    end

    def manifest_hash(queue:, adv:, dimension:, scorer_rel:, runtime_portable:)
      contract = {
        "contract_type" => "adventure_ingest_v1",
        "disposition" => "local-qualified-adventure-ingest",
        "queue" => queue,
        "candidate_model" => dimension.fetch("model_alias"),
        "qualified_profile" => dimension.fetch("profile"),
        "source_qualification_path" => dimension.fetch("qualification_path"),
        "source_qualification_sha256" => dimension.fetch("qualification_sha256"),
        "replicate_count" => 1,
        "no_favorable_rerun" => true,
        "external_api_cost_usd" => 0.0,
        "catalog_filename" => catalog_filename,
        "catalog_sha256" => catalog_sha256
      }
      if dimension["qualified_scorer_baseline"]
        contract["qualified_scorer_baseline"] = dimension["qualified_scorer_baseline"]
      end

      data = {
        "name" => "#{queue}-#{dimension.fetch('model_alias')}-#{dimension.fetch('slug')}-adv#{adv.fetch('id').split('-').last.downcase}-v1",
        "purpose" => "AdventureFinder #{queue} row-major local production scoring for #{adv.fetch('id')} on #{dimension.fetch('name')}. Preserve the frozen qualified profile; produce one proposed assessment pending QC/ingestion.",
        "dispatch" => "pool",
        "models" => [dimension.fetch("model_alias")],
        "dimension" => dimension.fetch("name"),
        "adventures" => [adv.fetch("id")],
        "replicates" => 1,
        "workers" => ["mac"],
        "required_worker_labels" => ["local"],
        "scorer" => {
          "repo" => scorer_rel,
          "mode" => "positional",
          "extra_args" => ["--config", runtime_portable]
        },
        "production_contract" => contract,
        "success_criteria" => [
          "Structured scorer output validates and remains grounded to the canonical adventure source unit.",
          "Use the frozen locally qualified profile for #{dimension.fetch('name')}.",
          "Preserve the single completed sample as a proposed production assessment pending QC/ingestion.",
          "Do not use an existing accepted score or calibration target as expected-answer context."
        ],
        "stop_conditions" => [
          "Do not rerun a completed case to seek a more favorable sample.",
          "Queue-level repeated operational failures trigger the background runner circuit breaker."
        ],
        "cost_cap_usd" => 0.01
      }

      if dimension["env_name"]
        data["phase6_contract"] = {
          "prompt_profile" => {
            "version" => dimension.fetch("profile"),
            "env_name" => dimension.fetch("env_name"),
            "env_value" => dimension.fetch("env_value")
          }
        }
      end
      data
    end

    def self.parse_ids(spec)
      tokens = Array(spec).flat_map { |value| value.split(',', -1) }
      ids = tokens.flat_map do |token|
        if (match = /\AADV-(\d{4})\.\.ADV-(\d{4})\z/.match(token))
          first, last = match.captures.map(&:to_i)
          raise Error, "descending ID range: #{token}" if first > last
          (first..last).map { |n| format('ADV-%04d', n) }
        elsif /\AADV-\d{4}\z/.match?(token)
          [token]
        else
          raise Error, "invalid Adventure ID/range: #{token.inspect}"
        end
      end
      raise Error, 'target IDs must be nonempty and unique' if ids.empty? || ids.uniq != ids
      ids
    end

    def initialize(root:, batch:, catalog:, ids:, scorer_repo: nil, clamp_ids: [], clamp_gaps: {})
      @root = File.expand_path(root)
      number = batch.to_s.sub(/\Aproduction-backlog-/, '')
      abort_with('batch must be a positive integer (e.g. 020)') unless /\A\d+\z/.match?(number) && number.to_i.positive?
      @queue = format('production-backlog-%03d', number.to_i)
      abort_with('catalog must be an XLSX basename') unless File.basename(catalog) == catalog && catalog.end_with?('.xlsx')
      @catalog_filename = catalog
      @ids = self.class.parse_ids(ids)
      @scorer_repo = File.expand_path(scorer_repo || ENV.fetch('AF_SCORER_REPO', '../af-cli-scoring-utility'), @root)
      @clamp_ids = clamp_ids
      @clamp_gaps = clamp_gaps
      abort_with('clamp allowlist must contain unique target IDs only') unless clamp_ids.is_a?(Array) && clamp_ids.uniq == clamp_ids && (clamp_ids - @ids).empty?
      abort_with('max-gap overrides require allowlisted IDs and positive integer gaps') unless clamp_gaps.is_a?(Hash) && (clamp_gaps.keys - clamp_ids).empty? && clamp_gaps.values.all? { |v| v.is_a?(Integer) && v.positive? }
    end

    def read_rows(path)
      require File.join(scorer_repo, 'lib/af_scoring/errors')
      require File.join(scorer_repo, 'lib/af_scoring/xlsx_reader')
      AFScoring::XlsxReader.new(path).rows(sheet_name: 'Adventure Catalog')
    end

    # Kept separate from IO so target/Levels interpretation can be tested directly.
    def select_targets(rows)
      abort_with('AMC Adventure Catalog sheet is empty') if rows.empty?
      headers = rows.first.map { |v| canonical_header(v) }
      score_columns = dimension_contracts.map { |d| d.fetch('catalog_column') }
      required = ['Adventure ID', 'Adventure Title', 'Source Book', 'Book Publisher',
                  'Page Count', 'Start Page', 'End Page', 'Level Start', 'Level End', *score_columns]
      abort_with("missing catalog headers: #{(required - headers).join(', ')}") unless (required - headers).empty?
      abort_with('duplicate catalog headers') unless headers.reject(&:empty?).uniq == headers.reject(&:empty?)
      deferred_columns_present = DEFERRED_COLUMNS.select { |column| headers.include?(column) }
      seen = []
      targets = []
      rows.drop(1).each do |row|
        values = headers.zip(row).to_h
        id = values['Adventure ID'].to_s.strip
        next if id.empty?
        seen << id
        next unless @ids.include?(id)
        start_page = integer_or_nil(values['Start Page'])
        end_page = integer_or_nil(values['End Page'])
        page_count = integer_or_nil(values['Page Count'])
        page_count ||= end_page - start_page + 1 if start_page && end_page && end_page >= start_page
        abort_with("#{id} missing/invalid page count or outside proven <100 page envelope") unless page_count&.positive? && page_count < 100
        left, right = ['Level Start', 'Level End'].map { |column| blank?(values[column]) }
        abort_with("#{id} has asymmetric Levels state") unless left == right
        (score_columns + deferred_columns_present).each do |column|
          abort_with("#{id} #{column} must remain blank") unless blank?(values[column])
        end
        targets << {
          'id' => id, 'title' => values['Adventure Title'].to_s,
          'source_book' => values['Source Book'].to_s, 'publisher' => values['Book Publisher'].to_s,
          'page_count' => page_count, 'start_page' => start_page, 'end_page' => end_page,
          'level_start' => integer_or_nil(values['Level Start']), 'level_end' => integer_or_nil(values['Level End']),
          'needs_levels' => left
        }
        unless left
          abort_with("#{id} invalid populated Levels pair") if targets.last.values_at('level_start', 'level_end').any?(&:nil?)
        end
      end
      abort_with('duplicate catalog Adventure IDs') unless seen.uniq == seen
      missing = @ids - targets.map { |t| t.fetch('id') }
      abort_with("missing target IDs: #{missing.join(', ')}") unless missing.empty?
      targets
    end

    def interpretation(catalog_path = catalog_path_for(scorer_repo))
      abort_with("catalog missing or wrong basename: #{catalog_path}") unless File.file?(catalog_path) && File.basename(catalog_path) == catalog_filename
      @catalog_sha256 = sha256(catalog_path)
      targets = select_targets(read_rows(catalog_path))
      level_ids = targets.select { |t| t.fetch('needs_levels') }.map { |t| t.fetch('id') }
      dimensions = dimension_contracts
      {
        'version' => 1, 'contract_type' => 'adventure_ingest_v1', 'queue' => queue,
        'catalog_filename' => catalog_filename, 'catalog_path' => catalog_path, 'catalog_sha256' => catalog_sha256,
        'expected_adventure_count' => targets.length,
        'expected_ordinary_calls' => targets.length * dimensions.length,
        'expected_levels_calls' => level_ids.length,
        'expected_calls' => targets.length * dimensions.length + level_ids.length,
        'adventures_per_pack' => 5, 'adventure_order' => targets.map { |t| t.fetch('id') },
        'source_boundary_clamp_adventure_ids' => clamp_ids, 'source_boundary_clamp_max_gaps' => clamp_gaps,
        'dimension_order' => dimensions.map { |d| d.fetch('name') }, 'dimension_contracts' => dimensions,
        'conditional_dimension_order' => ['Levels'], 'levels_contract' => levels_contract,
        'levels_inference_adventure_ids' => level_ids,
        'preserved_levels_adventure_ids' => targets.reject { |t| t.fetch('needs_levels') }.map { |t| t.fetch('id') },
        'deferred_columns' => DEFERRED_COLUMNS, 'selected_adventures' => targets,
        'qualification_files' => QUALIFICATION_PATHS.values.to_h { |path| [path, sha256(File.join(root, path))] }
      }
    end

    def scorer_check!
      abort_with('scorer executable missing') unless File.executable?(File.join(scorer_repo, 'bin/af-score'))
      commit = git_head(scorer_repo)
      [[], ['--cached']].each do |args|
        _out, _err, status = Open3.capture3('git', '-C', scorer_repo, 'diff', *args, '--quiet', '--',
                                          'lib/af_scoring', 'config/default.yml', 'config/source_mappings.yml')
        abort_with('scorer protected paths have uncommitted changes') unless status.success?
      end
      commit
    end

    def unstarted!(force)
      exists = [queue_dir, experiment_dir].any? { |path| File.exist?(path) }
      abort_with('queue already exists; --force is only for an unstarted queue') if exists && !force
      # More conservative than B19: even partial output without metadata blocks replacement.
      abort_with('refusing build/--force: queue output already exists') unless Dir.glob(File.join(root, 'output', "#{queue}-*", '**', '*')).empty?
    end

    def queue_dir
      File.join(root, 'production_backlog', queue)
    end

    def experiment_dir
      File.join(root, 'experiments', queue)
    end

    def operations(snapshot)
      snapshot.fetch('selected_adventures').flat_map do |adv|
        dimensions = snapshot.fetch('dimension_contracts').dup
        dimensions << snapshot.fetch('levels_contract') if adv.fetch('needs_levels')
        dimensions.map { |dimension| [adv, dimension] }
      end
    end

    def manifest_relative(adv, dimension)
      File.join('experiments', queue, "#{queue}-#{dimension.fetch('model_alias')}-#{dimension.fetch('slug')}-adv#{adv.fetch('id').split('-').last}-v1.yml")
    end

    def build(force: false, dry_run: false)
      unstarted!(force) unless dry_run
      snapshot = interpretation
      snapshot['local_model_eval_commit'] = git_head(root)
      snapshot['scorer_commit'] = scorer_check!
      snapshot['scorer_repo_path'] = Pathname.new(scorer_repo).relative_path_from(Pathname.new(root)).to_s
      snapshot['generated_at'] = Time.now.iso8601
      initial_payloads = runtime_payloads
      initial_runtime_hashes = RUNTIME_SOURCE_PATHS.transform_values { |path| sha256(File.join(root, path)) }
      puts "#{queue}: #{snapshot.fetch('expected_adventure_count')} adventures / #{snapshot.fetch('expected_calls')} calls"
      failures = []
      snapshot.fetch('selected_adventures').each do |target|
        ok, detail = source_preflight(scorer_repo, snapshot.fetch('catalog_path'), target.fetch('id'))
        puts "#{ok ? 'PASS' : 'FAIL'} #{target.fetch('id')} — #{target.fetch('title')}"
        failures << "#{target.fetch('id')} — #{target.fetch('title')}: #{detail}" unless ok
      rescue StandardError => e
        failures << "#{target.fetch('id')} — #{target.fetch('title')}: #{e.message}"
      end
      abort_with("source preflight failed; no queue/manifests written:\n#{failures.join("\n")}") unless failures.empty?
      # Fail if inputs changed during the potentially lengthy source preflight.
      abort_with('catalog/qualification changed during preflight') unless interpretation == snapshot.reject { |key, _| %w[local_model_eval_commit scorer_commit scorer_repo_path generated_at].include?(key) }
      abort_with('scorer changed during preflight') unless scorer_check! == snapshot.fetch('scorer_commit')
      payloads = runtime_payloads
      abort_with('runtime changed during preflight') unless payloads == initial_payloads && RUNTIME_SOURCE_PATHS.transform_values { |path| sha256(File.join(root, path)) } == initial_runtime_hashes
      snapshot['runtime_files'] = payloads.to_h do |key, payload|
        source = RUNTIME_SOURCE_PATHS[key]
        [key, {'path' => "production_backlog/#{queue}/runtime-#{key}.yml",
               'sha256' => Digest::SHA256.hexdigest(YAML.dump(payload)),
               'source_path' => source, 'source_sha256' => source && sha256(File.join(root, source))}]
      end
      snapshot['manifest_order'] = operations(snapshot).map { |adv, d| manifest_relative(adv, d) }
      unless dry_run
        unstarted!(force)
        # All validation/preflight precedes materialization, including --force deletion.
        Dir.mktmpdir('af-ingest-build') do |staging|
          write_package(staging, snapshot, payloads)
          FileUtils.mkdir_p(File.dirname(queue_dir))
          FileUtils.mkdir_p(File.dirname(experiment_dir))
          FileUtils.rm_rf(queue_dir) if force
          FileUtils.rm_rf(experiment_dir) if force
          FileUtils.mv(File.join(staging, 'queue'), queue_dir)
          FileUtils.mv(File.join(staging, 'experiments'), experiment_dir)
        end
      end
      puts "#{dry_run ? 'DRY RUN' : 'PREPARED'}: #{queue}; #{snapshot.fetch('expected_ordinary_calls')} ordinary + #{snapshot.fetch('expected_levels_calls')} Levels; no inference; API cost $0"
      snapshot
    end

    CASE_HEADERS = %w[case_index pack_index pack_case_index adventure_index adventure_id adventure_title source_book publisher page_count dimension profile model_alias runtime_key manifest_path].freeze

    def write_package(staging, snapshot, payloads)
      qdir = File.join(staging, 'queue')
      edir = File.join(staging, 'experiments')
      FileUtils.mkdir_p([qdir, edir])
      payloads.each { |key, payload| File.write(File.join(qdir, "runtime-#{key}.yml"), YAML.dump(payload)) }
      File.write(File.join(qdir, 'snapshot.yml'), YAML.dump(snapshot))
      rows = []
      packs = Hash.new { |hash, key| hash[key] = [] }
      scorer_rel = Pathname.new(scorer_repo).relative_path_from(Pathname.new(experiment_dir)).to_s
      operations(snapshot).each_with_index do |(adv, dimension), index|
        adv_index = snapshot.fetch('adventure_order').index(adv.fetch('id'))
        pack = adv_index / snapshot.fetch('adventures_per_pack') + 1
        relative = manifest_relative(adv, dimension)
        runtime = snapshot.fetch('runtime_files').fetch(dimension.fetch('runtime_key')).fetch('path')
        data = manifest_hash(queue: queue, adv: adv, dimension: dimension, scorer_rel: scorer_rel, runtime_portable: "${LME_REPO}/#{runtime}")
        File.write(File.join(edir, File.basename(relative)), YAML.dump(data))
        row = [index + 1, pack, packs[pack].length + 1, adv_index + 1, adv.fetch('id'), adv.fetch('title'),
               adv.fetch('source_book'), adv.fetch('publisher'), adv.fetch('page_count'), dimension.fetch('name'),
               dimension.fetch('profile'), dimension.fetch('model_alias'), dimension.fetch('runtime_key'), relative]
        rows << row
        packs[pack] << row
      end
      write_index(qdir, '', rows)
      packs.each { |pack, entries| write_index(qdir, format('pack-%03d_', pack), entries) }
      CSV.open(File.join(qdir, 'candidate_audit.csv'), 'w') do |csv|
        csv << %w[adventure_id adventure_title source_book publisher page_count level_start level_end levels_action decision reason]
        snapshot.fetch('selected_adventures').each do |adv|
          csv << [*adv.values_at('id', 'title', 'source_book', 'publisher', 'page_count', 'level_start', 'level_end'),
                  adv.fetch('needs_levels') ? 'SCORE' : 'PRESERVE', 'SELECT', 'explicit_target_11_scores_blank_source_preflight_pass']
        end
      end
    end

    def write_index(dir, prefix, rows)
      CSV.open(File.join(dir, "#{prefix}case_index.csv"), 'w') do |csv|
        csv << CASE_HEADERS
        rows.each { |row| csv << row }
      end
      File.write(File.join(dir, "#{prefix}run_order.txt"), rows.map(&:last).join("\n") + "\n")
    end
  end
end
