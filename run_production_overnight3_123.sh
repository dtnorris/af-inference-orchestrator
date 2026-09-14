#!/bin/zsh
set -u

REPO="${LME_REPO:-$HOME/code/af-inference-orchestrator}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORDER="$SCRIPT_DIR/production_overnight3_run_order.txt"
SESSIONS_ORDER="$SCRIPT_DIR/qualification/sessions-qwen-v0.1/run_order.txt"
VERIFY="$SCRIPT_DIR/verify_production_overnight3_123.sh"
FAILED="$REPO/production_overnight3_failed.txt"
SESSIONS_FAILED="$REPO/sessions_qwen_qualification_failed.txt"

cd "$REPO" || { echo "ERROR: Could not find $REPO"; exit 1; }
[[ -x "$VERIFY" ]] || { echo "ERROR: missing/executable verifier $VERIFY"; exit 1; }
[[ -f "$ORDER" ]] || { echo "ERROR: missing $ORDER"; exit 1; }
[[ -f "$SESSIONS_ORDER" ]] || { echo "ERROR: missing $SESSIONS_ORDER"; exit 1; }

# Hard gate: this performs matrix checks, bin/lme plan on all manifests, and worker/model check.
# It never launches inference.
"$VERIFY" || { echo "ERROR: production preflight failed. No inference launched."; exit 1; }

total=$(grep -c '^experiments/' "$ORDER" || true)
[[ "$total" -eq 123 ]] || { echo "ERROR: expected 123 run manifests; got $total"; exit 1; }
sessions_total=$(grep -c '^experiments/' "$SESSIONS_ORDER" || true)
[[ "$sessions_total" -eq 5 ]] || { echo "ERROR: expected 5 Sessions qualification manifests; got $sessions_total"; exit 1; }

: > "$FAILED"
: > "$SESSIONS_FAILED"

caffeinate -dimsu &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT INT TERM

echo
echo "Working directory: $(pwd)"
echo "caffeinate active (PID $CAFFEINATE_PID)"
echo "Model: qwen => qwen3.6:35b-a3b"
echo "Sessions qualification cases: 5 (run first; separate from production accounting)"
echo "Production cells: 123 (9 AMC-existing cells protected/skipped)"
echo "Completed jobs are skipped by bin/lme, so this batch is resumable."
echo "Qualification numeric outcomes never stop the production batch."

q=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  q=$((q + 1))

  echo
  echo "================================================================"
  echo "[$q/$sessions_total] SESSIONS QUALIFICATION: $f"
  echo "================================================================"

  if ! bin/lme run "$f"; then
    echo "FAILED: $f" | tee -a "$SESSIONS_FAILED"
    echo "Continuing through qualification and then production; adjudication happens after persisted outputs are reviewed."
  fi
done < "$SESSIONS_ORDER"

echo
echo "================================================================"
echo "SESSIONS QUALIFICATION BLOCK FINISHED — STARTING PRODUCTION"
echo "================================================================"
if [[ -s "$SESSIONS_FAILED" ]]; then
  echo "Some Sessions qualification cases failed operationally. Review later: $SESSIONS_FAILED"
else
  rm -f "$SESSIONS_FAILED"
  echo "No Sessions qualification operational failures recorded."
fi

n=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  n=$((n + 1))

  echo
  echo "================================================================"
  echo "[$n/$total] PRODUCTION: $f"
  echo "================================================================"

  if ! bin/lme run "$f"; then
    echo "FAILED: $f" | tee -a "$FAILED"
    echo "Continuing to the next production cell so one source/job does not waste the overnight window."
  fi
done < "$ORDER"

echo
echo "================================================================"
echo "OVERNIGHT3 PRODUCTION BATCH FINISHED"
echo "================================================================"
if [[ -s "$FAILED" ]]; then
  echo "Some production cells failed. Review: $FAILED"
else
  rm -f "$FAILED"
  echo "No production operational failures recorded."
fi
if [[ -s "$SESSIONS_FAILED" ]]; then
  echo "Sessions qualification operational failures remain in: $SESSIONS_FAILED"
fi
