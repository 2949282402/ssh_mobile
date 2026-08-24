> Last updated: 2026-08-21

# Legacy Ownership Audit

Status: BLOCKED

Scope: `native/network_core` connection, session, connect, and crypto domains.
This was a read-only audit; no implementation files were changed.

## Findings

- PASS: No legacy `ConnectionRegistry`, `ConnectionOrchestrator`,
  `SessionManager`, or `active_route` owner was found. `ConnectionRouteSelector`
  is a pure selector (`native/network_core/crates/network-core/src/connection.rs:209-226`),
  `ReadySessionIndex` is an index (`connect/ready_index.rs:1-15`), and
  `ConnectionSessionStore` is admission-only (`session.rs:1-11,90-117`).
- PASS: Carrier lifetime is owned by `PeerPathManager`/`PhysicalPath`
  (`connect/path.rs:148-181,664-890,1189-1472`); connectivity state is
  coordinated by `ConnectivityAttemptCoordinator`
  (`connect/connectivity_attempt.rs:63-131`). No old `network.v1` state machine
  or per-message `crypto_mode` owner was found.
- BUG / ARCHITECTURE RISK: `try_stage_a_direct` returns success for any ready
  Direct path without checking requested capability
  (`connect/connectivity_attempt.rs:633-651`), and
  `RuntimeState::has_ready_direct_path` checks only path existence
  (`runtime.rs:737-749`).
- BUG / ARCHITECTURE RISK: `RuntimeState::begin_connect` ignores
  `_required_capabilities` and uses `ConnectionSessionStore` binding to return
  `AlreadyConnected` (`runtime.rs:522-557`); the success branch can bypass
  capability-aware route admission (`connect/connectivity_attempt.rs:334-355`).
- BUG / TEST GAP: Concurrent capability handling only covers strictly stronger
  comparable requirements (`connect/peer_supervisor.rs:152-168,594-605`), while
  datagram and stream requirements are not fully unioned. Existing coverage is
  limited to message-to-stream stronger requirements
  (`peer_supervisor.rs:1292-1313`).

## Required Changes

- Make Stage A, `AlreadyConnected`, and reuse paths capability-aware.
- Keep `ConnectionSessionStore` security/admission-only; do not let it decide
  connectivity ownership.
- Carry a true bitwise capability union through attempt, route admission, ready
  index, and tests; add incompatible path/session and datagram+stream tests.

## Risk

An unsupported request can be reported successful and fail later at send time;
incompatible concurrent requirements can wait indefinitely or select the wrong
transport. Legacy ownership migration itself is largely complete, but the
remaining capability bug blocks acceptance.
