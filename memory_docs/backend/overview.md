> Last updated: 2026-08-13

# Backend Overview

`relay/` is the Go control-plane and WebSocket Relay service. It owns device
enrollment, authenticated device connections, the administrator API, in-memory
device/session state, Relay routing, and the production Compose/Caddy topology.

It does not own:

- the React console in `front/`;
- Flutter or Rust Session, Delivery, or cryptographic state;
- persistent device or transfer storage;
- interpretation of opaque application-E2EE payloads.

Canonical operational and API documentation:

- [Relay README](../../relay/README.md)
- [Relay Compose topology](../../relay/compose.yaml)
- [Backend current state](current-state.md)

Changes to the device wire contract, opaque handshake forwarding, or Session
route behavior also require the [SDK Memory](../sdk/overview.md) and the
relevant ADR.
