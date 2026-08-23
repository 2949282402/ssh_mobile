> Last updated: 2026-08-24

# SDK Architecture

The maintained Client-to-native flow is:

```text
Feature
  → network_sdk contract
  → App Shell adapter
  → network_transport App-scoped runtime
  → ssh_mobile_network_native
  → Rust network_core
```

Ownership rules:

- `network_sdk` exposes business-facing typed contracts and owns no socket,
  native handle, HTTP client, database, isolate, or App lifecycle.
- App Shell adapters correlate public operations with native results and map
  native events without exposing SDP, ICE, sockets, or FFI handles to Features.
- `network_transport` owns the single App-scoped native-runtime facade and
  lends bounded gateways; borrowers release subscriptions, not the native handle.
- `ssh_mobile_network_native` owns the helper isolate and explicit native
  `start → stop → destroy` binding lifecycle. Its stable protocol facade
  delegates command encoding, event-envelope dispatch, typed domain mapping,
  and bounded FFI value validation to separate stateless collaborators.
- Rust `network-core` owns the `PeerSupervisor` lifecycle owner,
  `PeerPathManager` Direct/Relay physical carriers, transport-scoped
  ConnectionSession security state, Delivery/Transfer managers, full-epoch
  ConnectivityAttempt snapshots, candidate races, StreamHandle-aware
  ReliableStream events, cryptographic context, transfer state, Realtime state,
  and supervised tasks. Business code borrows a `PathLease`; the
  `ConnectionSessionStore` does not own route or Peer lifecycle.
- Connectivity attempt execution owns only the bounded Stage A→B→C state
  machine and route/session effects. Candidate snapshot/cache/ranking policy is
  independent from authoritative Resolve and Relay fallback eligibility, so a
  configured endpoint cannot bypass Relay status, E2EE, capability, or budget.
- ReliableStream wire frames, QUIC preambles, and Relay tokens are stateless
  codec concerns. The stream manager owns registry, sequence, bounded buffers,
  tombstones, and one retained `PathLease`; the SSH gateway adapter alone maps
  FFI commands and pumps bytes to local sshd under the runtime supervisor.
- Each transport Connection owns exactly one `ConnectionSession`; a new
  connection gets a new `SessionId` and Noise root, and transport loss destroys
  that session. Delivery and Transfer managers own the business state that may
  resume across fresh ConnectionSessions.
- `relay/` is an external authenticated carrier and opaque forwarder, not a
  ConnectionSession or crypto owner.
- New transport connections always create a fresh SessionId and application
  root. Required E2EE is the normal business path; Disabled is Direct
  identity-only and cannot fall through to Relay.
- `PeerPathManager` may hold one Direct and one Relay ready path concurrently;
  `PathHandle`/projection entries are weak, while a `PathLease` is the only
  business lifetime reservation. Delivery releases a per-send lease before ACK
  wait, Transfer retains its lease for one attempt, and ReliableStream retains
  one lease through open/close without path migration.
- Passive inbound admission is Online-only and does not enable maintenance.
  Network-environment changes preserve healthy Relay/Realtime and schedule
  maintained-peer Direct recovery only after Relay readiness. Native/FFI/Dart
  event lanes are bounded at Control `256/4 MiB`, Data `128/8 MiB`, `1 MiB`
  per event, with an eight-control fairness cap.

The complete rationale remains in the
[network design](../../docs/网络传输SDK架构设计_最终版.md) and
[ADRs](../../docs/adr/).
