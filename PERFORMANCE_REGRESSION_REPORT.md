> Last updated: 2026-08-21

# PR49 Performance Regression Report

Status: **PASS for local deterministic regression smoke**

The repository does not contain a stable production benchmark harness or a
previous numerical baseline for cross-device throughput. The checks below are
therefore regression smoke evidence, not claims about production hardware
latency.

## Local measurements

Measured in WSL on the PR49 worktree, with existing owner tests and no external
service endpoint:

| Area | Check | Wall time | Result |
| --- | --- | ---: | --- |
| Connection/runtime | `cargo test -p network-core --locked --lib` | 11.42 s | PASS; full library suite completed without timeout or retry growth |
| FFI/runtime boundary | `cargo test -p network-ffi --locked` | 1.59 s | PASS; ABI/lifecycle and bounded command tests completed |
| Relay | `go test ./... -count=1 -timeout=240s` | 29.07 s | PASS; full Go package suite completed |
| SDK | `flutter test --no-pub` in `network_sdk` | 2.70 s | PASS; all SDK contract/realtime tests completed |

## Required performance dimensions

- Connection: Stage A/B/C and fresh-session tests pass; the Stage B integration
  test records the controlled Resolve → Offer → Reservation flow. A production
  connect-latency percentile is not asserted because no network benchmark
  fixture or multi-device endpoint is available.
- Relay: control/data queues, nonce/revocation caps, transfer-session caps, and
  bounded event lanes are covered by code-level limits and owner tests. A
  sustained throughput and RSS benchmark requires Redis/MySQL plus multiple
  Relay clients and is deferred to deployment validation.
- Transfer: large bounded payload, resume-across-fresh-session, progress
  backpressure, and cancellation tests pass. No artificial file-throughput
  number is recorded because the test transport is deterministic and local.
- Runtime: command/event queues have explicit item/byte limits, terminal FFI
  history is bounded, and lifecycle tests cover stop/dispose. Idle RSS and task
  count require a running release build and platform profiler.

## Gate result

No local performance regression or unbounded-queue signal was observed after
the Network V2 fixes and SDK domain migration. The performance gate is **PASS
for this repository change**. Real-device latency, sustained Relay throughput,
CPU, RSS, and cross-instance load remain required release-environment evidence
and are not silently treated as measured here.
