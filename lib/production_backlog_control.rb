# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "time"
require "yaml"

module ProductionBacklogControl
  class Error < StandardError; end

  DEFAULT_PRODUCTION_ROOT = "/Users/davidnorris/code/af-inference-orchestrator-production"
  MIN_ETA_SAMPLES = 5

  module_function

  def median(values)
    values = values.map(&:to_f).sort
    return nil if values.empty?
    mid = values.length / 2
    values.length.odd? ? values[mid] : (values[mid - 1] + values[mid]) / 2.0
  end

  def format_duration(seconds)
    seconds = seconds.to_f.round
    hours, remainder = seconds.divmod(3600)
    minutes = (remainder / 60.0).round
    if minutes == 60
      hours += 1
      minutes = 0
    end
    return "#{minutes}m" if hours.zero?
    return "#{hours}h" if minutes.zero?
    "#{hours}h #{minutes}m"
  end

  class Queue
    attr_reader :root, :queue_dir, :queue_rel, :snapshot, :rows

    def initialize(root:, queue:)
      @root = File.expand_path(root)
      @queue_dir = File.expand_path(queue, @root)
      allowed_root = File.join(@root, "production_backlog") + File::SEPARATOR
      unless @queue_dir.start_with?(allowed_root) && File.basename(@queue_dir).match?(/\Aproduction-backlog-\d+\z/)
        raise Error, "queue must be production_backlog/production-backlog-NNN inside #{root}"
      end
      @queue_rel = Pathname.new(@queue_dir).relative_path_from(Pathname.new(@root)).to_s

      snapshot_path = File.join(@queue_dir, "snapshot.yml")
      index_path = File.join(@queue_dir, "case_index.csv")
      order_path = File.join(@queue_dir, "run_order.txt")
      [snapshot_path, index_path, order_path].each { |path| raise Error, "missing queue artifact: #{path}" unless File.file?(path) }

      @snapshot = YAML.safe_load_file(snapshot_path, aliases: true) || {}
      @rows = CSV.read(index_path, headers: true).map(&:to_h)
      @order = File.readlines(order_path, chomp: true).reject(&:empty?)
      validate_scope!
    rescue Psych::Exception, CSV::MalformedCSVError => e
      raise Error, "invalid queue metadata: #{e.message}"
    end

    def name = File.basename(queue_dir)

    def expected_calls
      Integer(snapshot.fetch("expected_calls"))
    rescue ArgumentError, TypeError, KeyError
      raise Error, "queue snapshot expected_calls must be an integer"
    end

    def queue_commit = snapshot.fetch("local_model_eval_commit", "").to_s.strip

    def records
      @records ||= rows.each_with_index.map do |row, index|
        manifest_rel = row.fetch("manifest_path").to_s
        raise Error, "case index/run order mismatch at call #{index + 1}" unless manifest_rel == @order.fetch(index)
        manifest_path = File.expand_path(manifest_rel, root)
        raise Error, "manifest escapes repository root: #{manifest_rel}" unless manifest_path.start_with?(root + File::SEPARATOR)
        manifest = YAML.safe_load_file(manifest_path, aliases: true) || {}
        name = manifest.fetch("name").to_s
        raise Error, "manifest #{manifest_rel} has blank name" if name.empty?
        metadata = metadata_for(name)
        {
          "index" => index + 1,
          "manifest_path" => manifest_rel,
          "name" => name,
          "adventure_id" => row.fetch("adventure_id").to_s,
          "adventure_title" => row.fetch("adventure_title").to_s,
          "page_count" => integer_or_nil(row["page_count"]),
          "dimension" => row.fetch("dimension").to_s,
          "model_alias" => row.fetch("model_alias").to_s,
          "status" => status_for(metadata),
          "metadata" => metadata
        }
      rescue Psych::Exception, KeyError => e
        raise Error, "invalid manifest/index data for call #{index + 1}: #{e.message}"
      end
    end

    def counts
      records.each_with_object(Hash.new(0)) { |record, out| out[record.fetch("status")] += 1 }
    end

    def timing_samples
      records.filter_map do |record|
        next unless record.fetch("status") == "complete"
        complete = record.fetch("metadata").reverse.find { |item| item["status"].to_s == "complete" }
        elapsed = Float(complete && complete["elapsed_seconds"]) rescue nil
        record.merge("elapsed_seconds" => elapsed) if elapsed&.positive?
      end
    end

    private

    def validate_scope!
      expected = expected_calls
      raise Error, "queue must contain at least one call" unless expected.positive?
      raise Error, "run_order count changed: expected #{expected}, got #{@order.length}" unless @order.length == expected
      raise Error, "case_index count changed: expected #{expected}, got #{@rows.length}" unless @rows.length == expected
      raise Error, "queue identity changed: expected #{name}, got #{snapshot['queue'].inspect}" unless snapshot["queue"].to_s == name
    end

    def integer_or_nil(value)
      return nil if value.to_s.strip.empty?
      Integer(Float(value))
    rescue ArgumentError, TypeError
      nil
    end

    def metadata_for(name)
      Dir.glob(File.join(root, "output", name, "runs", "*", "metadata.json")).sort.map do |path|
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        { "status" => "unknown" }
      end
    end

    def status_for(metadata)
      return "pending" if metadata.empty?
      states = metadata.map { |item| item.fetch("status", "unknown").to_s }
      return "complete" if states.all? { |state| state == "complete" }
      return "failed" if states.any? { |state| state == "failed" }
      return "running" if states.any? { |state| state == "running" }
      "unknown"
    end
  end

  class EtaEstimator
    def initialize(records:, samples:)
      @records = records
      @samples = samples
    end

    def estimate
      return nil if @samples.length < MIN_ETA_SAMPLES
      return nil if @records.any? { |record| record.fetch("status") == "unknown" }
      targets = @records.select { |record| %w[pending running].include?(record.fetch("status")) }
      return { "seconds" => 0.0, "targets" => 0, "samples" => @samples.length, "tiers" => {} } if targets.empty?

      tiers = Hash.new(0)
      seconds = targets.sum do |target|
        estimate, tier = estimate_record(target)
        tiers[tier] += 1
        estimate
      end
      { "seconds" => seconds, "targets" => targets.length, "samples" => @samples.length, "tiers" => tiers }
    end

    private

    def estimate_record(target)
      exact = @samples.select do |sample|
        sample.fetch("model_alias") == target.fetch("model_alias") && sample.fetch("dimension") == target.fetch("dimension")
      end
      return [nearest_median(exact, target), "same model+dimension"] unless exact.empty?

      same_model = @samples.select { |sample| sample.fetch("model_alias") == target.fetch("model_alias") }
      return [nearest_median(same_model, target), "same model"] unless same_model.empty?

      [nearest_median(@samples, target), "global"]
    end

    def nearest_median(pool, target)
      target_pages = target["page_count"]
      nearest = pool.sort_by do |sample|
        sample_pages = sample["page_count"] || target_pages
        [target_pages && sample_pages ? (sample_pages - target_pages).abs : 0, sample.fetch("index")]
      end.first(5)
      ProductionBacklogControl.median(nearest.map { |sample| sample.fetch("elapsed_seconds") })
    end
  end

  class Controller
    attr_reader :root, :expected_root, :control_dir

    def initialize(root:, expected_root: DEFAULT_PRODUCTION_ROOT)
      @root = File.expand_path(root)
      @expected_root = File.expand_path(expected_root)
      @control_dir = File.join(@root, "output", "production-backlog-control")
    end

    def start(queue_arg, resume: false)
      queue = Queue.new(root:, queue: queue_arg)
      readiness = verify_launch_readiness!(queue)
      raise Error, "production is paused; use `bin/production-backlog resume #{queue.queue_rel}`" if !resume && File.file?(pause_path)
      raise Error, "production runner is already active (pid #{manager_pid})" if manager_running?
      if (current = current_call) && current["queue"] != queue.queue_rel
        raise Error, "current-call state belongs to #{current['queue']}; inspect it before launching #{queue.queue_rel}"
      elsif current
        raise Error, "current-call state already exists; inspect status before starting another runner"
      end
      FileUtils.rm_f(pause_path) if resume
      FileUtils.mkdir_p(control_dir)

      log_path = File.join(control_dir, "#{queue.name}.log")
      runner = File.join(root, "run_production_backlog.sh")
      raise Error, "missing executable #{runner}" unless File.executable?(runner)
      state = {
        "queue" => queue.queue_rel,
        "pid" => nil,
        "launched_at" => Time.now.iso8601,
        "production_root" => root,
        "repo_head" => readiness.fetch("head"),
        "queue_commit" => queue.queue_commit,
        "log_path" => log_path
      }
      write_manager_state(state)
      pid = Process.spawn(
        { "LME_REPO" => root }, "nohup", runner, queue.queue_rel,
        chdir: root, in: File::NULL, out: [log_path, "a"], err: [:child, :out], pgroup: true
      )
      state["pid"] = pid
      write_manager_state(state)
      Process.detach(pid)
      state
    rescue SystemCallError => e
      state["launch_error"] = e.message if defined?(state) && state
      write_manager_state(state) if defined?(state) && state
      raise Error, "could not start detached production runner: #{e.message}"
    end

    def pause(queue_arg)
      queue = Queue.new(root:, queue: queue_arg)
      verify_production_root!
      if (state = manager_state) && manager_running? && state["queue"] != queue.queue_rel
        raise Error, "active runner belongs to #{state['queue']}, not #{queue.queue_rel}"
      end
      if (current = current_call) && current["queue"] != queue.queue_rel
        raise Error, "active current call belongs to #{current['queue']}, not #{queue.queue_rel}"
      end
      FileUtils.mkdir_p(control_dir)
      File.write(pause_path, Time.now.iso8601 + "\n")
      { "queue" => queue.queue_rel, "current" => current_call(queue.queue_rel), "manager_running" => manager_running? }
    end

    def status(queue_arg)
      verify_production_root!
      queue = Queue.new(root:, queue: queue_arg)
      counts = queue.counts
      terminal = counts["complete"] + counts["failed"]
      manager = manager_state
      manager = nil unless manager && manager["queue"] == queue.queue_rel
      active = manager && process_alive?(manager["pid"])
      current = current_call(queue.queue_rel)
      paused = File.file?(pause_path)
      state = if counts["unknown"].positive?
                "ATTENTION"
              elsif terminal == queue.expected_calls
                counts["failed"].positive? ? "FINISHED_WITH_STICKY_FAILURES" : "FINISHED"
              elsif paused && (active || current)
                "PAUSE_REQUESTED"
              elsif paused
                "PAUSED"
              elsif active
                "RUNNING"
              elsif current
                "ATTENTION"
              elsif manager
                "STOPPED"
              else
                "READY"
              end
      {
        "state" => state,
        "queue" => queue.queue_rel,
        "expected_calls" => queue.expected_calls,
        "counts" => counts,
        "terminal" => terminal,
        "head" => git_head(root),
        "queue_commit" => queue.queue_commit,
        "working_tree_status" => git_status(root),
        "production_root" => root,
        "production_root_matches" => production_root_matches?,
        "manager" => manager,
        "manager_running" => !!active,
        "pause_requested" => paused,
        "current" => current,
        "eta" => EtaEstimator.new(records: queue.records, samples: queue.timing_samples).estimate
      }
    end

    def verify_launch_readiness!(queue)
      verify_production_root!
      head = git_head(root)
      dirty = git_status(root)
      raise Error, "production checkout has uncommitted changes:\n#{dirty}" unless dirty.empty?
      commit = queue.queue_commit
      raise Error, "queue snapshot does not contain a valid local_model_eval_commit" unless commit.match?(/\A[0-9a-f]{40}\z/i)
      raise Error, "queue commit #{commit} is not an ancestor of production HEAD #{head}" unless git_ancestor?(commit, head)
      { "head" => head, "queue_commit" => commit, "calls" => queue.expected_calls }
    end

    def manager_state
      return nil unless File.file?(manager_path)
      JSON.parse(File.read(manager_path))
    rescue JSON::ParserError
      nil
    end

    def manager_pid
      Integer(manager_state && manager_state["pid"])
    rescue ArgumentError, TypeError
      nil
    end

    def manager_running? = process_alive?(manager_pid)

    private

    def manager_path = File.join(control_dir, "manager.json")
    def pause_path = File.join(control_dir, "pause")
    def current_path = File.join(control_dir, "current")

    def write_manager_state(state)
      tmp = "#{manager_path}.tmp-#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(state) + "\n")
      File.rename(tmp, manager_path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp
    end

    def production_root_matches?
      File.directory?(root) && File.directory?(expected_root) && File.realpath(root) == File.realpath(expected_root)
    rescue SystemCallError
      false
    end

    def verify_production_root!
      raise Error, "production commands must run from #{expected_root}; current root is #{root}" unless production_root_matches?
    end

    def git_head(repo)
      out, err, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      raise Error, "cannot read production Git HEAD: #{err.strip}" unless status.success?
      out.strip
    end

    def git_status(repo)
      out, err, status = Open3.capture3("git", "-C", repo, "status", "--porcelain")
      raise Error, "cannot read production working-tree state: #{err.strip}" unless status.success?
      out.rstrip
    end

    def git_ancestor?(ancestor, descendant)
      _out, _err, status = Open3.capture3("git", "-C", root, "merge-base", "--is-ancestor", ancestor, descendant)
      status.success?
    end

    def process_alive?(pid)
      pid = Integer(pid)
      return false unless pid.positive?
      Process.kill(0, pid)
      true
    rescue ArgumentError, TypeError, Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def current_call(queue_rel = nil)
      return nil unless File.file?(current_path)
      data = File.readlines(current_path, chomp: true).each_with_object({}) do |line, out|
        key, value = line.split("=", 2)
        out[key] = value if key && value
      end
      return nil if queue_rel && data["queue"] && data["queue"] != queue_rel
      data
    end
  end
end
