# AFIO ↔ RPOF Production Burst Budget Contract v0.1

Status: **FROZEN — A0 contract freeze**

This document freezes the cross-repository contract required before implementing
AdventureFinder production-burst cumulative cost enforcement.

It intentionally defines **interface and safety semantics only**. It does not
implement a budget engine, guardian, paid-provider mutation, or new shutdown
behavior.

Expected repository baselines for this freeze:

- AFIO: `3ba08d1bf73ff8c5437bce5e8cdbae88d4e0c417`
- RPOF: `7bd4fe420a27f584f3e1dd3471b0a449e71aaf5a`

Normative terms **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used in their
usual requirements sense.

## 1. Ownership boundary

AFIO owns production intent. For a paid production burst it MUST freeze:

- one opaque `budget_id`;
- the cumulative compute-dollar ceiling;
- the maximum runtime;
- the guardian polling cadence;
- the AFIO/orchestrator heartbeat timeout; and
- the teardown reserve duration.

RPOF owns enforcement. RPOF MUST own:

- the authoritative budget ledger;
- locking and atomic mutation of that ledger;
- accrued-cost accounting;
- committed-liability accounting;
- mutation reservation and authorization;
- guardian-health evidence;
- heartbeat receipt/persistence;
- budget-triggered teardown;
- provider deletion; and
- verification that paid provider resources are absent before the budget closes.

AFIO MUST NOT independently reimplement RPOF liability accounting or provider
teardown.

## 2. Frozen AFIO plan declaration

A paid AFIO production execution-pool plan MUST carry this budget object:

```json
{
  "budget": {
    "contract_version": "afio-production-burst-budget/v0.1",
    "budget_id": "<opaque immutable id>",
    "max_cumulative_compute_usd": 5.0,
    "max_runtime_seconds": 2700,
    "guardian_poll_seconds": 5,
    "orchestrator_heartbeat_timeout_seconds": 30,
    "teardown_reserve_seconds": 60
  }
}
```

The existing plan field:

```text
capacity.max_total_hourly_usd
```

remains the authoritative aggregate hourly-rate ceiling. The budget object MUST
NOT duplicate that value.

All numeric budget limits MUST be finite and strictly positive.

`orchestrator_heartbeat_timeout_seconds` MUST be at least
`2 * guardian_poll_seconds`.

`budget_id` is an opaque identifier generated before the final plan is
serialized. It MUST NOT be derived from the final plan SHA, because doing so
would create a self-referential identity.

After the plan is serialized, the immutable budget identity is the tuple:

```text
(budget_id, plan_sha256)
```

A resume, retry, pool fulfillment, worker expansion, replacement, or guardian
restart MUST preserve that exact tuple.

No resume or retry MAY reset, widen, replace, or mint a new budget for work
belonging to the same frozen production plan.

## 3. Cumulative-budget scope

`max_cumulative_compute_usd` applies to the entire production burst, not to an
individual pool or fleet.

The same budget covers all provider compute created or retained for the frozen
plan, including:

- every model pool;
- partial fulfillment;
- retries;
- resumed execution;
- worker replacement;
- adaptive worker expansion; and
- workers that are prepared but not yet admitted to dispatch.

Pool-local and fleet-local safety controls remain subordinate constraints. They
MAY make execution cheaper or stop it earlier, but they MUST NOT increase the
parent burst budget.

This contract governs tracked RunPod **compute** cost. Storage, network, taxes,
credits, and other provider billing adjustments are outside
`max_cumulative_compute_usd` unless a later contract explicitly adds them.

## 4. Committed maximum liability

The budget engine MUST gate paid mutations on **committed maximum liability**,
not merely spend already accrued.

At any decision point, define:

```text
committed_rate_usd_per_hour =
    active_owned_resource_rate
  + pending_reserved_resource_rate

enforcement_horizon_seconds =
    guardian_poll_seconds
  + orchestrator_heartbeat_timeout_seconds
  + teardown_reserve_seconds

enforcement_reserve_usd =
    committed_rate_usd_per_hour
  * enforcement_horizon_seconds
  / 3600

committed_maximum_liability_usd =
    accrued_compute_usd
  + enforcement_reserve_usd
```

A proposed positive paid mutation MUST be rejected unless the post-mutation
`committed_maximum_liability_usd` is less than or equal to
`max_cumulative_compute_usd`.

The guardian MUST begin budget teardown before continued accrual would consume
the enforcement reserve.

For a mutation whose actual provider rate is not yet known, the reservation MUST
use the highest rate that the existing lower-level cost policy would permit for
that mutation, not an optimistic quoted rate. After the provider rate is known
and verified to be within that lower-level cap, RPOF MAY reduce the committed
rate to the recorded actual rate.

This definition deliberately reserves enough budget to cover bounded guardian
detection plus teardown after an orchestrator failure.

## 5. Authoritative RPOF budget state

RPOF MUST persist one authoritative ledger per immutable budget identity.

The implementation MAY choose its file layout, but the logical state MUST contain
at least:

```text
contract_version = rpof-production-burst-budget-state/v0.1
budget_id
plan_sha256
state
armed_at_utc
deadline_at_utc
last_orchestrator_heartbeat_at_utc
last_guardian_heartbeat_at_utc
limits
accrued_compute_usd
committed_rate_usd_per_hour
committed_maximum_liability_usd
reservations
owned_resources
teardown_reason
closed_at_utc
```

Only RPOF MAY mutate this authoritative ledger. AFIO communicates heartbeat and
budget operations through the RPOF boundary; AFIO MUST NOT directly edit RPOF
budget state.

All read-modify-write budget operations that can affect authorization or
liability MUST be serialized under an exclusive lock and persisted atomically.

## 6. Frozen budget state machine

The externally meaningful budget states are:

```text
ARMED
  |
  | runtime expiry
  | cumulative-budget threshold
  | stale orchestrator heartbeat
  | guardian reconciliation requiring teardown
  v
TEARDOWN_REQUIRED
  |
  | all owned paid resources verified absent
  v
CLOSED
```

### ARMED

`ARMED` is the only state in which a positive paid mutation MAY be authorized.

### TEARDOWN_REQUIRED

No positive paid mutation MAY be authorized.

Cost-reducing or destructive operations, including scale-down and destroy, MUST
remain permitted.

The guardian MUST continue reconciliation and verified teardown until every
budget-owned paid resource is absent or an explicit operator-visible teardown
failure remains.

### CLOSED

`CLOSED` is terminal.

A closed budget MUST NOT be reopened, reset, or reused for new paid work.

Budget exhaustion, runtime expiry, and stale heartbeat are teardown **reasons**,
not separate states.

## 7. Frozen logical operations

Implementation class names and CLI spellings are intentionally NOT frozen by A0.
The following logical operations and their semantics ARE frozen.

### arm

Inputs include the complete frozen limits plus `(budget_id, plan_sha256)`.

`arm` MUST:

1. persist the immutable limits;
2. establish `armed_at_utc`;
3. establish one absolute `deadline_at_utc`;
4. start or verify the independent guardian; and
5. return success only when guardian health is fresh.

If the identity already exists, `arm` MAY resume it only when all immutable
fields match exactly.

A mismatch MUST fail closed.

### heartbeat

Records a heartbeat for the same immutable identity.

A heartbeat MUST NOT extend `deadline_at_utc`, reset accrued cost, increase a
limit, or change the budget identity.

### status

Read-only.

It MUST expose enough information to report at least:

- state;
- accrued compute;
- committed rate;
- committed maximum liability;
- remaining uncommitted budget;
- absolute deadline;
- age of the latest orchestrator heartbeat;
- age of the latest guardian heartbeat;
- owned resources; and
- teardown reason, if any.

### reserve_mutation

This is the atomic pre-provider authorization step for a positive paid mutation.

The reservation MUST be persisted before the provider mutation occurs.

It MUST identify at least:

- a unique reservation id;
- operation type;
- intended fleet key;
- intended logical worker/resource identity;
- maximum reserved hourly-rate delta; and
- creation time.

The mutation is authorized only if:

1. the budget is `ARMED`;
2. guardian health is fresh;
3. the orchestrator heartbeat is not stale;
4. the absolute deadline has not passed;
5. all existing lower-level cost gates pass; and
6. post-reservation committed maximum liability remains within the cumulative
   budget.

Guardian health is fresh when:

```text
guardian_heartbeat_age <= 2 * guardian_poll_seconds
```

### commit_mutation

Binds a persisted reservation to the provider resource actually created.

It MUST record provider identity, actual verified hourly rate, and provider
lifecycle start time.

The actual rate MUST NOT exceed the rate authorized by the reservation or any
existing lower-level rate ceiling.

### release_reservation

A reservation MAY be released only when RPOF has established that the provider
mutation did not create a paid resource, or that any created resource has been
verified absent.

A process crash after provider creation but before `commit_mutation` MUST NOT
cause the reservation to disappear. The guardian MUST reconcile that reservation
against provider and RPOF fleet state.

If RPOF cannot prove absence, the budget MUST enter or remain
`TEARDOWN_REQUIRED`.

### begin_teardown

Transitions an `ARMED` budget to `TEARDOWN_REQUIRED` with a durable reason.

This operation is idempotent.

### close

`close` is permitted only after all budget-owned paid resources are verified
absent.

It MUST persist `CLOSED` and `closed_at_utc`.

## 8. Guardian-before-mutation invariant

The first paid provider mutation MUST NOT occur until:

1. the budget is durably armed;
2. the guardian is running independently of the AFIO production-burst process;
3. guardian health is fresh; and
4. the exact mutation has a durable reservation.

The same invariant applies to every later positive mutation.

The guardian MUST survive failure of the initiating AFIO/orchestration process.

The guardian is responsible for enforcing:

- the absolute budget deadline;
- the cumulative liability threshold;
- stale orchestrator heartbeat;
- reconciliation of pending reservations; and
- verified teardown.

A guardian that cannot establish its own authoritative state MUST fail closed and
MUST NOT authorize new paid mutations.

## 9. Mutations covered by the parent budget

At minimum, these RPOF paths are positive paid mutations and therefore require a
valid budget reservation when invoked by automated production execution:

- initial provider worker creation;
- scale-up;
- replacement worker creation;
- execution-pool fulfillment that adds a worker; and
- adaptive production worker preparation/expansion that adds a worker.

A cost-reducing mutation MUST remain available even after the budget stops
authorizing positive mutations.

`keep` or equivalent lifecycle cancellation MUST NOT reset or widen the budget,
deadline, heartbeat timeout, or cumulative ceiling.

Bootstrap, tunnel setup, capability checks, runtime aliases, and dispatch do not
create additional provider workers, but their elapsed paid compute remains part
of accrued budget cost while owned workers are alive.

## 10. Existing safeguards remain in force

The parent cumulative budget is an additional gate, not a replacement for
existing protections.

The implementation MUST preserve:

- qualified-GPU restrictions;
- per-worker price ceilings;
- per-pool hourly ceilings;
- aggregate hourly ceiling;
- existing fleet runtime/spend leases where configured;
- RPOF runtime cost-control drain behavior;
- AFIO adaptive-expansion economic policy;
- terminal inactivity shutdown; and
- verified provider deletion.

A new budget mechanism MAY tighten these controls. It MUST NOT silently loosen,
disable, reset, or bypass them.

## 11. Resume and adaptive expansion

Adaptive expansion MUST inherit the exact parent `(budget_id, plan_sha256)`.

Expansion MUST NOT create a child budget or a fresh allowance.

On resume:

- accrued cost remains accrued;
- the original `armed_at_utc` remains authoritative;
- the original absolute deadline remains authoritative;
- pending reservations remain durable until reconciled;
- owned resources remain associated with the same budget; and
- closed budgets remain closed.

## 12. Crash-safety acceptance criterion

The implementation is not complete until a deterministic test can demonstrate:

1. arm one parent burst budget;
2. create or simulate multiple independent pool mutations;
3. persist a further positive reservation;
4. simulate provider creation;
5. kill the AFIO production-burst process immediately afterward;
6. leave the guardian alive;
7. observe stale AFIO heartbeat;
8. prevent every subsequent positive paid mutation;
9. reconcile the pending reservation;
10. tear down every budget-owned provider resource;
11. verify provider absence;
12. close the budget; and
13. show that the calculated committed maximum liability never exceeded the
    frozen cumulative budget.

Additional required concurrency evidence:

- two simultaneous pools cannot both spend the same remaining budget;
- guardian restart does not reset the budget;
- AFIO resume does not reset the budget;
- adaptive expansion uses the original budget; and
- an unverified provider deletion leaves the budget in `TEARDOWN_REQUIRED`.

## 13. Explicit guarantee boundary

This contract is designed to make the maximum additional compute loss finite
when the initiating AFIO/orchestration process fails.

It does not claim a provider-side billing guarantee when the machine hosting the
independent RPOF guardian itself is powered off, indefinitely disconnected, or
otherwise unable to contact RunPod.

Future work MAY add a provider-side financial boundary, but it MUST be additive;
it MUST NOT weaken this contract.

## 14. Parallel implementation lanes after A0

With this document frozen:

### Patch A — AFIO contract/plumbing

Patch A owns:

- adding the frozen budget object to the production plan;
- validating its fields;
- propagating `(budget_id, plan_sha256)` and frozen limits through AFIO→RPOF
  handoffs;
- resume identity checks; and
- AFIO heartbeat plumbing.

Patch A MUST NOT implement provider accounting or teardown.

### Patch B — RPOF cumulative-budget engine

Patch B owns:

- the authoritative ledger representation;
- file locking and atomic persistence;
- accrued-cost accounting;
- committed-liability calculation;
- reservation/commit/release semantics;
- mutation authorization; and
- integration into provider-positive mutation paths.

Patch B is authoritative for the on-disk budget state schema and liability math.

### Patch C — independent guardian and inheritance

Patch C owns:

- the independent guardian loop/supervision;
- guardian health evidence;
- heartbeat expiry handling;
- runtime/cumulative-budget teardown triggers;
- reconciliation after AFIO failure;
- adaptive-expansion inheritance integration; and
- crash/restart acceptance tests.

Patch C MUST consume Patch B's ledger and operations. It MUST NOT invent a second
budget state format, second liability formula, or alternate reservation model.

### Collision rule

If Patch B and Patch C are developed concurrently, Patch C SHOULD use a fake or
stubbed Patch-B service interface until Patch B lands.

Patch C MUST NOT independently edit the authoritative accounting semantics owned
by Patch B.

Any future change to sections 1–13 is a contract revision and MUST increment the
contract version rather than silently changing v0.1.
