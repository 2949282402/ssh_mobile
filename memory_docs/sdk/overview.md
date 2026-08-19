> Last updated: 2026-08-20

# SDK Overview

The SDK domain contains the versioned network contract and native runtime:

- `packages/infrastructure/network_sdk/`: Feature-facing Dart client contracts;
- `packages/infrastructure/network_transport/`: the App-scoped runtime facade;
- `packages/infrastructure/ssh_mobile_network_native/`: Dart FFI and native asset binding;
- `native/network_core/`: Rust PeerSupervisor/PeerPathManager ownership,
  connection security admission, transport, Delivery, transfer, crypto, NAT,
  Relay-client, WebRTC, and FFI implementation;
- `protocol/`: the shared versioned wire schema.

`ssh_core` is Client infrastructure, not part of this domain. The Go Relay is a
separate [Backend domain](../backend/overview.md), although wire, route, and
E2EE changes normally require both domains.

Canonical sources:

- [Network SDK design](../../docs/网络传输SDK架构设计_最终版.md)
- [Network platform implementation plan](../../docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md)
- [Network fault matrix](../../docs/NETWORK_FAULT_MATRIX.md)
- [Transport routing Memory](features/transport-routing.md)
