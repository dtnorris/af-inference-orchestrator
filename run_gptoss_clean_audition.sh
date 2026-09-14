#!/bin/zsh

set -u

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" || {
  echo "ERROR: Could not enter script directory: $SCRIPT_DIR"
  exit 1
}

if [[ ! -x bin/lme ]]; then
  echo "ERROR: bin/lme not found or not executable in $(pwd)"
  echo "Place this script in the root of af-inference-orchestrator."
  exit 1
fi

MANIFESTS=(
  experiments/gptoss-clean-audition-01-social-adv0230-v1.yml
  experiments/gptoss-clean-audition-02-seriousness-adv0062-v1.yml
  experiments/gptoss-clean-audition-03-gm-beginner-adv0287-v1.yml
)

for f in "${MANIFESTS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing manifest: $f"
    exit 1
  fi
done

# af-inference-orchestrator resolves manifest model names through config/models.yml.
# The committed repo did not yet contain a GPT-OSS alias when this audition was built.
if ! ruby -ryaml -e '
  cfg = YAML.load_file("config/models.yml")
  model = cfg.fetch("models", {})["gptoss"]
  exit 1 unless model && model["ollama_model"] == "gpt-oss:20b"
' >/dev/null 2>&1; then
  echo "ERROR: config/models.yml does not define the required GPT-OSS alias."
  echo
  echo "Add this under the existing models: mapping:"
  echo
  echo "  gptoss:"
  echo "    ollama_model: gpt-oss:20b"
  echo
  echo "Then rerun this script."
  exit 1
fi

echo "Preflight: checking mac worker and gpt-oss:20b..."
if ! bin/lme worker-check "${MANIFESTS[1]}"; then
  echo
  echo "ERROR: worker/model preflight failed."
  echo "Confirm Ollama is listening on the normal mac worker endpoint and gpt-oss:20b is installed."
  exit 1
fi

caffeinate -dimsu &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

echo
echo "Working directory: $(pwd)"
echo "caffeinate active (PID $CAFFEINATE_PID)"
echo "GPT-OSS clean non-RSMD audition: maximum 3 local calls"
echo

ADJACENT_MISSES=0
EXACT_PASSES=0

experiment_name() {
  ruby -ryaml -e 'print YAML.load_file(ARGV[0]).fetch("name")' "$1"
}

assert_complete() {
  local experiment="$1"
  local root="output/$experiment"

  ruby -rjson -e '
    root = ARGV[0]
    files = Dir[File.join(root, "runs", "*", "metadata.json")]
    exit 2 if files.empty?
    statuses = files.map { |f| JSON.parse(File.read(f))["status"] }
    exit 3 unless statuses.all? { |s| s == "complete" }
  ' "$root"
}

metric_value() {
  local experiment="$1"
  local metric="$2"
  local root="output/$experiment"

  ruby -rcsv -e '
    root, metric = ARGV
    files = Dir[File.join(root, "runs", "*", "native", "assessments", "*.csv")]
    exit 2 if files.empty?
    file = files.max_by { |f| File.mtime(f) }
    row = CSV.foreach(file, headers: true).find { |r| r["metric"] == metric }
    exit 3 unless row && row["value"] && !row["value"].empty?
    print row["value"]
  ' "$root" "$metric"
}

run_discriminator() {
  local manifest="$1"
  local metric="$2"
  local target="$3"
  local experiment value delta

  experiment=$(experiment_name "$manifest") || {
    echo "ERROR: Could not read experiment name from $manifest"
    return 10
  }

  echo
  echo "================================================================"
  echo "RUNNING: $manifest"
  echo "TARGET:  $metric = $target"
  echo "================================================================"

  if ! bin/lme run "$manifest"; then
    echo
    echo "AUDITION FAILED: af-inference-orchestrator returned an operational error."
    return 20
  fi

  if ! assert_complete "$experiment"; then
    echo
    echo "AUDITION FAILED: job did not finish with status=complete."
    echo "Inspect output/$experiment/runs/*/stderr.log"
    return 21
  fi

  value=$(metric_value "$experiment" "$metric") || {
    echo
    echo "AUDITION FAILED: could not recover a validated '$metric' value."
    echo "This counts as a structured/output-path failure, not a scoring miss."
    return 22
  }

  if [[ ! "$value" =~ '^[0-9]+$' ]]; then
    echo
    echo "AUDITION FAILED: non-integer metric value: $value"
    return 23
  fi

  delta=$(( value - target ))
  (( delta < 0 )) && delta=$(( -delta ))

  echo
  echo "RESULT: $metric = $value"

  if (( delta == 0 )); then
    EXACT_PASSES=$(( EXACT_PASSES + 1 ))
    echo "CLASSIFICATION: EXACT PASS"
    return 0
  fi

  if (( delta == 1 )); then
    ADJACENT_MISSES=$(( ADJACENT_MISSES + 1 ))
    echo "CLASSIFICATION: ADJACENT MISS ($ADJACENT_MISSES total)"

    if (( ADJACENT_MISSES >= 2 )); then
      echo
      echo "AUDITION STOP: two misses have occurred. Do not deepen GPT-OSS testing."
      return 30
    fi

    return 0
  fi

  echo "CLASSIFICATION: NON-ADJACENT MISS"
  echo
  echo "AUDITION STOP: serious miss. Do not deepen GPT-OSS testing."
  return 31
}

# 1 — low anchor, play_mix scorer group.
run_discriminator \
  "${MANIFESTS[1]}" \
  "Social Interaction Emphasis" \
  1 || exit $?

# 2 — middle anchor, experience_tone scorer group.
run_discriminator \
  "${MANIFESTS[2]}" \
  "Seriousness" \
  3 || exit $?

# 3 — high anchor, beginner_suitability scorer group.
run_discriminator \
  "${MANIFESTS[3]}" \
  "GM Beginner Suitability" \
  5 || exit $?

echo
echo "================================================================"
echo "GPT-OSS CLEAN AUDITION COMPLETE"
echo "Exact passes:    $EXACT_PASSES / 3"
echo "Adjacent misses: $ADJACENT_MISSES / 3"

if (( EXACT_PASSES == 3 )); then
  echo "VERDICT: 3/3 EXACT — GPT-OSS EARNS A BROADER NON-RSMD AUDITION."
elif (( EXACT_PASSES == 2 && ADJACENT_MISSES == 1 )); then
  echo "VERDICT: 2/3 EXACT + 1 ADJACENT — GPT-OSS SURVIVES CAUTIOUSLY."
else
  echo "VERDICT: REVIEW REQUIRED."
fi

echo "================================================================"
