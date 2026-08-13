> Last updated: 2026-08-13

# Backend Current State

The maintained backend is the v1 Go control plane and memory-only WSS Relay in
`relay/`.

Current boundaries:

- Device enrollment binds an in-memory credential to a device identity.
- Device WebSocket connections are authenticated before hub admission.
- The administrator API uses a separate versioned contract and an in-memory,
  HttpOnly-cookie session.
- Relay payloads and Session crypto-handshake stages are forwarded opaquely.
  The backend does not own Application Root material or plaintext.
- Process restart clears device, administrator-session, and Relay-session state;
  clients must enroll again.
- Docker Compose with Caddy is the supported production topology.

Endpoint definitions, environment variables, deployment instructions, and the
current hardening backlog remain owned by the [Relay README](../../relay/README.md).

For route and cryptographic semantics, read:

- [SDK transport routing](../sdk/features/transport-routing.md)
- [Relay direct upgrade ADR](../../docs/adr/ADR-018-relay-direct-upgrade.md)
- [Forward-secret Session E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md)
