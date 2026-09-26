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

`bundle exec rake test:runtime` measures the wall-clock duration of a fresh
`bundle exec rake test` subprocess using a monotonic clock.

Thresholds:
- warning: 6.0 s
- hard ceiling: 6.5 s

The warning threshold is about 11% above the measured 5.400 s median. The hard
ceiling is about 20% above the median and fails the runtime guard when reached.

`bundle exec rake test:contract` uses `test:runtime` as its ordinary-suite gate,
so the runtime ceiling is enforced whenever the complete test-suite contract is
run.
