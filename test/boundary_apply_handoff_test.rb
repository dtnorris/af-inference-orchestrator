# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/boundary_apply_handoff"

class BoundaryApplyHandoffTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("boundary-apply-handoff-test")
    @path = File.join(@dir, "apply-report.json")
    write_receipt
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def receipt
    {
      "schema_version" => "af-boundary-freeze-apply-report/v0.1",
      "command_schema_version" => "af-data-boundary-freeze-apply/v0.1",
      "status" => "complete",
      "boundary_freeze" => {
        "schema_version" => "af-boundary-freeze/v0.1",
        "approved_by" => "David",
        "approved_at" => "2026-09-24T08:00:00-04:00"
      },
      "source" => {
        "canonical_source_id" => "Fixture Book",
        "book_publisher" => "Fixture Publisher"
      },
      "output_amc" => {
        "path" => "/Users/davidnorris/code/af-xlsx-data-sources/5e_Adventure_Master_Catalog_7.1.xlsx",
        "sha256" => "a" * 64
      },
      "counts" => {
        "frozen_records" => 2,
        "adventure_ids_assigned" => 2,
        "errors" => 0
      },
      "allocation" => {
        "first_adventure_id" => "ADV-1000",
        "last_adventure_id" => "ADV-1001",
        "order" => "boundary-freeze record order"
      },
      "records" => [
        {
          "adventure_id" => "ADV-1000",
          "canonical_title" => "Parent Adventure",
          "printed_pages" => {"start" => 10, "end" => 20},
          "levels" => {"start" => 3, "end" => 5}
        },
        {
          "adventure_id" => "ADV-1001",
          "canonical_title" => "Nested Adventure",
          "printed_pages" => {"start" => 14, "end" => 18}
        }
      ],
      "verification" => {
        "passed" => true,
        "unauthorized_cell_changes" => 0,
        "records_verified" => 2,
        "unassessed_scoring_fields_verified_blank" => 2,
        "unexpected_package_member_changes" => []
      }
    }
  end

  def write_receipt(data = receipt)
    File.write(@path, JSON.pretty_generate(data))
  end

  def load_handoff
    AdventureIngest::BoundaryApplyHandoff.load(@path)
  end

  def snapshot
    {
      "catalog_filename" => "5e_Adventure_Master_Catalog_7.1.xlsx",
      "catalog_sha256" => "a" * 64,
      "adventure_order" => %w[ADV-1000 ADV-1001],
      "selected_adventures" => [
        {
          "id" => "ADV-1000",
          "title" => "Parent Adventure",
          "source_book" => "Fixture Book",
          "publisher" => "Fixture Publisher",
          "page_count" => 11,
          "start_page" => 10,
          "end_page" => 20,
          "level_start" => 3,
          "level_end" => 5,
          "needs_levels" => false
        },
        {
          "id" => "ADV-1001",
          "title" => "Nested Adventure",
          "source_book" => "Fixture Book",
          "publisher" => "Fixture Publisher",
          "page_count" => 5,
          "start_page" => 14,
          "end_page" => 18,
          "level_start" => nil,
          "level_end" => nil,
          "needs_levels" => true
        }
      ]
    }
  end

  def test_derives_catalog_and_exact_record_scope
    handoff = load_handoff

    assert_equal "5e_Adventure_Master_Catalog_7.1.xlsx", handoff.catalog_filename
    assert_equal "a" * 64, handoff.catalog_sha256
    assert_equal %w[ADV-1000 ADV-1001], handoff.ids
    assert_equal [false, true], handoff.expected_targets.map { |target| target.fetch("needs_levels") }
    assert handoff.verify_snapshot!(snapshot)
  end

  def test_rejects_catalog_hash_or_record_metadata_drift
    handoff = load_handoff

    changed_catalog = Marshal.load(Marshal.dump(snapshot))
    changed_catalog["catalog_sha256"] = "b" * 64
    error = assert_raises(AdventureIngest::Error) { handoff.verify_snapshot!(changed_catalog) }
    assert_match(/catalog SHA-256 mismatch/, error.message)

    changed_scope = Marshal.load(Marshal.dump(snapshot))
    changed_scope["selected_adventures"][1]["title"] = "Changed Title"
    error = assert_raises(AdventureIngest::Error) { handoff.verify_snapshot!(changed_scope) }
    assert_match(/scope metadata mismatch/, error.message)
    assert_match(/title=/, error.message)
  end

  def test_rejects_scope_order_drift
    handoff = load_handoff
    changed = Marshal.load(Marshal.dump(snapshot))
    changed["adventure_order"].reverse!

    error = assert_raises(AdventureIngest::Error) { handoff.verify_snapshot!(changed) }
    assert_match(/scope\/order mismatch/, error.message)
  end

  def test_rejects_receipt_mutation_after_selection
    handoff = load_handoff
    File.open(@path, "a") { |file| file.puts }

    error = assert_raises(AdventureIngest::Error) { handoff.verify_unchanged! }
    assert_match(/changed after selection/, error.message)
  end

  def test_rejects_unverified_or_internally_inconsistent_receipts
    mutations = [
      ->(data) { data["status"] = "incomplete" },
      ->(data) { data["verification"]["passed"] = false },
      ->(data) { data["verification"]["unauthorized_cell_changes"] = 1 },
      ->(data) { data["counts"]["adventure_ids_assigned"] = 1 },
      ->(data) { data["records"][1]["adventure_id"] = "ADV-1000" },
      ->(data) { data["verification"]["unexpected_package_member_changes"] = ["xl/workbook.xml"] }
    ]

    mutations.each do |mutate|
      data = receipt
      mutate.call(data)
      write_receipt(data)
      assert_raises(AdventureIngest::Error) { load_handoff }
    end
  end

  def test_receipt_bound_batch_uses_receipt_catalog_and_ids
    handoff = load_handoff
    batch = AdventureIngest::BoundaryApplyBatch.new(root: @dir, batch: "037", handoff: handoff, scorer_repo: @dir)

    assert_equal "5e_Adventure_Master_Catalog_7.1.xlsx", batch.catalog_filename
    assert_equal "production-backlog-037", batch.queue
  end
end
