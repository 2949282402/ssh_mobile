> Last updated: 2026-08-21

# PR49 File Ownership Lock

The Coordinator owns this lock and must claim a disjoint file set before each
modification. Claims are released after the focused validation and diff review.
No agent may modify another claim's files.

| Agent | Owned Files | Modification Scope | State |
| --- | --- | --- | --- |
| Coordinator | `OWNERSHIP_LOCK.md`, audit/review reports, final reports, `tool/compatibility_inventory.dart`; `native/network_core/crates/network-core/src/peer.rs`; inbound-path helpers and typed Relay/Transfer ports in `runtime.rs`, `runtime_lifecycle.rs`, `relay.rs`, `relay_control.rs`, `relay_data.rs`, `relay_transfer.rs`, `relay_state.rs`, `relay_tests.rs`, `transfer.rs`, `transfer_operations.rs`, and `stream.rs`; `packages/infrastructure/network_sdk/lib/src/network_v2.dart`, `network_v2_domains.dart`, `network_v2_facade.dart`; App Shell network service adapters; the V2 contract test and package README | Integration, classification, final acceptance; exact inbound carrier binding; SDK/App domain-port migration and lifecycle ownership correction; typed Relay/Transfer bridge, Runtime lifecycle aggregate, and production function ownership splits with focused regression validation; no wire-protocol change | released after full local CI and strict acceptance |
| Repair A — Connectivity | `native/network_core/crates/network-core/src/connect/connectivity_attempt.rs`; `runtime.rs`; `connect/peer_supervisor.rs`; their focused tests | Capability-aware Stage A/reuse and stage-order regression tests | released; strict acceptance reviewed |
| Repair B — Candidate cache | `native/network_core/crates/network-core/src/relay.rs`; `native/network_core/crates/network-core/src/connect/connectivity_attempt.rs` tests only; `native/network_core/crates/network-relay/src/v2/control_client.rs`; candidate/cache tests | Runtime epoch invalidation and TTL propagation tests | released; strict acceptance reviewed |
| Repair C — PathLease | `native/network_core/crates/network-core/src/transfer.rs`; `stream.rs`; `connect/ready_index.rs`; focused tests | Inbound physical-path binding and operation leases | released; coordinator integrated entry points |
| Repair D — Relay security | `relay/internal/relay/device_enrollment.go`; `control_v2.go`; `reservation.go`; `admin_access.go`; focused tests | Fail-closed auth, revocation admission, expiry/revocation tests | released; strict acceptance reviewed |
| Repair E — FFI | `packages/infrastructure/ssh_mobile_network_native/lib/src/ssh_mobile_network_native.dart`; `network_native_isolate.dart`; `native/network_core/crates/network-ffi/src/lib.rs`; focused tests | Stop/destroy ordering, bounded command tracking, ABI lifecycle tests | released; strict acceptance reviewed |
| Repair F — CI/docs | `scripts/network_v2_acceptance.sh`; `scripts/full_test.sh`; `docs/NETWORK_FAULT_MATRIX.md`; `relay/README.md`; focused checker tests | Validation preflight and stale lifecycle documentation | released; strict acceptance reviewed |

Claims are intentionally narrow. Repair agents must report changed paths and
release their claim; the Coordinator reviews all diffs before the next gate.
