> Last updated: 2026-08-15

# Backend Current State

The maintained backend is the v1 Go control plane and WSS Relay in `relay/`.
Device-plane durable state (enrollment, revocation) is behind a `Storage`
interface: the default `memory` mode is process-local and restart clears it;
`mysql` mode persists it and requires `RedisURL` for the shared state layer
(presence, replay-protection nonce, administrator sessions, cross-instance
events). Non-redundant single-instance data plane stays in the hub
(`hub.peers`, `hub.transferSessions`).

Current boundaries:

- Device enrollment binds a signed (HMAC) credential to a device identity;
  the durable enrollment record (device ID + public key) lives in `Storage`.
- Device revocation is one atomic store transaction (MySQL: device-row lock +
  tombstone + removal), so a revoke and a concurrent cross-instance re-enroll
  serialize on the device row instead of tearing into a "removed but not
  revoked" state; the admin handler keeps the per-device lock stripe for the
  local nonce/hub/event side effects.
- Device WebSocket connections are authenticated before hub admission through a
  single `authenticatedRequest` path: credential signature/expiry, Ed25519
  proof, anti-replay nonce, enrollment key match, and revocation check.
- The administrator API uses a separate versioned contract and an HttpOnly
  cookie session; sessions live in the `Cache` layer (memory by default, Redis
  when configured).
- Administrator online statistics are derived from the `Cache` presence layer;
  device-to-device `lookup` still answers from the local hub, matching the
  single-instance data plane (cross-instance lookup is deferred to the
  cross-instance forwarding milestone).
- Relay payloads and Session crypto-handshake stages are forwarded opaquely.
  The backend does not own Application Root material or plaintext.
- Process restart clears device, administrator-session, and Relay-session state
  **in memory mode**; `mysql` mode keeps enrollment and revocation durable and
  devices keep working across a restart.
- Docker Compose with Caddy is the supported production topology; a `storage`
  compose profile adds MySQL and Redis for the durable/multi-instance stack.

Endpoint definitions, environment variables, deployment instructions, and the
current hardening backlog remain owned by the [Relay README](../../relay/README.md).

For route and cryptographic semantics, read:

- [SDK transport routing](../sdk/features/transport-routing.md)
- [Relay direct upgrade ADR](../../docs/adr/ADR-018-relay-direct-upgrade.md)
- [Forward-secret Session E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md)
