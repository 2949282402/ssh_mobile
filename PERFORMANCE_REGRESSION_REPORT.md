> Last updated: 2026-08-22

# Network V2 Performance Regression Report

Status: **PASS for local deterministic regression smoke; not a production
benchmark**

This is the canonical performance report for the Network V2 final-fix
workstream. `PR48`/`PR49` are internal labels only. Validation used branch
`agent/network-v2-final-20260819` at base commit
`b61347cbbb062a079ef1e6daa7f82c50123a799f` plus the uncommitted working-tree
fixes.

The repository does not contain a stable production benchmark harness or a
cross-device throughput baseline. The checks below are regression-smoke
evidence, not claims about production hardware latency.

## Local measurements and gates

| Area | Check | Result |
| --- | --- | --- |
| Connection/runtime | `cargo test -p network-core --locked --lib` and the strict connectivity selector | PASS; full library and 24 connectivity tests completed |
| Stage ordering | `stage_b_resolves_and_offers_before_relay_reservation` | PASS; one Resolve, one Offer, then reservation |
| Relay client | `cargo test -p network-relay --locked` plus concrete WebSocket integration | PASS; 37 unit/golden and 1 integration test |
| Linux mirror | `bash scripts/full_test.sh --no-bootstrap --no-coverage --serial` | PASS; 12 runnable jobs, 731s |
| Front/backend/SDK coverage | `front_coverage.sh`, `backend_coverage.sh`, `sdk_coverage.sh` | PASS; 95.78% front lines, 82.1% filtered Go lines, 84.46% Dart and 84.32% Rust SDK lines |

## Required performance dimensions

- Connection: Stage A/B predicates and Stage B ordering pass. Stage C remains
  predicate-only; no production connect-latency percentile is asserted because
  no multi-device benchmark fixture or external endpoint is available.
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

No local performance regression or unbounded-queue signal was observed after
the Network V2 fixes. The performance gate is **PASS for repository smoke
coverage only**. Real-device latency, sustained Relay throughput, CPU, RSS,
and cross-instance load remain release-environment evidence and are not
silently treated as measured here.
