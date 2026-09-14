#!/bin/bash
set -u

# Batch-009 local runtime guard.
#
# Uses the captured batch009-runtime-state.txt as the reference state, performs
# only two narrowly safe repairs:
#   1. Re-pins af-cli-scoring-utility to the captured scorer commit if its
#      working tree is clean.
#   2. Restores the exact historical AMC blob if the file is missing/empty and
#      the captured SHA-256 can be recovered from local git history.
#
# It does NOT reset dirty repositories, rewrite source/spec repos, change
# workers.yml, install/upgrade Ollama, pull models, or launch inference.
#
# Usage:
#   bin/ensure-batch009-runtime
#   bin/ensure-batch009-runtime /path/to/batch009-runtime-state.txt

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LME="$HOME/code/af-inference-orchestrator"
SCORER="$HOME/code/af-cli-scoring-utility"
XLSX="$HOME/code/af-xlsx-data-sources"
SOURCE="$HOME/code/md-for-llm-book-content"
SPECS="$HOME/code/md-specification-files"

QUEUE="production_backlog/production-backlog-009"
SNAPSHOT="$LME/$QUEUE/snapshot.yml"
CONTROL="$LME/output/production-backlog-control"

REF="${1:-$CONTROL/batch009-runtime-state.txt}"

PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN  %s\n' "$*" >&2; WARN=$((WARN + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

die_if_missing() {
  if [ ! -e "$1" ]; then
    fail "missing: $1"
    return 1
  fi
  return 0
}

extract_repo_sha() {
  repo_path="$1"
  /usr/bin/awk -v section="=== $repo_path ===" '
    $0 == section { inside=1; next }
    inside && /^=== / { exit }
    inside {
      if ($0 ~ /^[0-9a-f]+$/ && length($0) == 40) {
        print $0
        exit
      }
      if ($0 ~ /^[[:space:]]*commit:[[:space:]]*[0-9a-f]+/) {
        sub(/^[[:space:]]*commit:[[:space:]]*/, "", $0)
        if (length($0) == 40) {
          print $0
          exit
        }
      }
    }
  ' "$REF"
}

extract_amc_sha() {
  /usr/bin/awk '
    /^=== historical runtime AMC ===$/ { getline; print $1; exit }
  ' "$REF"
}

extract_ollama_server_version() {
  /usr/bin/awk '
    /^=== Ollama ===$/ { inside=1; next }
    inside && /^ollama version is / { print $4; exit }
  ' "$REF"
}

extract_model_field() {
  wanted="$1"
  /usr/bin/awk -v wanted="$wanted" '
    /^=== Ollama ===$/ { inside=1; next }
    inside && /^=== / { exit }
    inside {
      line=$0
      gsub(/^[[:space:]]+/, "", line)
      if (index(line, wanted) == 1) {
        sub("^" wanted "[[:space:]]+", "", line)
        print line
        exit
      }
    }
  ' "$REF"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

repo_head() {
  /usr/bin/git -C "$1" rev-parse HEAD 2>/dev/null
}

repo_dirty() {
  [ -n "$(/usr/bin/git -C "$1" status --porcelain 2>/dev/null)" ]
}

check_exact_repo() {
  label="$1"
  repo="$2"
  expected="$3"

  if [ -z "$expected" ]; then
    fail "$label: reference file did not contain a commit SHA"
    return
  fi
  if [ ! -d "$repo/.git" ]; then
    fail "$label: not a git checkout: $repo"
    return
  fi

  actual="$(repo_head "$repo")"
  if [ "$actual" = "$expected" ]; then
    pass "$label HEAD = $expected"
  else
    fail "$label HEAD mismatch: expected $expected, got ${actual:-UNKNOWN}"
  fi
}

restore_exact_amc_if_needed() {
  rel="5e_Adventure_Master_Catalog_2.4.5.xlsx"
  path="$XLSX/$rel"
  expected="$1"

  if [ -z "$expected" ]; then
    fail "reference file did not contain historical AMC SHA-256"
    return
  fi

  if [ -s "$path" ]; then
    actual="$(sha256_file "$path")"
    if [ "$actual" = "$expected" ]; then
      pass "historical AMC 2.4.5 SHA-256 = $expected"
    else
      fail "historical AMC exists but hash differs; refusing to overwrite: $path"
      fail "expected $expected; got $actual"
    fi
    return
  fi

  if [ -e "$path" ] && [ ! -s "$path" ]; then
    warn "removing zero-byte historical AMC placeholder: $path"
    /bin/rm -f "$path" || {
      fail "could not remove zero-byte AMC placeholder"
      return
    }
  fi

  tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/batch009-amc.XXXXXX")" || {
    fail "could not allocate temporary AMC file"
    return
  }

  found=""
  for c in $(/usr/bin/git -C "$XLSX" rev-list --all -- "$rel" 2>/dev/null); do
    if /usr/bin/git -C "$XLSX" cat-file -e "$c:$rel" 2>/dev/null; then
      if /usr/bin/git -C "$XLSX" show "$c:$rel" > "$tmp" 2>/dev/null; then
        candidate="$(sha256_file "$tmp")"
        if [ "$candidate" = "$expected" ]; then
          found="$c"
          break
        fi
      fi
    fi
  done

  if [ -z "$found" ]; then
    /bin/rm -f "$tmp"
    fail "could not recover AMC 2.4.5 with captured SHA-256 $expected from local git history"
    return
  fi

  /bin/mv "$tmp" "$path" || {
    /bin/rm -f "$tmp"
    fail "could not restore historical AMC to $path"
    return
  }

  pass "restored historical AMC 2.4.5 from git commit $found"
  pass "historical AMC 2.4.5 SHA-256 = $expected"
}

ensure_scorer_commit() {
  expected="$1"

  if [ -z "$expected" ]; then
    fail "scorer: reference file did not contain a commit SHA"
    return
  fi
  if [ ! -d "$SCORER/.git" ]; then
    fail "scorer: not a git checkout: $SCORER"
    return
  fi

  actual="$(repo_head "$SCORER")"
  if [ "$actual" = "$expected" ]; then
    if repo_dirty "$SCORER"; then
      fail "scorer is at expected commit but working tree is dirty"
    else
      pass "scorer pinned at $expected with clean working tree"
    fi
    return
  fi

  if repo_dirty "$SCORER"; then
    fail "scorer HEAD mismatch and working tree is dirty; refusing to change checkout"
    fail "expected $expected; got ${actual:-UNKNOWN}"
    return
  fi

  if ! /usr/bin/git -C "$SCORER" cat-file -e "${expected}^{commit}" 2>/dev/null; then
    fail "scorer checkout does not contain required commit $expected"
    return
  fi

  warn "scorer HEAD differs; safely detaching clean checkout at required Batch-009 commit"
  if /usr/bin/git -C "$SCORER" checkout --detach "$expected" >/dev/null 2>&1; then
    pass "scorer pinned at $expected with clean working tree"
  else
    fail "could not detach scorer at $expected"
  fi
}

printf '\nBatch-009 runtime guard\n'
printf 'Reference: %s\n\n' "$REF"

if [ ! -f "$REF" ]; then
  printf 'FAIL  reference state file not found: %s\n' "$REF" >&2
  exit 1
fi

# Do not mutate runtime state while a production call appears active.
if [ -f "$CONTROL/current" ]; then
  fail "production current-marker exists: $CONTROL/current"
  warn "not performing automatic scorer/AMC repairs while a production call may be active"
  ALLOW_REPAIR=0
else
  ALLOW_REPAIR=1
fi

for required in "$LME" "$SCORER" "$XLSX" "$SOURCE" "$SPECS" "$SNAPSHOT"; do
  die_if_missing "$required" >/dev/null || true
done

expected_lme="$(extract_repo_sha "$LME")"
expected_scorer="$(extract_repo_sha "$SCORER")"
expected_xlsx="$(extract_repo_sha "$XLSX")"
expected_source="$(extract_repo_sha "$SOURCE")"
expected_specs="$(extract_repo_sha "$SPECS")"
expected_amc="$(extract_amc_sha)"
expected_ollama="$(extract_ollama_server_version)"

if [ "$ALLOW_REPAIR" -eq 1 ]; then
  ensure_scorer_commit "$expected_scorer"
  restore_exact_amc_if_needed "$expected_amc"
else
  check_exact_repo "scorer" "$SCORER" "$expected_scorer"
  if [ -s "$XLSX/5e_Adventure_Master_Catalog_2.4.5.xlsx" ]; then
    actual_amc="$(sha256_file "$XLSX/5e_Adventure_Master_Catalog_2.4.5.xlsx")"
    if [ "$actual_amc" = "$expected_amc" ]; then
      pass "historical AMC 2.4.5 SHA-256 = $expected_amc"
    else
      fail "historical AMC 2.4.5 hash mismatch"
    fi
  else
    fail "historical AMC 2.4.5 is missing/empty"
  fi
fi

check_exact_repo "af-inference-orchestrator" "$LME" "$expected_lme"
check_exact_repo "af-xlsx-data-sources" "$XLSX" "$expected_xlsx"
check_exact_repo "md-for-llm-book-content" "$SOURCE" "$expected_source"
check_exact_repo "md-specification-files" "$SPECS" "$expected_specs"

if [ -f "$LME/config/workers.yml" ]; then
  pass "machine-local worker config exists: $LME/config/workers.yml"
else
  fail "missing machine-local worker config: $LME/config/workers.yml"
fi

# If a future state capture includes a worker-config SHA, enforce it.
expected_workers_sha="$(
  /usr/bin/awk '
    /^=== local worker config ===$/ { getline; print $1; exit }
  ' "$REF"
)"
if [ -n "$expected_workers_sha" ] && [ -f "$LME/config/workers.yml" ]; then
  actual_workers_sha="$(sha256_file "$LME/config/workers.yml")"
  if [ "$actual_workers_sha" = "$expected_workers_sha" ]; then
    pass "workers.yml SHA-256 matches captured reference"
  else
    fail "workers.yml SHA-256 mismatch: expected $expected_workers_sha, got $actual_workers_sha"
  fi
else
  warn "reference capture has no workers.yml SHA; existence + production verifier will be used"
fi

if ! command -v ollama >/dev/null 2>&1; then
  fail "ollama command not found"
else
  ollama_version_output="$(ollama --version 2>&1 || true)"
  actual_ollama="$(printf '%s\n' "$ollama_version_output" | /usr/bin/awk '/^ollama version is / {print $4; exit}')"

  if [ -n "$expected_ollama" ] && [ "$actual_ollama" = "$expected_ollama" ]; then
    pass "Ollama server version = $actual_ollama"
  elif [ -n "$expected_ollama" ]; then
    fail "Ollama server version mismatch: expected $expected_ollama, got ${actual_ollama:-UNKNOWN}"
  else
    warn "reference capture did not contain an Ollama server version"
  fi

  if printf '%s\n' "$ollama_version_output" | /usr/bin/grep -q '^Warning: client version is '; then
    warn "$(printf '%s\n' "$ollama_version_output" | /usr/bin/grep '^Warning: client version is ' | /usr/bin/head -1)"
  fi

  expected_model="$(
    ruby - "$SNAPSHOT" <<'RUBY' 2>/dev/null
require "yaml"
snapshot = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
print snapshot.fetch("ollama_model")
RUBY
  )"

  if [ -z "$expected_model" ]; then
    fail "could not resolve frozen Ollama model from Batch-009 snapshot"
  elif model_show="$(ollama show "$expected_model" 2>&1)"; then
    pass "Ollama model available: $expected_model"

    ref_arch="$(extract_model_field "architecture")"
    ref_ctx="$(extract_model_field "context length")"
    ref_quant="$(extract_model_field "quantization")"

    actual_arch="$(printf '%s\n' "$model_show" | /usr/bin/awk '$1=="architecture" {print $2; exit}')"
    actual_ctx="$(printf '%s\n' "$model_show" | /usr/bin/awk '$1=="context" && $2=="length" {print $3; exit}')"
    actual_quant="$(printf '%s\n' "$model_show" | /usr/bin/awk '$1=="quantization" {print $2; exit}')"

    [ -z "$ref_arch" ] || {
      if [ "$actual_arch" = "$ref_arch" ]; then
        pass "model architecture = $actual_arch"
      else
        fail "model architecture mismatch: expected $ref_arch, got ${actual_arch:-UNKNOWN}"
      fi
    }

    [ -z "$ref_ctx" ] || {
      if [ "$actual_ctx" = "$ref_ctx" ]; then
        pass "model context length = $actual_ctx"
      else
        fail "model context mismatch: expected $ref_ctx, got ${actual_ctx:-UNKNOWN}"
      fi
    }

    [ -z "$ref_quant" ] || {
      if [ "$actual_quant" = "$ref_quant" ]; then
        pass "model quantization = $actual_quant"
      else
        fail "model quantization mismatch: expected $ref_quant, got ${actual_quant:-UNKNOWN}"
      fi
    }
  else
    fail "required Ollama model unavailable: $expected_model"
    printf '%s\n' "$model_show" >&2
  fi
fi

if [ -f "$CONTROL/pause" ]; then
  fail "production pause file is present: $CONTROL/pause"
  warn "the runner will not dispatch until this pause state is intentionally cleared/resumed"
else
  pass "no production pause file present"
fi

printf '\nRunning Batch-009 zero-inference production verifier...\n'
if (
  cd "$LME" &&
  ./verify_production_backlog.sh "$QUEUE"
); then
  pass "verify_production_backlog.sh passed"
else
  fail "verify_production_backlog.sh failed"
fi

printf '\nRunning runtime source-resolution preflight (zero inference)...\n'
if (
  cd "$LME" &&
  bin/preflight-production-backlog-sources "$QUEUE"
); then
  pass "runtime source-resolution preflight passed"
else
  fail "runtime source-resolution preflight failed"
fi

printf '\n============================================================\n'
printf 'Batch-009 runtime guard: %d PASS, %d WARN, %d FAIL\n' "$PASS" "$WARN" "$FAIL"
printf '============================================================\n'

if [ "$FAIL" -ne 0 ]; then
  printf 'NOT READY — no inference was launched.\n' >&2
  exit 1
fi

printf 'READY — Batch 009 matches the captured local runtime and all zero-inference preflights passed.\n'
printf 'No inference was launched by this script.\n'
exit 0
