# Declarative adventure-ingest batches

`bin/build-production-backlog` generalizes the committed Batch 19 preparation
contract. It performs no inference and never changes the catalog, source Markdown,
or scorer. Historical preparers, verifiers, snapshots and manifests are retained.

## Build and verify

From the af-inference-orchestrator checkout, after freezing the exact target set:

```bash
bin/build-production-backlog \
  --batch 020 \
  --catalog 5e_Adventure_Master_Catalog_4.9.xlsx \
  --ids ADV-0465..ADV-0493

bin/verify-production-backlog production_backlog/production-backlog-020
```

**The example range is not a frozen B20 selection.** The supplied AMC 4.9 has
ADV-0466 through ADV-0493 but does not have ADV-0465. That exact example therefore
fails closed. Decide the actual IDs (or separately adjudicate the catalog) first;
the builder never silently drops a missing ID. Use `--ids ADV-0466..ADV-0493`
only if that 28-adventure set is the intended selection.

`--ids` accepts comma-separated exact IDs, inclusive ranges, and repeated options.
Catalog row order wins over selector order. Duplicate IDs, missing targets,
asymmetric Levels, populated ordinary/deferred scores, and adventures outside
the existing <100-page envelope fail. Eleven ordinary calls are generated per
adventure, followed by one paired Levels call only when both Levels cells are
blank. Populated Levels remain untouched.

The scorer defaults to `../af-cli-scoring-utility`; `AF_SCORER_REPO` can select
another checkout before freezing. Catalog location uses the scorer's existing
configuration. Ruby and the repository's existing gems are required; no new gem
dependencies are introduced.

## Explicit source-boundary policy

Optionally supply `--clamp-policy /path/to/approved-clamps.yml`:

```yaml
allow_inward_boundary_clamp_adventure_ids:
  - ADV-0447
  - ADV-0460
inward_boundary_clamp_max_gap_by_adventure:
  ADV-0447: 2
```

These are B19's approvals, shown as a format example, not approvals for a new
batch. All listed IDs must be targets. A max-gap exception requires an allowlisted
ID and a positive integer. An allowlisted ID without an override retains the
scorer's ordinary one-page default. Unknown policy keys fail. There is no global
max-gap option, source repair, boundary widening or full-source fallback.

All source units go through `af-score --preflight`; every failure is reported
with ID, title and diagnostics. No queue/manifests are written on preflight
failure. `--force` replaces only an unstarted queue after successful preflight;
any prior queue output blocks replacement, including partial output without
metadata. Do not build and run the same queue concurrently.

`--dry-run` performs the same catalog/source preflight without materializing a
queue or manifests. It does not start Ollama inference or check model availability.
Run the generic verifier on the materialized package to check worker readiness.

## Frozen contract and compatibility

Snapshots record ordered targets, selected metadata, catalog/scorer/LME commits
or hashes as appropriate, ordinary/Levels/total counts, preserved Levels IDs,
qualification/runtime hashes, clamp policy, and manifest order. Runtime/profile
semantics are shared between builder and verifier, based on B19's qualification
contracts. The runner uses the generic verifier for any `adventure_ingest_v1`
queue. Its 8192-token amendment remains restricted to the six established qwen35
core dimensions; Levels, GMBS, EE, GMPB and Seriousness keep their prior scope.

The verifier checks all execution-related manifest fields and rejects unexpected
execution keys. Historical descriptive prose is not compared. Every manifest
is planned through `bin/lme plan`; one representative per distinct model goes
through the existing `worker-check`. Scorer HEAD must equal the frozen commit,
and the historical protected paths must be clean. An environment override cannot
change a frozen scorer path. Historical absolute catalog paths remain authoritative.

B16/B17 snapshots omit conditional-Levels metadata and represent preserved
Levels only. B16–B18 omit max-gap overrides and retain the scorer default. These
older shapes are supported without rewriting files. LME's recorded generation
commit is provenance, not a requirement to run the old LME code after applying
this patch. Historical preparer/verifier duplication is intentionally retained.

After verifier PASS, inspect the Git diff, commit the batch manually, and launch
`run_production_backlog.sh` only when ready. The builder never launches it.

## Tests

```bash
ruby -Itest -e 'Dir["test/adventure_ingest*_test.rb"].sort.each { |f| require_relative f }'
bundle exec rake
bin/verify-production-backlog production_backlog/production-backlog-019
```

Tests use temporary synthetic catalogs and a preflight-only fake scorer. Runner
tests use a fake dispatcher; no model is called. Historical regression tests read
all committed B16–B19 snapshots/runtimes/indices/manifests unchanged. Actual AMC
and host checks are additional integration gates, never represented as mocked
host-readiness PASSes.
