> Last updated: 2026-08-23

# Network V2 Performance Regression Report

Status: **PASS for local deterministic regression smoke; production benchmark
DEFERRED — NON-BLOCKING**

This is the canonical performance report for the PR48 local closure. Validation
used branch `agent/network-v2-final-20260819` at the frozen baseline and local
test head below; no production benchmark or remote CI result is inferred.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

The repository does not contain a stable production benchmark harness or a
cross-device throughput baseline. The checks below are regression-smoke
evidence, not claims about production hardware latency.

## Local measurements and gates

| Area | Check | Result |
| --- | --- | --- |
| Connection/runtime | `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked` | PASS; 61 focused tests, including cancellation/timeout reconnect isolation |
| Stage ordering | Independent Stage C evidence in `src/tests/connectivity_attempt.rs` | PASS; `Resolve=1`, `Offer=1`, `Reserve=1`, with Direct failure before Reserve |
| Relay client/data | `cargo test -p network-relay --locked` plus concrete integration | PASS; 45 unit/golden and 7 integration tests |
| Linux owner/workspace smoke | strict selectors plus `cargo test --workspace --locked` | PASS; workspace tests completed with no product failures |
| SDK/transport/FFI smoke | Flutter/Dart analyze/test and native Rust FFI checks | PASS; all runnable local selectors passed |
| Full aggregate coverage | `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial` | ENVIRONMENT GAP; App Flutter shard remained at `loading` without a VM Service in WSL and was stopped |

## Required performance dimensions

- Connection: Stage A/B predicates, lifecycle cleanup, and the test-only Stage C
  order/count evidence pass. No production connect-latency percentile is
  asserted because no multi-device benchmark fixture or external endpoint is
  available.
- Relay: control/data queues, nonce/revocation caps, transfer-session caps, and
  bounded event lanes are covered by code-level limits and owner tests. A
  sustained throughput and RSS benchmark still requires Redis/MySQL plus
  multiple Relay clients.
- Transfer: bounded payload, resume-across-fresh-session, progress
  backpressure, and cancellation tests pass. No artificial file-throughput
  number is recorded for deterministic local transports.
- Runtime: command/event queues have explicit item/byte limits, terminal FFI
  history is bounded, and lifecycle tests cover stop/dispose. Idle RSS and task
  count require a release build and platform profiler.

## Gate result

No regression signal or unbounded-queue signal was observed in the deterministic
repository smoke after the Network V2 changes. The performance gate is **PASS
for repository smoke coverage only**. Production benchmarking is
`DEFERRED — NON-BLOCKING`: real-device latency, sustained Relay throughput, CPU,
RSS, and cross-instance load remain release-environment evidence and are not
silently treated as measured here.
