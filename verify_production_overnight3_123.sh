#!/bin/zsh
set -u

REPO="${LME_REPO:-$HOME/code/af-inference-orchestrator}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORDER="$SCRIPT_DIR/production_overnight3_run_order.txt"
SESSIONS_ORDER="$SCRIPT_DIR/qualification/sessions-qwen-v0.1/run_order.txt"
SESSIONS_MANIFEST="$SCRIPT_DIR/qualification/sessions-qwen-v0.1/manifest.yml"
SESSIONS_CRITERIA="$SCRIPT_DIR/qualification/sessions-qwen-v0.1/criteria.md"
INDEX="$SCRIPT_DIR/production_overnight3_case_index.csv"
EXPECTED_RUNS=123
EXPECTED_SESSIONS_RUNS=5
EXPECTED_SKIPS=9
EXPECTED_MATRIX=132
EXPECTED_MODEL="qwen3.6:35b-a3b"

cd "$REPO" || { echo "ERROR: Could not find $REPO"; exit 1; }
[[ -x bin/lme ]] || { echo "ERROR: bin/lme not found/executable in $REPO"; exit 1; }
[[ -f "$ORDER" ]] || { echo "ERROR: missing $ORDER"; exit 1; }
[[ -f "$SESSIONS_ORDER" ]] || { echo "ERROR: missing $SESSIONS_ORDER"; exit 1; }
[[ -f "$SESSIONS_MANIFEST" ]] || { echo "ERROR: missing $SESSIONS_MANIFEST"; exit 1; }
[[ -f "$SESSIONS_CRITERIA" ]] || { echo "ERROR: missing $SESSIONS_CRITERIA"; exit 1; }
[[ -f "$INDEX" ]] || { echo "ERROR: missing $INDEX"; exit 1; }

actual=$(grep -c '^experiments/' "$ORDER" || true)
echo "Run manifest count: $actual (expected $EXPECTED_RUNS)"
[[ "$actual" -eq "$EXPECTED_RUNS" ]] || { echo "ERROR: wrong run manifest count"; exit 1; }

dups=$(sort "$ORDER" | uniq -d)
[[ -z "$dups" ]] || { echo "ERROR: duplicate manifest paths:"; echo "$dups"; exit 1; }

sessions_actual=$(grep -c '^experiments/' "$SESSIONS_ORDER" || true)
echo "Sessions qualification manifest count: $sessions_actual (expected $EXPECTED_SESSIONS_RUNS)"
[[ "$sessions_actual" -eq "$EXPECTED_SESSIONS_RUNS" ]] || { echo "ERROR: wrong Sessions qualification manifest count"; exit 1; }
sessions_dups=$(sort "$SESSIONS_ORDER" | uniq -d)
[[ -z "$sessions_dups" ]] || { echo "ERROR: duplicate Sessions qualification manifest paths:"; echo "$sessions_dups"; exit 1; }

# Verify the frozen production matrix and every manifest's semantics without inference.
ruby - "$INDEX" "$ORDER" <<'RUBY' || exit 1
require "csv"
require "yaml"
Encoding.default_external = Encoding::UTF_8

index_path, order_path = ARGV
rows = CSV.read(index_path, headers: true, encoding: "UTF-8")
abort "case index must contain 132 matrix cells" unless rows.length == 132
run_rows = rows.select { |r| r["action"] == "RUN" }
skip_rows = rows.select { |r| r["action"] == "SKIP_AMC_EXISTING" }
abort "case index must contain 123 RUN cells" unless run_rows.length == 123
abort "case index must contain 9 SKIP cells" unless skip_rows.length == 9

expected_paths = run_rows.map { |r| r["manifest_path"] }
order_paths = File.readlines(order_path, chomp: true).reject(&:empty?)
abort "run order does not exactly match RUN rows in case index" unless order_paths == expected_paths

expected_counts = {
  "Combat Emphasis" => 28,
  "Structural Openness" => 29,
  "Darkness / Horror Intensity" => 33,
  "Player Beginner Suitability" => 33,
}
actual_counts = Hash.new(0)
seen_cases = {}

run_rows.each do |row|
  path = row["manifest_path"]
  abort "missing manifest: #{path}" unless File.file?(path)
  data = YAML.safe_load_file(path)
  adv = row["adventure_id"]
  dim = row["dimension"]
  key = [adv, dim]
  abort "duplicate production cell #{key.join(' / ')}" if seen_cases[key]
  seen_cases[key] = true

  abort "wrong model in #{path}" unless data["models"] == ["qwen"]
  abort "wrong dimension in #{path}" unless data["dimension"] == dim
  abort "wrong adventure in #{path}" unless data["adventures"] == [adv]
  abort "wrong replicate count in #{path}" unless data["replicates"] == 1
  abort "wrong worker in #{path}" unless data["workers"] == ["mac"]
  abort "wrong worker labels in #{path}" unless data["required_worker_labels"] == ["local"]
  abort "wrong scorer repo in #{path}" unless data.dig("scorer", "repo") == "../../../af-cli-scoring-utility"
  abort "wrong scorer mode in #{path}" unless data.dig("scorer", "mode") == "positional"
  abort "unexpected scorer extra args in #{path}" unless data.dig("scorer", "extra_args") == []
  abort "wrong cost cap in #{path}" unless data["cost_cap_usd"].to_f == 0.01
  actual_counts[dim] += 1
end

abort "dimension counts mismatch: #{actual_counts.inspect}" unless actual_counts == expected_counts

# Freeze the 9 AMC-existing cells that must not have production manifests.
skips = skip_rows.map { |r| [r["adventure_id"], r["dimension"], r["existing_score"]] }
expected_skips = [
  ["ADV-0278", "Combat Emphasis", "1"],
  ["ADV-0278", "Structural Openness", "5"],
  ["ADV-0200", "Combat Emphasis", "1"],
  ["ADV-0200", "Structural Openness", "1"],
  ["ADV-0230", "Combat Emphasis", "4"],
  ["ADV-0288", "Structural Openness", "1"],
  ["ADV-0323", "Structural Openness", "5"],
  ["ADV-0033", "Combat Emphasis", "5"],
  ["ADV-0020", "Combat Emphasis", "3"],
]
abort "AMC skip cells mismatch" unless skips == expected_skips

puts "Matrix semantics: PASS"
actual_counts.each { |dim, n| puts "  #{dim}: #{n} RUN" }
puts "  AMC-existing skips: #{skip_rows.length}"
RUBY

# Verify the five-case benchmark-blind Sessions qualification cohort separately
# from the 123-cell production matrix. Targets live only in criteria.md and are
# never included in the executable case manifests.
ruby - "$SESSIONS_MANIFEST" "$SESSIONS_ORDER" <<'RUBY' || exit 1
require "yaml"

manifest_path, order_path = ARGV
plan = YAML.safe_load_file(manifest_path)
abort "wrong Sessions qualification plan version" unless plan["version"] == 1
abort "wrong Sessions qualification dimension" unless plan["dimension"] == "# of Sessions"
abort "wrong Sessions candidate model" unless plan["candidate_model"] == "qwen"
abort "wrong Sessions criteria document" unless plan["criteria_document"] == "criteria.md"
abort "wrong Sessions run-order document" unless plan["run_order"] == "run_order.txt"
abort "Sessions qualification must remain benchmark-blind" unless plan.dig("blindness", "expected_values_absent_from_case_manifests") == true
abort "Sessions qualification must adjudicate after inference" unless plan.dig("blindness", "adjudication_after_inference") == true
abort "Sessions qualification must complete all cases" unless plan.dig("execution", "complete_all_cases") == true
abort "Sessions qualification must not stop on score outcomes" unless plan.dig("execution", "score_triggered_stop") == false
abort "Sessions qualification external cost must be zero" unless plan.dig("execution", "external_api_cost_usd").to_f == 0.0

cases = plan["fresh_cases"]
abort "Sessions qualification must contain exactly five fresh cases" unless cases.is_a?(Array) && cases.length == 5
expected_adventures = %w[ADV-0200 ADV-0287 ADV-0040 ADV-0277 ADV-0262]
abort "Sessions qualification adventure order changed" unless cases.map { |c| c["adventure_id"] } == expected_adventures

expected_paths = cases.map { |c| c["manifest"] }
order_paths = File.readlines(order_path, chomp: true).reject(&:empty?)
abort "Sessions run order does not match qualification manifest" unless order_paths == expected_paths

forbidden_keys = %w[target expected_score expected_value oracle_score oracle_value benchmark_sessions accepted_score accepted_value]

cases.each do |case_row|
  path = case_row["manifest"]
  adv = case_row["adventure_id"]
  abort "missing Sessions manifest: #{path}" unless File.file?(path)
  data = YAML.safe_load_file(path)
  abort "wrong model in #{path}" unless data["models"] == ["qwen"]
  abort "wrong dimension in #{path}" unless data["dimension"] == "# of Sessions"
  abort "wrong adventure in #{path}" unless data["adventures"] == [adv]
  abort "wrong replicate count in #{path}" unless data["replicates"] == 1
  abort "wrong worker in #{path}" unless data["workers"] == ["mac"]
  abort "wrong worker labels in #{path}" unless data["required_worker_labels"] == ["local"]
  abort "wrong scorer repo in #{path}" unless data.dig("scorer", "repo") == "../../../af-cli-scoring-utility"
  abort "wrong scorer mode in #{path}" unless data.dig("scorer", "mode") == "positional"
  abort "unexpected scorer extra args in #{path}" unless data.dig("scorer", "extra_args") == []
  abort "wrong cost cap in #{path}" unless data["cost_cap_usd"].to_f == 0.01
  abort "wrong qualification wave in #{path}" unless data.dig("qualification_contract", "wave") == "qwen-sessions-v0.1"
  abort "expected value must remain blind in #{path}" unless data.dig("qualification_contract", "blind_expected_value") == true
  abort "favorable reruns must be forbidden in #{path}" unless data.dig("qualification_contract", "no_favorable_rerun") == true
  leaked = forbidden_keys.select { |k| data.key?(k) || data.dig("qualification_contract", k) }
  abort "target leakage key(s) #{leaked.inspect} in #{path}" unless leaked.empty?
end

puts "Sessions qualification semantics: PASS"
puts "  Fresh cases: #{cases.length}"
puts "  Adventure order: #{expected_adventures.join(', ')}"
puts "  Accepted targets remain outside executable case manifests."
RUBY

# Assert the authorized model alias has not silently changed.
ruby - <<'RUBY' || exit 1
require "yaml"
models = YAML.safe_load_file("config/models.yml")
actual = models.dig("models", "qwen", "ollama_model")
expected = "qwen3.6:35b-a3b"
abort "ERROR: qwen alias is #{actual.inspect}; expected #{expected.inspect}" unless actual == expected
puts "Qwen alias: #{actual} (expected)"
RUBY

failed=0
for order_file in "$SESSIONS_ORDER" "$ORDER"; do
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! -f "$f" ]]; then
      echo "MISSING: $f"
      failed=$((failed + 1))
      continue
    fi
    if ! bin/lme plan "$f" >/dev/null; then
      echo "PLAN FAILED: $f"
      failed=$((failed + 1))
    fi
  done < "$order_file"
done

if [[ "$failed" -ne 0 ]]; then
  echo "ERROR: $failed manifest(s) failed bin/lme plan. No inference was run."
  exit 1
fi

echo "All $EXPECTED_SESSIONS_RUNS Sessions qualification manifests passed bin/lme plan."
echo "All $EXPECTED_RUNS production manifests passed bin/lme plan."

qwen_sample=$(head -n 1 "$SESSIONS_ORDER")
echo
echo "Checking local worker and authorized Qwen model..."
bin/lme worker-check "$qwen_sample" || exit 1

echo
echo "PREFLIGHT PASSED — 5 Sessions qualification cases + 123 RUN cells + 9 protected AMC skips."
echo "The production matrix remains exactly 132 cells; qualification is separate and runs first."
echo "NO INFERENCE WAS RUN."
