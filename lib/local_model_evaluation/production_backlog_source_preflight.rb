# frozen_string_literal: true

require "json"
require "open3"
require_relative "config"
require_relative "experiment"

module LocalModelEvaluation
  class ProductionBacklogSourcePreflight
    TERMINAL_STATUSES = %w[complete failed].freeze

    def initialize(root:, io: $stdout, err: $stderr, command_runner: nil)
      @root = File.expand_path(root)
      @io = io
      @err = err
      @command_runner = command_runner || method(:capture3)
    end

    def run(queue_arg, manifest_entries: nil)
      previous_lme_repo = ENV["LME_REPO"]
      ENV["LME_REPO"] = @root if previous_lme_repo.to_s.empty?

      queue_dir = File.expand_path(queue_arg, @root)
      order_path = File.join(queue_dir, "run_order.txt")
      raise ArgumentError, "missing run order: #{order_path}" unless File.file?(order_path)

      models = Config.load_yaml(File.join(@root, "config", "models.yml")).fetch("models")
      frozen_manifest_paths = File.readlines(order_path, chomp: true).reject(&:empty?)
      raise ArgumentError, "run order is empty: #{order_path}" if frozen_manifest_paths.empty?
      manifest_paths = select_manifest_paths(frozen_manifest_paths, manifest_entries)

      seen = {}
      failures = []
      checked = 0
      terminal_skipped = 0
      nonterminal_considered = 0

      manifest_paths.each do |manifest_entry|
        manifest_path = File.expand_path(manifest_entry, @root)
        experiment = Experiment.new(manifest_path)

        if TERMINAL_STATUSES.include?(manifest_status(experiment))
          terminal_skipped += 1
          next
        end

        nonterminal_considered += 1
        manifest = Config.load_yaml(manifest_path)

        unless experiment.scorer_mode == "positional"
          raise ArgumentError, "runtime source preflight requires positional scorer mode in #{manifest_entry}"
        end

        if experiment.models.length != 1
          raise ArgumentError, "runtime source preflight requires exactly one model in #{manifest_entry}"
        end

        model_alias = experiment.models.fetch(0)
        ollama_model = models.fetch(model_alias).fetch("ollama_model").to_s
        env = prompt_profile_env(manifest)

        experiment.adventures.each do |adventure|
          key = [experiment.scorer_repo, adventure, experiment.extra_args, env.sort]
          next if seen[key]
          seen[key] = true
          checked += 1

          command = preflight_command(experiment, ollama_model, adventure)
          stdout, stderr, status = @command_runner.call(env, command, experiment.scorer_repo)
          detail = [stdout, stderr].map(&:to_s).reject(&:empty?).join("\n").strip

          if status.success?
            @io.puts format("SOURCE PASS %3d  %-9s  %s", checked, adventure, File.basename(manifest_entry))
          else
            @err.puts format("SOURCE FAIL %3d  %-9s  %s", checked, adventure, File.basename(manifest_entry))
            @err.puts detail unless detail.empty?
            failures << [adventure, manifest_entry]
          end
        end
      end

      summary = source_summary(
        checked: checked,
        terminal_skipped: terminal_skipped,
        nonterminal_considered: nonterminal_considered
      )

      if failures.empty?
        @io.puts "Runtime source preflight: PASS (#{summary})"
        true
      else
        @err.puts "Runtime source preflight: FAIL (#{failures.length}/#{checked} failed; #{summary}). No inference is authorized."
        false
      end
    rescue KeyError, ArgumentError, Errno::ENOENT => e
      @err.puts "Runtime source preflight: ERROR: #{e.message}"
      false
    ensure
      if previous_lme_repo.nil?
        ENV.delete("LME_REPO")
      else
        ENV["LME_REPO"] = previous_lme_repo
      end
    end

    private

    def select_manifest_paths(frozen_manifest_paths, manifest_entries)
      return frozen_manifest_paths if manifest_entries.nil?

      requested = Array(manifest_entries).map(&:to_s)
      if requested.empty? || requested.any?(&:empty?)
        raise ArgumentError, "source preflight manifest selection is empty"
      end

      requested_expanded = requested.map { |entry| File.expand_path(entry, @root) }
      if requested_expanded.uniq.length != requested_expanded.length
        raise ArgumentError, "source preflight manifest selection contains duplicates"
      end

      frozen_expanded = frozen_manifest_paths.to_h do |entry|
        [File.expand_path(entry, @root), entry]
      end
      unknown = requested.reject do |entry|
        frozen_expanded.key?(File.expand_path(entry, @root))
      end
      unless unknown.empty?
        raise ArgumentError,
              "source preflight manifest selection is not present in frozen run order: #{unknown.join(', ')}"
      end

      selected = requested_expanded.to_h { |entry| [entry, true] }
      frozen_manifest_paths.select do |entry|
        selected.key?(File.expand_path(entry, @root))
      end
    end

    def capture3(env, command, chdir)
      Open3.capture3(env, *command, chdir: chdir)
    end

    def manifest_status(experiment)
      pattern = File.join(@root, "output", experiment.name, "runs", "*", "metadata.json")
      metadata = Dir.glob(pattern).sort
      return "pending" if metadata.empty?

      statuses = metadata.map { |path| JSON.parse(File.read(path))["status"].to_s }
      return "complete" if statuses.all? { |status| status == "complete" }
      return "failed" if statuses.any? { |status| status == "failed" }
      return "running" if statuses.any? { |status| status == "running" }

      "unknown"
    rescue JSON::ParserError
      "unknown"
    end

    def source_summary(checked:, terminal_skipped:, nonterminal_considered:)
      [
        "#{checked} unique source context#{checked == 1 ? '' : 's'} checked",
        "#{terminal_skipped} terminal manifest#{terminal_skipped == 1 ? '' : 's'} skipped",
        "#{nonterminal_considered} nonterminal manifest#{nonterminal_considered == 1 ? '' : 's'} considered"
      ].join("; ")
    end

    def preflight_command(experiment, ollama_model, adventure)
      executable = File.join(experiment.scorer_repo, "bin", "af-score")
      raise ArgumentError, "scorer executable not found: #{executable}" unless File.file?(executable)

      [
        executable,
        "--model", ollama_model,
        "--dimension", experiment.dimension,
        "--preflight",
        adventure,
        *experiment.extra_args
      ]
    end

    def prompt_profile_env(manifest)
      profile = manifest.dig("phase6_contract", "prompt_profile")
      return {} unless profile

      name = profile["env_name"].to_s
      value = profile["env_value"].to_s
      return {} if name.empty?

      { name => value }
    end
  end
end
