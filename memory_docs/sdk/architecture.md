> Last updated: 2026-08-13

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
- Rust `network-core` owns logical Session state, active routes, Delivery,
  cryptographic context, transfer state, Realtime state, and supervised tasks.
- `relay/` is an external authenticated carrier and opaque forwarder, not a
  Session or crypto owner.

The complete rationale remains in the
[network design](../../docs/网络传输SDK架构设计_最终版.md) and
[ADRs](../../docs/adr/).
