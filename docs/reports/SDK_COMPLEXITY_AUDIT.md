> Last updated: 2026-08-21

# SDK Complexity Audit

Status: PASS — App, Runtime lifecycle, and Relay/Transfer domain and
production-function extractions landed

Scope: Dart `network_sdk`, `network_facade`, `network_service`, `network_v2`,
and Rust `runtime.rs`, `runtime_lifecycle.rs`, `connection.rs`, `session.rs`,
`relay.rs`, `relay_control.rs`, `relay_data.rs`, `relay_transfer.rs`,
`relay_state.rs`, `relay_tests.rs`, `transfer.rs`, and
`transfer_operations.rs`. The audit is retained as the migration ledger. The
current implementation has landed the App Shell service split, the Runtime
lifecycle aggregate, typed Runtime Relay/Transfer ports, and the production
function ownership splits described below.

## Findings

### 1. Public boundary overlap

- File: `packages/infrastructure/network_sdk/lib/network_sdk.dart:4-10`;
  `lib/src/network_clients.dart:52-57,93-129,211-223`
- Current Responsibility: Exposes Bootstrap, authentication, Session,
  Realtime, event streams, and compatibility aliases.
- Problem: `SessionClient` is documented as an internal NetworkFacade boundary
  but is exposed through `NetworkSdk.sessions`; legacy NetworkFacade/Session
  and NetworkV2Facade/NetworkV2CommandPort are exported in parallel, while no
  production implementation of NetworkV2CommandPort was found.
- Target Domain: SDK public API and compatibility migration.
- Migration Risk: High.

### 2. V2 contract aggregation

- File: `packages/infrastructure/network_sdk/lib/src/network_v2.dart:7-32,94-223,321-395,398-584,592-742`
- Current Responsibility: Resource limits, request models, command-result
  tracking, environment/diagnostic models, events, command port, and Facade
  lifecycle.
- Problem: Multiple ownership domains are combined; `NetworkV2FacadeImpl`
  documents the injected Port as App/native-owned (`:609-610`) but `dispose`
  calls `_port.stop()` and `_port.dispose()` (`:713-722`), risking borrower
  shutdown of an owner resource.
- Target Domain: V2 models, command correlation, event contract, and App Shell
  lifecycle adapter.
- Migration Risk: High.

### 3. Dart App God Object — RESOLVED AT THE COMPATIBILITY BOUNDARY

- Files: `apps/ssh_mobile_full/lib/services/network/network_service.dart` and
  its `network_service_*` adapter, coordinator, projection, lifecycle, and
  router parts.
- Current Responsibility: `NativeNetworkService` is now a compatibility
  facade/combination root. Command correlation, event routing, Runtime
  lifecycle, Peer, Relay, Route projection, and Transfer are separate internal
  owners.
- Resolution: The two public construction modes and `NetworkService` API are
  unchanged. `fromGateway` still borrows the gateway and never disposes an
  AppRuntime owner. Existing App V2 contract tests pass after the migration.
- Target Domain: App Shell command adapter, Peer/Route projection, Relay
  adapter, Transfer adapter, and runtime lifecycle owner.
- Migration Risk: Reduced to Medium for future public-boundary cleanup.

### 4. Rust RuntimeState aggregation

- Files: `native/network_core/crates/network-core/src/runtime.rs` and
  `runtime_lifecycle.rs`
- Current Responsibility: Session admission, crypto, Delivery, Realtime,
  Relay control/data, discovery/cache, PeerSupervisor, PathManager,
  ReliableStream, TransferManager, and task supervision.
- Problem: The root still coordinates Session teardown, PathLease lookup,
  Direct/Relay close, Transfer pause, Realtime close, and stream cleanup, but
  the Relay and Transfer flat field groups have now been moved behind
  `RelayDomainState` and `TransferDomainState`, while lifecycle resources
  (endpoint, accept-loop task ids, identity, and receive directory) are owned
  by `RuntimeLifecycleState`.
- Target Domain: Runtime lifecycle root plus Peer/Path, Relay, Transfer,
  Realtime, and Crypto typed ports.
- Migration Risk: Reduced to High; lifecycle methods still coordinate the
  aggregate and require no public API change during any further extraction.

### 5. Rust Relay aggregation

- Files: `native/network_core/crates/network-core/src/relay.rs`,
  `relay_state.rs`, and `relay_tests.rs`
- Current Responsibility: Control/reconnect, Direct offers, reservation data
  plane, opaque/E2EE admission, message/stream/ACK routing, and Relay file
  transfer approval/chunking/checksum/resume/cancel.
- Problem: Control/reconnect, data/E2EE, and file transfer have distinct
  ownership while still sharing one implementation file and borrowing
  RuntimeState, Crypto, Peer, Stream, Channel, and Transfer domain ports.
- Resolution: Relay runtime state is physically isolated in `relay_state.rs`,
  Relay regression tests are isolated in `relay_tests.rs`, and production
  control, data/E2EE, and file-transfer functions are isolated in
  `relay_control.rs`, `relay_data.rs`, and `relay_transfer.rs` behind the
  state and typed-port boundaries.
- Target Domain: Relay Control, Relay Data, Relay admission/Crypto, and Relay
  Transfer adapter.
- Migration Risk: Critical.

### 6. Rust Transfer aggregation

- File: `native/network_core/crates/network-core/src/transfer.rs:99-274,316-447,451-974,976-1104`
- Current Responsibility: Transfer identity/lifecycle, PathLease/route choice,
  QUIC file I/O, manager state, approval, progress, resume, command dispatch,
  and Relay forwarding.
- Problem: Business ownership was mixed with concrete QUIC carrier, Runtime
  command boundary, and Relay adapter; `TransferDispatcher` is reasonable but
  the file also owned direct attempts and incoming approval. The manager is
  now held by `TransferDomainState` and the operation/IO/command functions are
  isolated in `transfer_operations.rs`.
- Target Domain: Transfer lifecycle/progress/resume, QUIC attempt adapter,
  Relay attempt adapter, and command adapter.
- Resolution: The root retains the Transfer state aggregate, identity models,
  and dispatcher boundary; the function-level operation lifecycle, QUIC I/O,
  inbound approval, progress, and command adapter now live in
  `transfer_operations.rs` with the public crate entry points re-exported.
- Migration Risk: Reduced to Medium for future owner-specific refinements.

### 7. Relay/Transfer bidirectional dependency — TYPED BRIDGE LANDED

- File: `native/network_core/crates/network-core/src/relay.rs:290,669,1282`;
  `transfer.rs:260,994,1085-1088`
- Current Responsibility: Relay triggers Transfer resume/cleanup; Transfer
  invokes Relay file send/cancel/incoming approval; both reach the other's
  internal state through RuntimeState.
- Problem: The domains still use the Runtime root as their lifecycle and typed
  adapter composition point; this is intentional because RuntimeState owns
  the cross-domain lifecycle and both ports are explicit.
- Resolution: `runtime.rs` now defines `RelayTransferPort` and
  `TransferRelayPort`. Transfer dispatch/approval/cancel and Relay recovery
  requests route through those interfaces; concrete adapters remain in the
  dedicated Relay and Transfer operation modules. Direct
  `crate::relay`/`crate::transfer` calls between the two modules have been
  removed.
- Migration Risk: Reduced to Medium; focused Rust tests and clippy are green.

## Deliberate PASS / do not mechanically split

- `network_facade.dart:95-255`: cohesive NetworkFacade delegation boundary;
  it should remain the single Feature-facing business facade.
- `connection.rs:1-675`: cohesive Connection/generic carrier domain; later
  lines are primarily tests and do not justify mechanical splitting.
- `session.rs:1-364`: cohesive ConnectionSession admission/security store;
  it correctly excludes Peer lifecycle, route, carrier, stream, Relay, and
  business recovery.

## Required Changes

- Complete the Architecture Freeze Gate before cleanup. **PASS**.
- Define one V2 public contract and App adapter before changing compatibility
  aliases. **PASS for the current compatible facade**.
- Migrate God Objects by function ownership with interfaces, caller migration,
  regression tests, and removal of old paths. **PASS for App, Runtime, Relay,
  and Transfer boundaries**.
- Use a typed interface to break Relay/Transfer bidirectional access. **PASS;
  focused network-core regression suite is green**.
- Continue owner-specific refinements only after each owner has a focused
  lifecycle test; do not mechanically move security-sensitive code without a
  cutover. The planned domain hardening is complete.
- Preserve current NetworkFacade, Connection, and Session boundaries where the
  audit found cohesive ownership.

## Risk

Medium. The completed ports, lifecycle aggregate, and production function
modules reduce direct module coupling. Future edits must still preserve public
API compatibility, E2EE, Session admission, PathLease semantics, Relay
security, Transfer resume, and runtime shutdown ordering.
