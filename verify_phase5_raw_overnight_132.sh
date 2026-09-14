#!/bin/zsh
set -u

REPO="${LME_REPO:-$HOME/code/af-inference-orchestrator}"
SCRIPT_DIR="${0:A:h}"
ORDER="$SCRIPT_DIR/phase5_raw_run_order.txt"

cd "$REPO" || { echo "ERROR: Could not find $REPO"; exit 1; }
[[ -x bin/lme ]] || { echo "ERROR: bin/lme not found/executable in $REPO"; exit 1; }
[[ -f "$ORDER" ]] || { echo "ERROR: missing $ORDER"; exit 1; }

expected=132
actual=$(grep -c '^experiments/' "$ORDER" || true)
echo "Manifest count: $actual (expected $expected)"
[[ "$actual" -eq "$expected" ]] || { echo "ERROR: wrong manifest count"; exit 1; }

failed=0
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
done < "$ORDER"

if [[ "$failed" -ne 0 ]]; then
  echo "ERROR: $failed manifest(s) failed static preflight. No inference was run."
  exit 1
fi

echo "All 132 manifests passed bin/lme plan."

qwen_sample=$(grep '/qwen-' "$ORDER" | head -n 1)
nemotron_sample=$(grep '/nemotron-' "$ORDER" | head -n 1)

echo
echo "Checking local Qwen worker/model..."
bin/lme worker-check "$qwen_sample" || exit 1

echo
echo "Checking local Nemotron worker/model..."
bin/lme worker-check "$nemotron_sample" || exit 1

echo
echo "PREFLIGHT PASSED — no inference was run."
