> Last updated: 2026-08-19

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
  `start → stop → destroy` binding lifecycle.
- Rust `network-core` owns transport-scoped ConnectionSession state, active routes, Delivery/Transfer managers,
  full-epoch ConnectivityAttempt snapshots, candidate races, StreamHandle-aware
  ReliableStream events, cryptographic context, transfer state, Realtime state,
  and supervised tasks.
- Each transport Connection owns exactly one `ConnectionSession`; a new
  connection gets a new `SessionId` and Noise root, and transport loss destroys
  that session. Delivery and Transfer managers own the business state that may
  resume across fresh ConnectionSessions.
- `relay/` is an external authenticated carrier and opaque forwarder, not a
  ConnectionSession or crypto owner.

The complete rationale remains in the
[network design](../../docs/网络传输SDK架构设计_最终版.md) and
[ADRs](../../docs/adr/).
