#!/bin/zsh
set -u

REPO="${LME_REPO:-$HOME/code/af-inference-orchestrator}"
SCRIPT_DIR="${0:A:h}"
ORDER="$SCRIPT_DIR/phase5_raw_run_order.txt"
FAILED="$REPO/phase5_raw_overnight_failed.txt"

cd "$REPO" || { echo "ERROR: Could not find $REPO"; exit 1; }
[[ -x bin/lme ]] || { echo "ERROR: bin/lme not found/executable in $REPO"; exit 1; }
[[ -f "$ORDER" ]] || { echo "ERROR: missing $ORDER"; exit 1; }

# Static validation before any inference.
failed_preflight=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ ! -f "$f" ]] || ! bin/lme plan "$f" >/dev/null; then
    echo "PREFLIGHT FAILED: $f"
    failed_preflight=$((failed_preflight + 1))
  fi
done < "$ORDER"
if [[ "$failed_preflight" -ne 0 ]]; then
  echo "ERROR: $failed_preflight manifest(s) failed preflight. No inference launched."
  exit 1
fi

qwen_sample=$(grep '/qwen-' "$ORDER" | head -n 1)
nemotron_sample=$(grep '/nemotron-' "$ORDER" | head -n 1)

qwen_ok=1
nemotron_ok=1
bin/lme worker-check "$qwen_sample" >/dev/null || qwen_ok=0
bin/lme worker-check "$nemotron_sample" >/dev/null || nemotron_ok=0
if [[ "$qwen_ok" -eq 0 && "$nemotron_ok" -eq 0 ]]; then
  echo "ERROR: neither Qwen nor Nemotron passed worker-check. No inference launched."
  exit 1
fi

: > "$FAILED"

caffeinate -dimsu &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT INT TERM

echo "Working directory: $(pwd)"
echo "caffeinate active (PID $CAFFEINATE_PID)"
echo "Qwen available: $qwen_ok | Nemotron available: $nemotron_ok"
echo "Completed jobs are skipped by bin/lme, so this batch is resumable."

n=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  n=$((n + 1))

  if [[ "$f" == *"/qwen-"* && "$qwen_ok" -eq 0 ]]; then
    echo "SKIPPING unavailable Qwen case: $f" | tee -a "$FAILED"
    continue
  fi
  if [[ "$f" == *"/nemotron-"* && "$nemotron_ok" -eq 0 ]]; then
    echo "SKIPPING unavailable Nemotron case: $f" | tee -a "$FAILED"
    continue
  fi

  echo
  echo "================================================================"
  echo "[$n/132] RUNNING: $f"
  echo "================================================================"

  if ! bin/lme run "$f"; then
    echo "FAILED: $f" | tee -a "$FAILED"
    echo "Continuing to next case so one bad source/job does not waste the overnight window."
  fi
done < "$ORDER"

echo
echo "================================================================"
echo "RAW PHASE-5 OVERNIGHT BATCH FINISHED"
echo "================================================================"
if [[ -s "$FAILED" ]]; then
  echo "Some cases failed/skipped. Review: $FAILED"
else
  rm -f "$FAILED"
  echo "No operational failures recorded."
fi
