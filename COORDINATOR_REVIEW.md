> Last updated: 2026-08-23

# Network V2 Coordinator Review

This is the canonical coordinator review for the PR48 local closure. The
review classifies the read-only audit snapshots and records current evidence.
It does not authorize changes to the frozen protocol or public SDK surface.

Validation base: branch `agent/network-v2-final-20260819`, commit
`926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

## PASS

- Legacy ownership: no old connection/session owner was found; selectors and
  indexes remain helpers, and `ConnectionSessionStore` is admission-only.
- Path accounting: `PathHandle` and `PathLease` are distinct, Delivery send
  attempts are bounded, outbound Streams hold one lease through close, and
  inbound Stream/Transfer carriers bind to the physical path that delivered
  them.
- Connectivity ownership: Stage A/reuse is capability-aware, required masks
  reach transport attempts, and failed Stage A now enters one concrete
  authoritative Resolve → Offer transaction before the Direct window and any
  Relay reservation. Independent tests also prove cancellation and overall
  timeout cleanup permit a new admission with a distinct SessionId, and that
  stale cleanup cannot close the replacement.
- Stage C evidence: the independent test fixture records exactly one Resolve,
  one Offer, one Direct-failure event, and one Reserve in strict temporal order;
  existing RelayData owner tests cover pair-ready admission, opaque payload/ACK,
  and close.
- Candidate freshness: monotonic TTL, expiry exclusion, runtime-epoch
  invalidation, Ready-TTL invalidation, wall-clock independence, and heartbeat
  non-refresh behavior are covered by owner tests.
- Relay role/token binding, fail-closed nonce-cache behavior, final admission
  revocation rechecks, configured Ready TTL, credential expiry, and the V2
  revocation matrix have executable owner tests.
- FFI representation, bounded terminal history, serialized stop/dispose,
  isolate-exit ordering, and buffer copy/free paths match the current ABI.
- `NetworkFacadeImpl`, `connection.rs`, and `session.rs` remain cohesive and
  were not mechanically split by file size.

## ENVIRONMENT GAP / FOLLOW-UP

- The coverage-enabled aggregate `scripts/full_test.sh` reached the App Flutter
  shard but stalled while loading tests in WSL; owner/workspace and domain
  quality gates remain independently green. A native Windows PowerShell 7 or
  CI run may supply separate Flutter coverage evidence; it does not convert
  this WSL gap into a Linux PASS.
- Real Redis/MySQL-backed admission, cross-instance revocation delivery, and
  physical Android/iOS lifecycle runs remain environment-dependent follow-ups.
- ReadySessionIndex draining/reacquisition and full production transport fault
  injection remain beyond the local owner suites.
- Production performance benchmarking is `DEFERRED — NON-BLOCKING`.

## BUG — resolved in the final-fix working tree

- Capability-aware Stage A/reuse and exact transport-mask propagation are
  covered by connectivity and PeerSupervisor tests.
- Inbound physical-carrier binding and operation-lifetime leases are covered by
  the Stream mismatch test and the full `network-core` library suite.
- Runtime epoch and configured Ready-TTL invalidation have deterministic cache
  tests.
- The concrete Relay client now performs exactly one Resolve followed by one
  Offer enqueue, and the exact sequence is exercised over a loopback
  authenticated WebSocket with two real clients.
- Relay admission, nonce-cache failure, expiry, revocation, and role/token
  checks are covered by the strict Go selector.
- Native lifecycle serialization, exit ordering, bounded history, and safe
  buffer cleanup are covered by Rust FFI and Dart facade tests.

## ARCHITECTURE RISK — held for explicit future work

- The Dart Network V2 public boundary and compatibility aliases overlap; alias
  retirement requires an external-consumer migration inventory.
- `NetworkV2FacadeImpl.dispose()` must continue to preserve App/native ownership
  of an injected Port.
- Native service, RuntimeState, Relay, and Transfer boundaries must remain
  governed by typed interfaces before any further extraction.
- Candidate-cache epoch and Relay Ready TTL ownership remain explicit; changing
  that boundary requires an accepted decision.
- A multi-process Stage C deployment harness and broader timeout/cancellation
  stress matrix are future integration work, not reasons to change the frozen
  wire shape; the required local evidence is now in independent test files.

## Coordinator decision

The final-fix owner gates are **PASS for runnable Linux evidence**, with the
coverage-enabled aggregate App shard recorded as an environment gap. The Stage
B double-Resolve architecture defect, stub-only confidence gap, and lifecycle
reconnect poisoning regressions are closed; Stage C has the required local
order/count evidence and RelayData owner coverage. Multi-process deployment,
native-platform/environment evidence, and production performance benchmarks
remain explicit follow-ups. Phase 4 SDK cleanup is complete under the freeze
gate, while public compatibility-alias retirement remains deferred and
non-blocking pending an external-consumer migration inventory. Network V2
protocol direction, PeerSupervisor ownership, and PathLease semantics remain
frozen.
