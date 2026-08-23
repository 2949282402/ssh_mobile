> Last updated: 2026-08-24

# Backend Current State

The maintained backend retains the v1 Go control-plane baseline while the v2
control/data path is developed as an additive migration in `relay/`.
Device-plane durable state (enrollment, revocation) is behind a `Storage`
interface: the default `memory` mode is process-local and restart clears it;
`mysql` mode persists it and requires `RedisURL` for the shared state layer
(presence, discovery, replay-protection nonce, administrator sessions,
shared live-state events). The first-phase topology is a single Relay Control
instance and a single Relay Data instance; Redis is the external shared live
state. Non-redundant single-instance data plane stays in the hub
(`hub.peers`, `hub.transferSessions`).

Current boundaries:

- Device enrollment binds a signed (HMAC) credential to a device identity;
  the durable enrollment record (device ID + public key) lives in `Storage`.
- Device revocation is one atomic store transaction (MySQL: device-row lock +
  tombstone + removal), so a revoke and a concurrent re-enroll serialize on the
  device row instead of tearing into a "removed but not revoked" state; the
  admin handler keeps the per-device lock stripe for the local nonce/hub/event
  side effects.
- Device WebSocket connections are authenticated before hub admission through a
  single `authenticatedRequest` path: credential signature/expiry, Ed25519
  proof, anti-replay nonce, enrollment key match, and revocation check.
- The administrator API uses a separate versioned contract and an HttpOnly
  cookie session; sessions live in the `Cache` layer (memory by default, Redis
  when configured).
- Administrator online statistics are derived from the `Cache` presence layer.
- Device-to-device `lookup` reports a peer online only when its presence lease
  is valid **and** a `discovery:{device_id}` snapshot exists, and returns the
  stored opaque candidates; a peer with only one of the two is not treated as
  connectable.
- The server stores a bounded discovery snapshot per online device
  (`discovery:{device_id}` = device_id + generation + opaque candidates +
  capabilities), filled from the device's own candidate reporting. The snapshot
  is removed when the connection is replaced or goes offline, with TTL /
  sweeper as a backstop.
- The server pushes four presence events over each authenticated device
  connection: `presence_snapshot`, `peer_online`, `peer_updated`, and
  `peer_offline`. Events are light: they carry only `device_id` + `generation`;
  candidate details are fetched via `lookup` (event-light / lookup-heavy model).
- A presence sweeper marks a device offline when its presence lease expires
  (TTL 60s, renewed by the 20s heartbeat), cleaning its discovery snapshot and
  feeding `peer_offline` and the admin presence view.
- `GET /v1/peers` exposes the online device view backed by the presence +
  discovery model.
- Relay payloads and Session crypto-handshake stages are forwarded opaquely.
  The backend does not own Application Root material or plaintext; discovery
  storage keeps opaque candidates without parsing their endpoint semantics
  (ADR-017 revision boundary).
- The V2 Relay Data registry treats `Ready` as one-shot per completed pair. If either role disconnects or is replaced, the old pair is closed and both roles must perform a fresh `Connect → Ready`; the remaining old endpoint never receives a second `Ready`.
- V2 client requests require a non-zero `request_id`; asynchronous connectivity
  and reservation requests also require an `attempt_id`. Resolve maps backend
  uncertainty to `UNKNOWN`/`CONTROL_UNAVAILABLE`, never to fail-open `OFFLINE` or
  `READY`, and a discovery snapshot with a zero `runtime_epoch` is not ready.
- V2 Relay Data admission binds the authenticated device to its reservation role
  and role-specific token. Device revocation closes pending endpoints, active
  pairs, and their counterparts; server shutdown closes all registered data
  endpoints.
- Expired credentials are rejected at new RelayControl and RelayData admission,
  while natural credential expiry does not terminate an already paired Ready
  data path. Explicit revoke remains an authorization termination event and
  closes pending/active participants plus the active counterpart; persistent
  revoke-store failure is fail-closed.
- After a RelayData pair is Ready, the reservation is consumed for new
  admission while active sockets keep their in-memory authorization. PairReady
  and 30s/15s Ping/Pong liveness control frames share the single outbound writer;
  active RelayData is not closed by reservation TTL or natural credential expiry.
- Relay Data storage, HTTP admission, one-shot pair registry, flow budget, and
  connection pump are independent owners. The pump borrows only reservation
  delete/renew and endpoint admit/release capabilities, so it cannot reach
  enrollment, presence, administrator state, registry revocation internals, or
  mutate flow counters directly.
- Process restart clears device, administrator-session, and Relay-session state
  **in memory mode**; `mysql` mode keeps enrollment and revocation durable and
  devices keep working across a restart.
- Docker Compose with Caddy is the supported production topology; a `storage`
  compose profile adds MySQL and Redis for the durable/Redis shared-state stack
  (single Relay Control instance + single Relay Data instance).

Endpoint definitions, environment variables, deployment instructions, and the
current hardening backlog remain owned by the [Relay README](../../relay/README.md).

For route and cryptographic semantics, read:

- [Relay control-plane architecture](../../docs/architecture/RELAY_CONTROL_PLANE.md)
- [SDK transport routing](../sdk/features/transport-routing.md)
- [Relay direct upgrade ADR](../../docs/adr/ADR-018-relay-direct-upgrade.md)
- [Candidate exchange ADR](../../docs/adr/ADR-017-candidate-exchange.md)
- [Direct First ADR](../../docs/adr/ADR-008-direct-relay-race.md)
- [Forward-secret Session E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md)

## Validation gates

Run the Go backend checks from the Relay directory:

```bash
cd relay
go test ./...
go test -race ./...
go vet ./...
```

The periodic backend coverage gate is run from the repository root:

```bash
bash scripts/backend_coverage.sh
```

When test DSNs are not supplied, the script provisions temporary
`mysql:8.4` and `redis:7-alpine` containers and removes them on exit. The
cross-owner Network V2 contract gate is:

```bash
bash scripts/network_v2_acceptance.sh strict
```
