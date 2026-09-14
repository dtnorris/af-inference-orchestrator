# AdventureFinder interruptible production backlog

This facility keeps otherwise-idle local Qwen compute doing useful production
scoring without competing with qualification work.

It deliberately starts with a small, falsifiable pilot:

- 3 packs
- 10 previously-uncovered adventures per pack
- 6 locally-qualified dimensions per adventure
- 60 calls per pack / 180 calls total when all selected rows are blank
- canonical source bodies no longer than 60 AMC pages
- local `qwen3.6:35b-a3b`
- external/API inference cost: **$0**

Every inference also requires scorer-side request provenance. Before model
inference, the scorer archives the exact provider-native request (full system
instructions, source/user prompt, structured-output schema, model parameters,
and hashes) next to the separately preserved raw provider response/reasoning.
The backlog verifier runs the scorer provenance tests and fails closed if that
capability is absent.

The qualified dimensions are frozen in `production_backlog/qualified_dimensions.yml`.
`# of Sessions` is intentionally not included here until its local qualification
has been adjudicated and recorded.

## Why generated queues are frozen

`bin/prepare-production-backlog` reads the adjacent scorer's **live configured
AMC**, rejects adventures already represented in checked-in production indexes
or local LME output, verifies source availability with scorer `--preflight`
(**zero inference**), then writes:

- a selection snapshot including the AMC SHA-256 and scorer commit;
- a candidate audit;
- one frozen case index;
- three pack indexes/run orders;
- one one-adventure × one-dimension × one-replicate manifest per RUN cell.

The runner never re-selects adventures. A queue therefore cannot silently
change under your feet if the AMC changes later.

## Prepare the first 30-adventure pilot

Do this when the current inference workload is idle (or after gracefully
pausing it):

```sh
bin/prepare-production-backlog \
  --queue production-backlog-pilot-v1
```

The defaults come from `production_backlog/selection_policy.yml`.

By default the generator uses the adjacent checkout:

```text
../af-cli-scoring-utility
```

For an isolated copy/worktree, override it explicitly:

```sh
AF_SCORER_REPO="$HOME/code/af-cli-scoring-utility2" \
  bin/prepare-production-backlog \
  --queue production-backlog-pilot-v1
```

The scorer checkout is frozen into `snapshot.yml` as a path relative to the
`af-inference-orchestrator` checkout (for sibling copies, for example
`../af-cli-scoring-utility2`). Generated manifests point at that same checkout.
Verify/run/resume resolve the frozen path, so they cannot silently fall back to
the primary scorer repository.

The generator uses that scorer's configured AMC and performs source preflights
only; it does **not** contact Ollama for inference.

## Verify before inference

```sh
./verify_production_backlog.sh production_backlog/production-backlog-pilot-v1
```

The verifier checks the frozen matrix, every manifest, the Qwen alias, local
worker availability, and the exact qualified Social v0.3 / Investigation v0.4
prompt activation. It also fails closed if those qualified scorer
implementations have changed from the accepted lineage.

It ends with:

```text
NO INFERENCE WAS RUN.
```

## Run

```sh
./run_production_backlog.sh production_backlog/production-backlog-pilot-v1
```

The runner:

- starts `caffeinate -dimsu`;
- works adventure-major so complete adventure coverage accrues early;
- skips already-complete or already-failed manifests on resume;
- never reruns an unfavorable completed sample;
- stops cleanly when a pause sentinel is observed between calls;
- stops automatically after 2 consecutive new failures or 3 total new
  failures in one invocation.

At the recent observed throughput (~128 calls in ~5h52m), a 60-call pack is
roughly 2h45m and all 180 calls roughly 8h15m. Those are planning estimates,
not gates.

## Graceful pause for qualification work

From another terminal:

```sh
./pause_production_backlog.sh
```

This **does not kill the current inference**. It creates a sentinel. The active
call finishes and persists normally, then the queue exits before dispatching
the next call.

Check where it is:

```sh
./status_production_backlog.sh production_backlog/production-backlog-pilot-v1
```

Resume later:

```sh
./resume_production_backlog.sh production_backlog/production-backlog-pilot-v1
```

This removes the pause sentinel and invokes the same resumable runner.

For an emergency immediate interruption, Ctrl-C is still available, but that
may abandon the current sample. Prefer the pause sentinel whenever waiting for
the current call is acceptable.

## Generating later queues

After this pilot is reviewed, generate another queue with a new name. Existing
checked-in case indexes and local output metadata are automatically treated as
reserved so the generator preferentially moves to untouched adventures.

Example:

```sh
bin/prepare-production-backlog \
  --queue production-backlog-002 \
  --packs 5 \
  --adventures-per-pack 10 \
  --max-pages 60
```

Do not use a larger queue merely because local compute is available. Expand
only after the pilot demonstrates clean pause/resume behavior, acceptable
operational failure rate, and useful production outputs.
