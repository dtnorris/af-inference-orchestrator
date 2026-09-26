# Test Suite Contract

## Whole-suite runtime baseline

Measured on 2026-09-25 from commit
`d5709172f0f42ca57cdd4fa03c90db4908c7bebb`.

Environment:
- MacBook Pro M4 Pro, 48 GB
- Ruby 4.0.6
- 1 warm-up run discarded
- 7 measured runs
- 184 tests
- 1,843 assertions
- 0 skips

Runtime:
- min: 5.319 s
- median: 5.400 s
- mean: 5.437 s
- max: 5.661 s
- stddev: 0.109 s

## Whole-suite runtime guard

The canonical coverage-instrumented functional suite is protected by absolute
wall-clock ceilings measured with a monotonic clock.

Thresholds:
- warning: 6.0 s
- hard ceiling: 6.5 s

The warning threshold is about 11% above the measured 5.400 s uninstrumented
median. The hard ceiling is about 20% above that median. Because the default
safety sweep now measures the coverage-instrumented run, validate these existing
thresholds on the same local hardware after applying this change.

When a parallel AdventureFinder workspace test marks the process with
`AF_TEST_CONTENDED=1`, the runtime guard automatically applies the fixed
`TEST_RUNTIME_CONTENTION_MULTIPLIER` of 1.25. That makes the contended thresholds
7.5 s warning / 8.125 s hard failure. Direct `rake` and serial workspace runs
retain the calibrated 6.0 s / 6.5 s limits. The multiplier accounts for deliberate
cross-repository resource contention; it does not redefine the isolated baseline.

`bundle exec rake test:coverage` runs the full functional suite once with
SimpleCov enabled. That single run simultaneously enforces functional
correctness, the line/branch coverage ratchet, and the runtime ceiling.

## Default safety sweep

Plain `rake` runs the complete `test:contract` safety sweep in two stages.

1. `test:coverage` runs by itself first. It is the canonical functional test
   execution and enforces correctness, coverage, and runtime without competing
   with other health checks.
2. After it passes, `test:health` runs test-file independence and structural
   Minitest lint checks in parallel.

The default sweep preserves live Minitest progress output but removes the
otherwise-empty line between the `Finished in ...` line and the run/assertion
summary.

Successful secondary checks are quiet. In an interactive terminal, a single
in-place spinner shows that the parallel health phase is still running;
redirected output prints one plain progress line instead. The final health
summary is:

```text
test:lint: <N> files inspected, no offenses detected
test:deps: no broken dependencies found
```

If the runtime warning threshold is reached, the warning is deferred until
after the health summary and printed as the final status with a blank line
above it. If the hard runtime ceiling is reached, the health checks still
complete, then the failure is printed in the same final position and the
overall task exits nonzero.

If either secondary check fails, its captured diagnostic output is printed
before the safety sweep fails. The raw `rake test:lint` and `rake test:deps`
tasks remain available when detailed successful output is desired.

`rake test` remains available when only the fast uninstrumented product suite
is desired.
