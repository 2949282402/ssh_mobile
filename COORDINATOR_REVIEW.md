> Last updated: 2026-08-22

# Network V2 Coordinator Review

This is the canonical coordinator review for the Network V2 hardening/final-fix
workstream. The original `PR49 Phase 2` label is historical; it is not a
repository or branch identifier. The review classifies the read-only audit
snapshots and records current closure evidence. It does not authorize changes
to the frozen protocol or public SDK surface.

Validation base: branch `agent/network-v2-final-20260819`, commit
`b61347cbbb062a079ef1e6daa7f82c50123a799f`, with the final-fix working tree
changes uncommitted.

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
  Relay reservation.
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

## TEST GAP — supplement tests

- Stage C still has predicate coverage rather than a complete local
  Direct-failure → READY/E2EE/resource-eligible → Relay reservation/data flow.
- Real Redis/MySQL-backed admission, cross-instance revocation delivery, and
  physical Android/iOS lifecycle runs remain environment-dependent follow-ups.
- ReadySessionIndex draining/reacquisition and full production transport fault
  injection remain beyond the local owner suites.

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
- A full Stage C integration harness and timeout/cancellation stress matrix are
  still future integration work, not reasons to change the frozen wire shape.

## Coordinator decision

The final-fix owner gates are **PASS for runnable Linux evidence**. The Stage B
double-Resolve architecture defect and stub-only confidence gap are closed;
Stage C and native-platform/environment evidence remain explicit follow-ups.
Phase 4 SDK cleanup is already complete under the freeze gate, while public
compatibility-alias retirement remains deferred. Network V2 protocol direction,
PeerSupervisor ownership, and PathLease semantics remain frozen.
