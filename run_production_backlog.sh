#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${LME_REPO:-$SCRIPT_DIR}"
export LME_REPO="$REPO"
QUEUE_ARG="${1:-}"
CONTROL_DIR="$REPO/output/production-backlog-control"
PAUSE_FILE="$CONTROL_DIR/pause"
CURRENT_FILE="$CONTROL_DIR/current"
FAIL_LOG="$CONTROL_DIR/failures.log"
BATCH_FAILURE_POLICY="$REPO/lib/batch_failure_policy.sh"
FAILURE_CLASSIFIER="$REPO/bin/classify-production-failure"

[[ -n "$QUEUE_ARG" ]] || {
  echo "Usage: ./run_production_backlog.sh production_backlog/QUEUE"
  exit 2
}

if [[ "$QUEUE_ARG" = /* ]]; then
  QUEUE_DIR="$QUEUE_ARG"
else
  QUEUE_DIR="$REPO/$QUEUE_ARG"
fi
ORDER="$QUEUE_DIR/run_order.txt"
SNAPSHOT="$QUEUE_DIR/snapshot.yml"
SOURCE_PREFLIGHT="$REPO/bin/preflight-production-backlog-sources"
RUNNER_POLICY="$REPO/bin/production-backlog-policy"
DISPATCHER="$REPO/bin/production-backlog-dispatch"

[[ -f "$RUNNER_POLICY" ]] || { echo "ERROR: missing $RUNNER_POLICY"; exit 1; }
[[ -f "$DISPATCHER" ]] || { echo "ERROR: missing $DISPATCHER"; exit 1; }
POLICY_ROUTE="$(ruby --disable-gems "$RUNNER_POLICY" route "$SNAPSHOT")" || {
  echo "ERROR: could not resolve production backlog runner policy."
  exit 1
}
CONTRACT_TYPE="${POLICY_ROUTE%%$'\t'*}"
VERIFY_REL="${POLICY_ROUTE#*$'\t'}"
[[ -n "$VERIFY_REL" && "$VERIFY_REL" != "$POLICY_ROUTE" ]] || {
  echo "ERROR: invalid production backlog runner policy route."
  exit 1
}
VERIFY="$REPO/$VERIFY_REL"

cd "$REPO" || exit 1
mkdir -p "$CONTROL_DIR"

[[ -f "$ORDER" ]] || { echo "ERROR: missing $ORDER"; exit 1; }
[[ -x "$VERIFY" ]] || { echo "ERROR: missing/executable verifier $VERIFY"; exit 1; }
[[ -x "$SOURCE_PREFLIGHT" ]] || { echo "ERROR: missing/executable runtime source preflight $SOURCE_PREFLIGHT"; exit 1; }
[[ -r "$BATCH_FAILURE_POLICY" ]] || { echo "ERROR: missing/readable batch failure policy $BATCH_FAILURE_POLICY"; exit 1; }
[[ -x "$FAILURE_CLASSIFIER" ]] || { echo "ERROR: missing/executable failure classifier $FAILURE_CLASSIFIER"; exit 1; }

source "$BATCH_FAILURE_POLICY"
batch_failure_policy_init

if [[ -f "$PAUSE_FILE" ]]; then
  echo "Background production is paused. Resume with:"
  echo "  ./resume_production_backlog.sh $QUEUE_ARG"
  exit 0
fi

"$VERIFY" "$QUEUE_ARG" || {
  echo "ERROR: backlog preflight failed. No inference launched."
  exit 1
}

export AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE=phase6-v0.3
export AF_INVESTIGATION_GUARDRAIL_PROFILE=phase6-v0.4

echo
echo "Checking runtime source resolution against the active scorer checkout..."
"$SOURCE_PREFLIGHT" "$QUEUE_ARG" || {
  echo "ERROR: runtime source preflight failed. No inference launched."
  exit 1
}

manifest_status() {
  local manifest="$1"
  ruby --disable-gems "$RUNNER_POLICY" status "$manifest" "$REPO/output"
}

if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -dimsu &
  CAFFEINATE_PID=$!
else
  CAFFEINATE_PID=""
  echo "WARNING: caffeinate not found; sleep prevention is not active."
fi

cleanup() {
  rm -f "$CURRENT_FILE"
  if [[ -n "${CAFFEINATE_PID:-}" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

total=$(grep -c '^experiments/' "$ORDER" || true)
n=0

echo
echo "INTERRUPTIBLE BACKGROUND PRODUCTION"
echo "Queue: $QUEUE_ARG"
echo "Calls in frozen queue: $total"
echo "Pause safely from another terminal:"
echo "  ./pause_production_backlog.sh"
echo 'External/API inference cost: $0'
echo

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  n=$((n + 1))

  if [[ -f "$PAUSE_FILE" ]]; then
    echo
    echo "PAUSE OBSERVED after completed call. No new inference dispatched."
    echo "Resume with: ./resume_production_backlog.sh $QUEUE_ARG"
    exit 0
  fi

  if ! manifest_inspection="$(ruby --disable-gems "$RUNNER_POLICY" inspect "$CONTRACT_TYPE" "$f" "$REPO/output")"; then
    echo "ERROR: could not inspect production manifest $f"
    exit 1
  fi
  status="${manifest_inspection%%$'\t'*}"
  runtime_max_tokens="${manifest_inspection#*$'\t'}"
  [[ "$runtime_max_tokens" != "$manifest_inspection" ]] || {
    echo "ERROR: invalid production manifest inspection for $f"
    exit 1
  }

  case "$status" in
    complete)
      echo "[$n/$total] SKIP complete: $f"
      continue
      ;;
    failed)
      echo "[$n/$total] SKIP previously failed (no favorable rerun): $f"
      continue
      ;;
  esac

  {
    echo "queue=$QUEUE_ARG"
    echo "index=$n"
    echo "total=$total"
    echo "manifest=$f"
    echo "started_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$CURRENT_FILE"

  echo
  echo "================================================================"
  echo "[$n/$total] BACKGROUND PRODUCTION: $f"
  echo "================================================================"

  command_ok=true

  # Operational runtime amendment:
  # qwen3.6:35b-a3b high-reasoning production calls can exhaust the
  # scorer's inherited 4096-token generation ceiling before emitting
  # assistant content. Batch 16 ADV-0367 Structural Openness and Darkness
  # reproduced this at exactly 4096 tokens; both completed normally at
  # the cheapest tested higher ceiling, 8192.
  #
  # Scope this narrowly to the six qwen35 core dimensions in the prepared
  # adventure-ingest batches. Other qualified runtimes retain their frozen
  # limits. Also remove any caller-supplied AF_LLM_MAX_TOKENS from unrelated
  # calls so it cannot override EE/GMPB/Seriousness/etc.
  if [[ "$runtime_max_tokens" == "8192" ]]; then
    echo "Operational runtime amendment: AF_LLM_MAX_TOKENS=8192 for qwen35 core dimension."
  fi
  ruby --disable-gems "$DISPATCHER" "$f" "$runtime_max_tokens" || command_ok=false

  status=$(manifest_status "$f")

  if [[ "$command_ok" == true && "$status" == "complete" ]]; then
    batch_failure_record_success
    echo "[$n/$total] COMPLETE"
  else
    failure_class="operational_or_unknown"
    if [[ "$status" == "failed" ]]; then
      classified=""
      if classified=$("$FAILURE_CLASSIFIER" "$f" "$REPO/output"); then
        failure_class="$classified"
      else
        echo "WARNING: failure classifier errored; treating failure as operational/unknown."
      fi
    fi

    if [[ "$failure_class" == "expected_model_validation" ]]; then
      batch_failure_record_expected_model_failure "$status"
    else
      batch_failure_record_failure "$status"
    fi

    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $status $f" >> "$FAIL_LOG"
    echo "[$n/$total] FAILURE status=$status class=$failure_class"
    if [[ "$failure_class" == "expected_model_validation" ]]; then
      echo "Expected sticky model-validation failure; excluded from consecutive operational breaker."
    fi
    echo "New failures this invocation: $batch_total_new_failures; consecutive operational: $batch_consecutive_failures"

    case "$batch_failure_action" in
      checkpoint_continue)
        echo
        echo "FAILURE BUDGET CHECKPOINT: $batch_last_checkpoint_size isolated persisted failures reached."
        echo "Failures remain sticky (no favorable rerun); resetting the isolated-failure budget and continuing."
        echo "Failure budget checkpoints this invocation: $batch_failure_budget_checkpoints"
        ;;
      circuit_break_consecutive)
        echo
        echo "CIRCUIT BREAKER: stopping unattended production."
        echo "Reason: >=${BATCH_CONSECUTIVE_FAILURE_THRESHOLD} consecutive failures."
        echo "Inspect $FAIL_LOG before resuming."
        exit 1
        ;;
      circuit_break_total)
        echo
        echo "CIRCUIT BREAKER: stopping unattended production."
        echo "Reason: isolated-failure budget reached, but the latest failure is not safely persisted as failed."
        echo "Inspect $FAIL_LOG before resuming."
        exit 1
        ;;
      continue)
        ;;
      *)
        echo
        echo "CIRCUIT BREAKER: unknown batch failure-policy action: $batch_failure_action"
        exit 1
        ;;
    esac
  fi

  rm -f "$CURRENT_FILE"

  if [[ -f "$PAUSE_FILE" ]]; then
    echo
    echo "PAUSE OBSERVED after current inference completed and persisted."
    echo "Resume with: ./resume_production_backlog.sh $QUEUE_ARG"
    exit 0
  fi
done < "$ORDER"

echo
echo "================================================================"
echo "BACKGROUND PRODUCTION QUEUE FINISHED"
echo "================================================================"
echo "Queue: $QUEUE_ARG"
echo "New failures this invocation: $batch_total_new_failures"
echo "Failure budget checkpoints this invocation: $batch_failure_budget_checkpoints"
