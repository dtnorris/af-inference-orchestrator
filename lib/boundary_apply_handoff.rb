# frozen_string_literal: true

require "digest"
require "json"
require_relative "adventure_ingest"

module AdventureIngest
  class BoundaryApplyHandoff
    SCHEMA_VERSION = "af-boundary-freeze-apply-report/v0.1"
    COMMAND_SCHEMA_VERSION = "af-data-boundary-freeze-apply/v0.1"
    BOUNDARY_SCHEMA_VERSION = "af-boundary-freeze/v0.1"
    SHA256_RE = /\A[0-9a-f]{64}\z/i
    ADV_ID_RE = /\AADV-\d{4}\z/
    TARGET_FIELDS = %w[id title source_book publisher start_page end_page level_start level_end needs_levels].freeze

    attr_reader :path, :sha256, :catalog_filename, :catalog_sha256, :ids, :expected_targets, :source_id, :publisher

    def self.load(path)
      new(path)
    end

    def initialize(path)
      @path = File.expand_path(path.to_s)
      raise Error, "boundary apply receipt not found: #{@path}" unless File.file?(@path)

      raw = File.binread(@path)
      @sha256 = Digest::SHA256.hexdigest(raw)
      data = JSON.parse(raw)
      validate!(data)
    rescue JSON::ParserError => e
      raise Error, "invalid boundary apply receipt JSON: #{e.message}"
    end

    def verify_unchanged!
      raise Error, "boundary apply receipt disappeared: #{path}" unless File.file?(path)

      actual = Digest::SHA256.file(path).hexdigest
      raise Error, "boundary apply receipt changed after selection: expected #{sha256}, got #{actual}" unless actual == sha256

      true
    end

    def verify_snapshot!(snapshot)
      verify_unchanged!

      actual_filename = snapshot.fetch("catalog_filename")
      unless actual_filename == catalog_filename
        raise Error, "boundary apply handoff catalog mismatch: expected #{catalog_filename}, got #{actual_filename}"
      end

      actual_sha = snapshot.fetch("catalog_sha256")
      unless actual_sha == catalog_sha256
        raise Error, "boundary apply handoff catalog SHA-256 mismatch for #{catalog_filename}: expected #{catalog_sha256}, got #{actual_sha}"
      end

      actual_ids = snapshot.fetch("adventure_order")
      unless actual_ids == ids
        raise Error, "boundary apply handoff Adventure-ID scope/order mismatch: expected #{ids.join(', ')}, got #{actual_ids.join(', ')}"
      end

      actual_targets = snapshot.fetch("selected_adventures").map do |target|
        TARGET_FIELDS.to_h { |field| [field, target.fetch(field)] }
      end
      return true if actual_targets == expected_targets

      mismatch_index = expected_targets.each_index.find { |index| expected_targets[index] != actual_targets[index] }
      expected = expected_targets.fetch(mismatch_index)
      actual = actual_targets.fetch(mismatch_index)
      differences = TARGET_FIELDS.filter_map do |field|
        next if expected[field] == actual[field]
        "#{field}=#{expected[field].inspect} -> #{actual[field].inspect}"
      end
      raise Error, "boundary apply handoff scope metadata mismatch for #{expected.fetch('id')}: #{differences.join(', ')}"
    end

    def provenance
      {
        "path" => path,
        "sha256" => sha256,
        "schema_version" => SCHEMA_VERSION,
        "command_schema_version" => COMMAND_SCHEMA_VERSION,
        "output_catalog_filename" => catalog_filename,
        "output_catalog_sha256" => catalog_sha256,
        "canonical_source_id" => source_id,
        "book_publisher" => publisher,
        "adventure_ids" => ids.dup
      }
    end

    private

    def validate!(data)
      hash!(data, "receipt")
      exact!(data["schema_version"], SCHEMA_VERSION, "schema_version")
      exact!(data["command_schema_version"], COMMAND_SCHEMA_VERSION, "command_schema_version")
      exact!(data["status"], "complete", "status")

      freeze = hash!(data["boundary_freeze"], "boundary_freeze")
      exact!(freeze["schema_version"], BOUNDARY_SCHEMA_VERSION, "boundary_freeze.schema_version")
      string!(freeze["approved_by"], "boundary_freeze.approved_by")
      string!(freeze["approved_at"], "boundary_freeze.approved_at")

      source = hash!(data["source"], "source")
      @source_id = string!(source["canonical_source_id"], "source.canonical_source_id")
      @publisher = string!(source["book_publisher"], "source.book_publisher")

      output_amc = hash!(data["output_amc"], "output_amc")
      output_path = string!(output_amc["path"], "output_amc.path")
      @catalog_filename = File.basename(output_path)
      unless @catalog_filename.end_with?(".xlsx") && @catalog_filename == File.basename(@catalog_filename)
        raise Error, "boundary apply receipt output_amc.path must name an XLSX catalog"
      end
      @catalog_sha256 = sha256!(output_amc["sha256"], "output_amc.sha256")

      records = data["records"]
      raise Error, "boundary apply receipt records must be a nonempty array" unless records.is_a?(Array) && !records.empty?

      @expected_targets = records.each_with_index.map do |record, index|
        record = hash!(record, "records[#{index}]")
        adventure_id = string!(record["adventure_id"], "records[#{index}].adventure_id")
        raise Error, "invalid Adventure ID in boundary apply receipt: #{adventure_id.inspect}" unless ADV_ID_RE.match?(adventure_id)

        pages = hash!(record["printed_pages"], "records[#{index}].printed_pages")
        start_page = positive_integer!(pages["start"], "records[#{index}].printed_pages.start")
        end_page = positive_integer!(pages["end"], "records[#{index}].printed_pages.end")
        raise Error, "invalid printed page range for #{adventure_id}" if end_page < start_page

        levels = record["levels"]
        if levels
          levels = hash!(levels, "records[#{index}].levels")
          level_start = positive_integer!(levels["start"], "records[#{index}].levels.start")
          level_end = positive_integer!(levels["end"], "records[#{index}].levels.end")
          raise Error, "invalid Levels range for #{adventure_id}" if level_end < level_start
        end

        {
          "id" => adventure_id,
          "title" => string!(record["canonical_title"], "records[#{index}].canonical_title"),
          "source_book" => @source_id,
          "publisher" => @publisher,
          "start_page" => start_page,
          "end_page" => end_page,
          "level_start" => levels && level_start,
          "level_end" => levels && level_end,
          "needs_levels" => levels.nil?
        }
      end
      @expected_targets.each(&:freeze)
      @expected_targets.freeze
      @ids = @expected_targets.map { |target| target.fetch("id") }.freeze
      raise Error, "boundary apply receipt contains duplicate Adventure IDs" unless ids.uniq == ids

      counts = hash!(data["counts"], "counts")
      record_count = records.length
      exact_integer!(counts["frozen_records"], record_count, "counts.frozen_records")
      exact_integer!(counts["adventure_ids_assigned"], record_count, "counts.adventure_ids_assigned")
      exact_integer!(counts["errors"], 0, "counts.errors")

      allocation = hash!(data["allocation"], "allocation")
      exact!(allocation["order"], "boundary-freeze record order", "allocation.order")
      exact!(allocation["first_adventure_id"], ids.first, "allocation.first_adventure_id")
      exact!(allocation["last_adventure_id"], ids.last, "allocation.last_adventure_id")

      verification = hash!(data["verification"], "verification")
      exact!(verification["passed"], true, "verification.passed")
      exact_integer!(verification["unauthorized_cell_changes"], 0, "verification.unauthorized_cell_changes")
      exact_integer!(verification["records_verified"], record_count, "verification.records_verified")
      exact_integer!(
        verification["unassessed_scoring_fields_verified_blank"],
        record_count,
        "verification.unassessed_scoring_fields_verified_blank"
      )
      unexpected = verification["unexpected_package_member_changes"]
      unless unexpected.is_a?(Array) && unexpected.empty?
        raise Error, "boundary apply receipt verification.unexpected_package_member_changes must be empty"
      end
    end

    def hash!(value, label)
      raise Error, "boundary apply receipt #{label} must be an object" unless value.is_a?(Hash)
      value
    end

    def string!(value, label)
      text = value.to_s.strip
      raise Error, "boundary apply receipt #{label} must be nonblank" if text.empty?
      text
    end

    def sha256!(value, label)
      digest = string!(value, label).downcase
      raise Error, "boundary apply receipt #{label} must be a 64-hex SHA-256" unless SHA256_RE.match?(digest)
      digest
    end

    def positive_integer!(value, label)
      integer = Integer(value)
      raise Error, "boundary apply receipt #{label} must be a positive integer" unless integer.positive?
      integer
    rescue ArgumentError, TypeError
      raise Error, "boundary apply receipt #{label} must be a positive integer"
    end

    def exact_integer!(value, expected, label)
      actual = Integer(value)
      raise Error, "boundary apply receipt #{label} must equal #{expected.inspect}, got #{actual.inspect}" unless actual == expected
      actual
    rescue ArgumentError, TypeError
      raise Error, "boundary apply receipt #{label} must equal #{expected.inspect}, got #{value.inspect}"
    end

    def exact!(actual, expected, label)
      raise Error, "boundary apply receipt #{label} must equal #{expected.inspect}, got #{actual.inspect}" unless actual == expected
      actual
    end
  end

  class BoundaryApplyBatch < Batch
    def initialize(root:, batch:, handoff:, scorer_repo: nil, clamp_ids: [], clamp_gaps: {})
      @handoff = handoff
      super(
        root: root,
        batch: batch,
        catalog: handoff.catalog_filename,
        ids: handoff.ids,
        scorer_repo: scorer_repo,
        clamp_ids: clamp_ids,
        clamp_gaps: clamp_gaps
      )
    end

    def interpretation(catalog_path = catalog_path_for(scorer_repo))
      @handoff.verify_unchanged!
      snapshot = super(catalog_path)
      @handoff.verify_snapshot!(snapshot)
      snapshot.merge("boundary_apply_handoff" => @handoff.provenance)
    end
  end
end
