#!/bin/zsh

(
  cd "$HOME/code/af-inference-orchestrator" || {
    echo "ERROR: Could not find $HOME/code/af-inference-orchestrator"
    return
  }

  if [[ ! -x bin/lme ]]; then
    echo "ERROR: bin/lme not found or not executable in $(pwd)"
    return
  fi

  caffeinate -dimsu &
  CAFFEINATE_PID=$!

  trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

  echo "Working directory: $(pwd)"
  echo "caffeinate active (PID $CAFFEINATE_PID)"

  for f in \
    experiments/11-qwen-lethality-adv0034-upper-endpoint-v1.yml \
    experiments/12-qwen-lethality-adv0278-lower-endpoint-v1.yml \
    experiments/13-qwen-darkness-adv0287-upper-endpoint-v1.yml \
    experiments/14-qwen-darkness-adv0062-lower-endpoint-v1.yml \
    experiments/15-qwen-combat-adv0277-lower-endpoint-v1.yml \
    experiments/16-qwen-investigation-adv0034-lower-endpoint-v1.yml \
    experiments/17-qwen-structural-openness-adv0278-upper-endpoint-v1.yml \
    experiments/18-qwen-seriousness-adv0013-lower-endpoint-v1.yml \
    experiments/19-qwen-player-beginner-adv0262-upper-endpoint-v1.yml \
    experiments/20-qwen-gm-improvisation-adv0303-high-control-v1.yml
  do
    echo
    echo "================================================================"
    echo "RUNNING: $f"
    echo "================================================================"

    if ! bin/lme run "$f"; then
      echo
      echo "ERROR: $f failed operationally; stopping batch."
      break
    fi
  done

  echo
  echo "================================================================"
  echo "BATCH FINISHED"
  echo "================================================================"
)
