> Last updated: 2026-08-21

# PR49 Phase 2 Coordinator Review

This review classifies the eight read-only audit reports. It is the decision
record between audit and the Architecture Freeze Gate. No SDK cleanup is
authorized by this document.

## PASS

- Legacy ownership: no old connection/session owner was found; selectors and
  indexes remain helpers, and `ConnectionSessionStore` is mostly admission-only.
- Path accounting: `PathHandle` and `PathLease` are distinct, `Arc` count is
  not used as lease count, Delivery send attempts are bounded, outbound
  Streams hold one lease through close, and inbound Stream/Transfer carriers
  now bind to the physical path that delivered them.
- Connectivity ownership: Stage A/reuse is capability-aware, required masks
  are propagated to transport attempts without widening the race, and Stage B
  records the required Resolve → Offer → Reservation ordering.
- Candidate freshness: monotonic TTL, expiry exclusion, runtime-epoch
  invalidation, Ready-TTL invalidation, wall-clock independence, and heartbeat
  non-refresh behavior are covered by owner tests.
- Relay role/token binding, fail-closed nonce-cache behavior, final admission
  revocation rechecks, configured Ready TTL, credential expiry, and the V2
  revocation matrix have executable owner tests.
- FFI representation, bounded terminal history, serialized stop/dispose,
  isolate-exit ordering, and buffer copy/free paths match the current ABI.
- `NetworkFacadeImpl`, `connection.rs`, and `session.rs` are cohesive and must
  not be mechanically split by file size.

## TEST GAP — supplement tests

- Real Redis/MySQL-backed admission, cross-instance revocation delivery, and
  physical Android/iOS lifecycle runs remain environment-dependent follow-ups;
  the local acceptance path is deterministic and fail-closed when those
  services are unavailable.
- ReadySessionIndex draining/reacquisition and full production transport fault
  injection remain integration coverage beyond the local owner suites.
- The repository-wide full gate still has external fetch/toolchain gaps recorded
  in the baseline; strict Network V2 acceptance itself is green.

## BUG — resolved before Freeze Gate

- Capability-aware Stage A/reuse and exact transport-mask propagation are
  covered by `connectivity_attempt` and `peer_supervisor` tests.
- Inbound physical-carrier binding and operation-lifetime leases are covered by
  the Stream mismatch test and the full `network-core` library suite.
- Runtime epoch and configured Ready-TTL invalidation have deterministic cache
  tests; Stage B ordering is asserted end to end at the owner-test level.
- Relay admission, nonce-cache failure, expiry, revocation, and role/token
  checks are covered by the strict Go selector.
- Native lifecycle serialization, exit ordering, bounded history, and safe
  buffer cleanup are covered by Rust FFI and Dart facade tests.
- Acceptance preflight, selector coverage, protocol environment classification,
  and stale V1 documentation were corrected and checked by Python contract
  tests.

## ARCHITECTURE RISK — pause and confirm

- The Dart Network V2 public boundary and compatibility aliases overlap; a
  production implementation of `NetworkV2CommandPort` was not found.
- `NetworkV2FacadeImpl.dispose()` appears to release an injected Port that the
  contract says is App/native-owned.
- `NativeNetworkService`, Rust `RuntimeState`, `relay.rs`, and `transfer.rs`
  combine multiple domains and have high/critical migration risk.
- Relay and Transfer access each other through RuntimeState, requiring a typed
  interface before extraction to avoid a dependency cycle.
- Fault-matrix semantics conflict with the accepted disposable
  ConnectionSession/no-transparent-migration ADR.
- Candidate-cache epoch and Relay Ready TTL currently have split ownership;
  changing the boundary requires an explicit owner decision.

## Coordinator decision

The BUG items are resolved and the strict owner acceptance is green. Phase 2 is
**PASS for the Freeze Gate**. The remaining TEST GAP items are explicitly
environment/integration follow-ups, not reasons to alter the frozen protocol.
The ARCHITECTURE RISK items are held for the SDK migration strategy; they do
not authorize a mechanical file split. Network V2 protocol direction remains
frozen, and SDK cleanup is allowed only through the Phase 4 interface → move →
caller → regression-test → old-path-removal sequence.
