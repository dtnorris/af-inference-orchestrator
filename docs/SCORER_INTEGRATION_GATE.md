# Scorer Integration Gate

`af-inference-orchestrator` is ready to target any already-running Ollama endpoint, but the current checked-out `af-cli-scoring-utility` must expose a configurable remote Ollama base URL.

## Before spending cloud money

On the Mac checkout of `af-cli-scoring-utility`, verify the current Ollama provider contract:

```bash
git status --short
git branch --show-current
grep -R "11434\|OLLAMA.*URL\|BASE_URL\|ollama" -n lib config README.md .env.example 2>/dev/null
```

The desired property is simple: the provider URL must be selectable without changing scorer code between workers.

For example, if the scorer supports:

```bash
AF_LLM_PROVIDER=ollama \
AF_OLLAMA_BASE_URL=http://127.0.0.1:11434 \
bin/af-score --model granite4:32b-a9b-h --dimension "Rules / System-Mastery Demand" --regression ADV-0034
```

then `config/workers.yml` can use `AF_OLLAMA_BASE_URL` directly.

If the current scorer uses a different variable, put that exact key in each worker's `scorer_env` map. No harness change is needed.

If the current scorer hard-codes `http://127.0.0.1:11434`, the smallest justified scorer change is to make that URL configurable. Do **not** add provider provisioning, worker scheduling, or cloud concepts to the scorer.

## Cloud pilot gate

Do not launch multiple paid workers yet. The first paid test should be one remote worker and the committed `experiments/granite-platform-equivalence-v1.yml` manifest.

Predeclared pilot sequence:

1. Start one suitable 48 GB worker.
2. Install/start Ollama and pull exactly `granite4:32b-a9b-h`.
3. Confirm `/api/version` and `/api/tags` are reachable from the Mac.
4. Run `bin/lme worker-check experiments/granite-platform-equivalence-v1.yml`.
5. Run `bin/lme plan experiments/granite-platform-equivalence-v1.yml`.
6. Only then run the experiment.
7. Stop if the soft `$1.00` scoring-runtime cap is reached or platform behavior looks systematically different.

Cloud provider billing, idle time, storage, and network charges remain outside the harness's scoring-runtime estimate, so the provider-side instance should also have an independent spending/termination discipline.
