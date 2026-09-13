# local-model-evaluation

Small orchestration and experiment-management layer for running controlled `af-cli-scoring-utility` evaluations across local and remote Ollama workers.

## Scope

This repository answers **what to test, where to run it, how to dispatch it, and what the experiment established**. Its primary role is to act as a lightweight control plane from the Mac: keep AdventureFinder scoring semantics and source access local, while sending model inference to one or more reachable Ollama workers.

That split is intentional. `af-cli-scoring-utility` remains authoritative for scoring behavior, prompts, AFAO interpretation, guardrails, and source resolution. A remote worker only needs Ollama plus the selected model; it does not need a copy of the AdventureFinder scorer or source corpus.

This makes the repo useful for parallelizing the waiting time around local-model evaluation without changing the scoring contract.

## v0.2 capabilities

- define Ollama workers as URLs plus environment variables;
- health-check workers and verify required models;
- define experiments declaratively in YAML;
- run either a worker-by-worker **matrix** or a shared **pool**;
- invoke the existing `bin/af-score` CLI while routing inference to the selected worker;
- kick off a detached experiment manager with `bin/lme start`;
- inspect progress with `bin/lme status` while continuing other work;
- preserve native scorer output plus stdout/stderr/metadata;
- resume interrupted experiments without rerunning successful jobs;
- retry only failed jobs when requested;
- consolidate operational results into `jobs.csv`, `results.csv`, and `summary.md`;
- estimate per-worker scoring-runtime cost when an hourly rate is configured.

## Non-goals for v0.2

No Terraform, Docker orchestration, distributed queues, databases, dashboards,
autoscaling, or remote scorer-repository synchronization.

In particular, v0.2 does **not** copy `af-cli-scoring-utility` to remote machines or execute the whole scorer remotely. The Mac remains the lightweight control plane and the expensive model inference happens on the worker. Whole-job remote execution should only be added if this simpler architecture proves insufficient.

The concrete first pilot remains `experiments/granite-platform-equivalence-v1.yml`. See `docs/SCORER_INTEGRATION_GATE.md` before starting paid compute. After platform equivalence is established, `experiments/templates/remote-parallel.yml` is the starting point for remote throughput runs.

## Requirements

- Ruby 3.1+
- an existing checkout of `af-cli-scoring-utility`
- one or more reachable Ollama-compatible endpoints
- the target model already installed on each worker used by the experiment

## Setup

```bash
bundle install
cp config/workers.example.yml config/workers.yml
$EDITOR config/workers.yml
```

Keep credentials and private endpoint URLs out of Git. `config/workers.yml` is ignored.

Environment variables in YAML may be written as `${NAME}` or `${NAME:-default}`.

## Worker configuration

```yaml
workers:
  mac:
    type: ollama
    base_url: http://127.0.0.1:11434
    hourly_rate_usd: 0.0
    labels: [local, apple-silicon]
    scorer_env:
      AF_LLM_PROVIDER: ollama
      AF_OLLAMA_BASE_URL: http://127.0.0.1:11434

  cloud_a:
    type: ollama
    base_url: ${LME_CLOUD_A_URL}
    hourly_rate_usd: 0.33
    labels: [remote, cloud, nvidia, a6000]
    scorer_env:
      AF_LLM_PROVIDER: ollama
      AF_OLLAMA_BASE_URL: ${LME_CLOUD_A_URL}
```

The harness intentionally treats scorer environment variables as configuration rather than hard-coding the scorer's remote-endpoint variable name. If the scorer uses a different endpoint variable, change `scorer_env` without changing this repository.

Use the `remote` label as a semantic guardrail when an experiment must only use remote workers:

```yaml
required_worker_labels: [remote]
```

## Dry-run the experiment plan

```bash
bin/lme plan experiments/my-experiment.yml
```

This expands the manifest without running inference and shows the job count, workers, rates, and configured pilot cap.

## Check workers

```bash
bin/lme worker-check
```

For a particular experiment/model:

```bash
bin/lme worker-check experiments/granite-platform-equivalence-v1.yml
```

The check calls Ollama's `/api/version` and `/api/tags` endpoints.

## Managed RunPod fleets and generic dispatch

Local execution remains the zero-cost default. When measured wall-clock needs
justify paid RunPod burst execution, `SECURE` is the default RunPod cloud tier
for AdventureFinder workloads. `COMMUNITY` remains available only as opt-in
experimental capacity; it is not a prerequisite for Secure qualification.
See `docs/RUNPOD_CLOUD_TIER_POLICY.md`.

Shared RunPod fleet commands support 1–16 workers. Explicit subsets remain available
with selectors such as `1-12`, `9-12`, or `1,6,12`; `--all` selects the active
workers recorded in the current fleet state.

RunPod pod storage remains backward-compatible at 30 GB for the container/root
disk and 60 GB for the persistent `/workspace` volume. Size either explicitly
when a worker must retain a larger multi-model Ollama store:

```bash
bin/lme runpod-create \
  --workers 16 \
  --cloud SECURE \
  --container-disk-gb 50 \
  --volume-gb 150 \
  --dry-run
```

The values above are illustrative rather than new defaults; size them from the
measured model-store requirement before paid creation. The current fleet-rate
estimate is derived from the GPU catalog rate and does not estimate storage
charges.

Long-lived fleets can add an explicit runtime and/or total-dollar lease without
weakening the existing per-fleet and aggregate hourly caps:

```bash
bin/lme runpod-create \
  --workers 16 \
  --cloud SECURE \
  --container-disk-gb 50 \
  --volume-gb 150 \
  --max-runtime-minutes 480 \
  --max-spend-usd 70 \
  --dry-run
```

On a paid create, a configured lease is persisted in fleet state and a detached
local watchdog starts automatically. The lease clock begins immediately before
the first paid pod-create request, so provisioning time is conservatively inside
the runtime/spend guard. Inspect it with:

```bash
bin/lme runpod-lease status
bin/lme runpod-status
```

This is an operator-side safety guard, not a provider-side billing limit. If the
control-plane Mac shuts down, sleeps indefinitely, or loses network connectivity,
the watchdog cannot delete pods until it is running and connected again. The
spend lease uses recorded GPU rates and intentionally does not claim to cap
storage, network, taxes, credits, provider billing granularity, or other charges.

The generic dispatcher accepts independent jobs as structured JSON:

```json
{
  "jobs": [
    {
      "job_id": "attempt-001",
      "argv": ["/path/to/workload", "--attempt", "1"],
      "affinity": "model:qwen3.6:35b-a3b",
      "env": { "WORKLOAD_SETTING": "value" }
    }
  ]
}
```

```bash
bin/lme runpod-dispatch \
  --jobs /path/to/jobs.json \
  --workers 1-4 \
  --output output/runpod-dispatch/example
```

FIFO remains the default. For mixed-model queues, jobs may declare an optional
`affinity` string and the dispatcher can stably group equal values before they
enter the shared worker queue:

```bash
bin/lme runpod-dispatch --jobs /path/to/jobs.json --workers 1-4 \
  --group-by-affinity --output output/runpod-dispatch/grouped
```

Affinity groups follow first appearance in the job file and preserve FIFO order
within each group. Untagged jobs form one group. Grouping is recorded in the
dispatch manifest and must match on resume; it is queue ordering, not a global
barrier between groups.

Each worker runs at most one job at a time. The dispatcher injects `LME_JOB_ID`,
`LME_WORKER_INDEX`, and `LME_OLLAMA_URL`, uses argv execution without a shell,
and writes a manifest, per-job stdout/stderr/metadata, and `summary.json`. A
workload failure does not stop other independent jobs. A fleet or tunnel failure
stops new assignments and leaves already-completed evidence intact.
Environment values are not persisted; pass secrets through `env`, never `argv`.

## Define an experiment

See `experiments/templates/model-viability.yml` for the general manifest shape and `experiments/templates/remote-parallel.yml` for a remote throughput campaign.

The two dispatch modes are:

- `matrix`: every configured worker runs every model/adventure/replicate combination. Use this for platform-equivalence tests.
- `pool`: each model/adventure/replicate combination runs once and is assigned to the next available compatible worker. Use this for remote parallelism. Each eligible worker processes one scorer job at a time, so adding workers increases concurrency without multiplying the logical benchmark.

## Kick off remote work and keep working

The intended management-layer flow is:

```bash
bin/lme worker-check experiments/my-experiment.yml
bin/lme plan experiments/my-experiment.yml
bin/lme start experiments/my-experiment.yml
bin/lme status experiments/my-experiment.yml
```

`start` launches the normal `run` command as a detached local manager. The manager writes to:

```text
output/<experiment>/manager.log
output/<experiment>/manager.pid
```

Your terminal is returned immediately, so you can continue human review or other AdventureFinder work while remote workers process jobs. Check progress at any time with `status`, or inspect the manager log directly:

```bash
tail -f output/<experiment>/manager.log
```

The manager is still running on the Mac. If the Mac sleeps, shuts down, or loses network connectivity, active remote Ollama calls can be interrupted. Resume behavior prevents completed jobs from being repeated when the experiment is started again.

## Foreground run

For debugging or small experiments, run synchronously:

```bash
bin/lme run experiments/my-experiment.yml
```

By default, completed jobs are never rerun.

```bash
bin/lme run experiments/my-experiment.yml --rerun-failed
bin/lme run experiments/my-experiment.yml --force
```

The same retry flags are accepted by `bin/lme start`.

## Report

A report is written automatically after a run. It can also be regenerated:

```bash
bin/lme report output/my-experiment
```

Output layout:

```text
output/<experiment>/
├── experiment.yml
├── environment.json
├── jobs.csv
├── results.csv
├── summary.md
├── manager.log       # detached-manager stdout/stderr, when started with `start`
├── manager.pid       # manager pid; may remain after completion as a stale pid record
└── runs/
    └── <job-id>/
        ├── metadata.json
        ├── stdout.log
        ├── stderr.log
        └── native/        # untouched af-score output
```

`results.csv` performs only lightweight extraction of common `score` and `confidence` fields from scorer JSON output. The native files remain authoritative.

## Cost discipline

The harness does not provision paid compute. A worker's `hourly_rate_usd` produces a **scoring-runtime estimate**, not a provider invoice. If `cost_cap_usd` is set, v0.2 stops dispatching new jobs once completed-job estimated runtime reaches that cap. This is deliberately a **soft cap**: already-running jobs can finish, and provider boot, idle, storage, and network charges are outside the estimate.

Before adding cloud-provider automation, the repo should first establish:

1. remote Ollama produces legitimate comparable scoring evidence;
2. parallel execution materially improves throughput;
3. repeated manual worker setup is burdensome enough to justify another automation layer.

## Tests

```bash
rake
```

```bash
env -u AF_NOS_TWO_STAGE_PROFILE \
  ./run_production_backlog.sh \
  production_backlog/production-backlog-<number>
```

```bash
./pause_production_backlog.sh
```
