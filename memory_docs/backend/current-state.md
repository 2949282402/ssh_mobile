> Last updated: 2026-08-27

# Backend Current State

The maintained backend is split into two independent Go services deployed via root
Docker Compose:

1. **Relay Backend** (`cmd/relay`, `internal/relay`):
   - Exposes V2 Bootstrap HTTP for device enrollment (`POST /v2/devices/enroll`)
     and credential refresh (`POST /v2/devices/refresh`), and a v2-only transport plane.
   - The transport routes are the long-lived protobuf `/v2/control` WebSocket and the
     reservation-scoped opaque `/v2/relay/{reservation_id}` WebSocket.
   - Exposes private authenticated management endpoints (`/internal/v2/*`) protected by
     `RELAY_INTERNAL_TOKEN`.
   - The legacy `/v1/*` bootstrap routes are retired (return 404).

2. **Admin Backend** (`cmd/admin`, `internal/admin`):
   - Exposes public REST API (`/api/admin/v1/*`) for administrator login, session management,
     overview, device listing, revocation, and enrollment token rotation.
   - Communicates with Relay via `RelayManagementClient` calling `/internal/v2/*`.
   - Maintains memory-local session store with single-replica constraint.
   - Holds no database, Redis, or signing keys.

Device-plane durable state (enrollment, revocation) is behind a `Storage`
interface: the default `memory` mode is process-local and restart clears it;
`mysql` mode persists it and requires `RedisURL` for the shared live-state
layer (presence, discovery, replay-protection nonce, reservations, and events).
The first-phase topology remains one Relay Control instance and one Relay Data instance;
Redis is external shared live state, not Global Control Routing or Relay Data Node Selection.
Control peers live in the Hub while data endpoints live in an independent one-shot Relay Data registry.

Current boundaries:

- Device enrollment binds a signed (HMAC) credential to a device identity;
  the durable enrollment record (device ID + public key + `protocol_version=2`) lives in `Storage`.
- Device revocation is one atomic store transaction (MySQL: device-row lock +
  tombstone + removal), so a revoke and a concurrent re-enroll serialize on the
  device row instead of tearing into a "removed but not revoked" state.
- Device WebSocket connections are authenticated before hub admission through a
  single `authenticatedRequest` path: credential signature/expiry, Ed25519
  proof, anti-replay nonce, enrollment key match, revocation check, and
  **`enrollment.ProtocolVersion == 2` admission invariant**. Both
  Control and RelayData require a canonical positive Unix-seconds
  `X-Relay-Timestamp`; the exact transcript is
  `GET\n<path>\n<timestamp>\n<nonce>` without a trailing newline. The inclusive
  ±300-second window and timestamp-plus-301-second nonce expiry match refresh;
  malformed/stale proofs, protocol mismatch, and Cache consumption failure return 401 and do not
  upgrade the socket ([ADR-031](../../docs/adr/ADR-031-relay-refresh-proof-freshness.md)).
- Device credential refresh is a V2 freshness contract: requests carry a
  required signed Unix-seconds `timestamp`, and the exact Ed25519 transcript is
  `POST\n/v2/devices/refresh\n<timestamp>\n<nonce>` without a trailing newline.
  Relay accepts the inclusive ±300-second window, retains the nonce until the
  signed timestamp plus 301 seconds, and returns 503 without issuing a
  credential when the replay-protection cache cannot consume the nonce
  ([ADR-031](../../docs/adr/ADR-031-relay-refresh-proof-freshness.md)). Re-enrollment
  on `/v2/devices/enroll` with the same key advances generation and upgrades
  legacy rows to version 2.
  bucket, and drains at most eight unrelated expired buckets per consume; active
  proof windows survive enrollment/revocation while historical empty device
  buckets converge without a whole-cache scan.
- The administrator API uses a separate versioned contract and an HttpOnly
  cookie session; memory composition uses the process-local `Cache`, while the
  MySQL composition uses Redis. Forwarded client-IP headers and
  `X-Forwarded-Proto` are
  trusted only when the immediate peer matches `RELAY_TRUSTED_PROXY_CIDRS`;
  otherwise `RemoteAddr` and direct TLS govern the login limiter, Cookie
  `Secure`, and admin Origin scheme.
- Administrator online statistics are derived from the `Cache` presence layer.
- Device-to-device `ResolvePeerRequest` reports READY only when the target's
  presence lease is valid **and** a matching `discovery:{device_id}` snapshot
  exists; a peer with only one of the two is not treated as connectable.
- The server stores a bounded discovery snapshot per online device
  (`discovery:{device_id}` = device_id + generation + opaque candidates +
  capabilities), filled from the device's own candidate reporting. The snapshot
  is removed when the connection is replaced or goes offline, with TTL /
  sweeper as a backstop.
- The v2 server sends `PresenceHintSnapshot`, `PeerAvailableHint`, and
  `PeerUnavailableHint` over the authenticated control connection. Hints are
  advisory and light; authoritative candidates come from a
  `ResolvePeerRequest`, which returns READY only when matching presence and
  discovery state are both valid and the snapshot has a non-zero runtime epoch.
- A presence sweeper marks a device offline when its presence lease expires
  (TTL 60s, renewed by the 20s heartbeat), cleaning its discovery snapshot and
  feeding `PeerUnavailableHint` and the admin presence view.
- Relay payloads and Session crypto-handshake stages are forwarded opaquely.
  The backend does not own Application Root material or plaintext; discovery
  storage keeps opaque candidates without parsing their endpoint semantics
  (ADR-017 revision boundary).
- The V2 Relay Data registry treats PairReady as one-shot per completed pair.
  A same-role retry replaces an unpaired endpoint; a retry against an active
  pair closes both old roles, starts a fresh pending pair, and requires the
  counterpart to reconnect before a new `Connect → PairReady` completes. A
  remaining old endpoint never receives a second PairReady.
- V2 client requests require a non-zero `request_id`; asynchronous connectivity
  and reservation requests also require an `attempt_id`. Resolve maps backend
  uncertainty to `UNKNOWN`/`CONTROL_UNAVAILABLE`, never to fail-open `OFFLINE` or
  `READY`, and a discovery snapshot with a zero `runtime_epoch` is not ready. A
  reservation request consumes a bounded, one-shot fallback gate established by
  the same authenticated Control connection's successful Resolve → Offer and
  must match that attempt and target. Attempts and gates maintain exact removable
  expiry indexes: an ordinary Offer performs no global expiry scan, full global
  capacity releases at most one expired heap root, and a full connection bucket
  examines only its fixed 64-entry reverse index. The authoritative Offer is
  encoded and allocated before entering the Hub mutex; the critical section
  rebinds both exact connection owners, commits the indexes, and performs only a
  non-blocking enqueue, with complete rollback on failure.
- V2 Relay Data admission binds the authenticated device to its reservation role
  and role-specific token. Device revocation closes pending endpoints, active
  pairs, and their counterparts. Forwarding encodes and allocates the opaque
  frame before entering the registry mutex; under that mutex it only rechecks
  pair state, reserves the flow budget, and performs a non-blocking queue handoff.
  Revocation marks both roles terminal and detaches retry ownership at the same
  linearization point; the writer discards queued business frames and waits out
  a write that already began before the lifecycle call returns. Server shutdown
  closes all registered data endpoints.
- Expired credentials are rejected at new RelayControl and RelayData admission,
  while natural credential expiry does not terminate an already paired Ready
  data path. Explicit revoke remains an authorization termination event and
  closes pending/active participants plus the active counterpart; persistent
  revoke-store failure is fail-closed.
- After a RelayData pair is Ready, the reservation is consumed for new
  admission while active sockets keep their in-memory authorization. PairReady
  is the WebSocket Ping
  `ssh-mobile-relay-paired-v1:<reservation_id>`: both queues must accept the
  marker before pair commit, and each endpoint cannot forward until its own
  marker has actually been written. The 30s/15s Ping/Pong liveness path shares
  the single outbound writer but uses the distinct
  `ssh-mobile-relay-keepalive-v1` marker. Active RelayData is not closed by
  reservation TTL or natural credential expiry.
- Relay Data storage, HTTP admission, one-shot pair registry, flow budget, and
  connection pump are independent owners. The pump borrows only reservation
  delete/renew and endpoint admit/release capabilities, so it cannot reach
  enrollment, presence, administrator state, registry revocation internals, or
  mutate flow counters directly.
- `RELAY_PUBLIC_URL` is normalized from the public HTTP edge origin to the data
  WebSocket origin: HTTPS becomes WSS, explicit WSS is preserved, and loopback
  HTTP becomes WS. A root path `/` is normalized away; non-root paths, queries,
  fragments, embedded credentials, and non-loopback cleartext origins are
  rejected.
- Redis command and pool safety is process-owned after URL parsing: context
  cancellation is enabled, automatic retries are disabled, dial/read/write and
  pool waits are capped at two seconds, and pool/active connections are capped
  at 64. URL query parameters cannot weaken these bounds.
- MySQL and Redis startup share one 15-second deadline. Shutdown performs at
  most 15 seconds of HTTP graceful shutdown followed by one 10-second Relay
  runtime budget; RelayData, Hub, and event reconciliation converge
  concurrently, then Cache and Storage close concurrently inside the remaining
  total budget, with forced socket close after bounded drain. A dependency that
  ignores cancellation cannot make `Server.Close` unbounded.
- Both `NewServer` memory mode and MySQL/Redis composition discard any supplied
  database URL, Redis URL, and Redis password after construction. The Hub keeps
  only the scalar routing/capacity/lifecycle capabilities it owns; long-lived
  runtime state cannot expose startup endpoints or credentials.
- Process restart clears device, administrator-session, and Relay-session state
  **in memory mode**; `mysql` mode keeps enrollment and revocation durable and
  devices keep working across a restart.
- Docker Compose with Caddy is the supported production topology; a `storage`
  compose profile adds MySQL and Redis for the durable/Redis shared-state stack
  (single Relay Control instance + single Relay Data instance).
- Telemetry & Observability Pipeline (`internal/telemetry`) is decoupled from Relay core:
  - Ingestion (`POST /api/v1/telemetry/ingest`), authentication (`POST /api/v1/telemetry/auth`),
    and dynamic policy (`GET /api/v1/telemetry/policy`) run on dedicated HTTP endpoints.
  - Ingestion processes batch records atomically: each record writes to `telemetry_events` (or
    `telemetry_diagnostics`) and inserts permanent `telemetry_ingest_receipts` (with
    `event_id`, `received_at`, `status`). Duplicate `event_id`s return `already_seen` without
    mutating data rows.
  - Scheduled retention background worker purges data based on trusted server `received_at`
    (time window and row count bounds) while preserving all idempotency receipts permanently.
  - Redis Stream hot cache provides sub-millisecond retrieval of recent diagnostic logs for
    admin streaming, automatically falling back to MySQL when Redis is offline or unconfigured.
  - Admin endpoints (`/api/admin/v1/telemetry/*`) provide aggregated overview metrics, filterable
    event explorer, diagnostic log stream, and dynamic policy/retention settings management.

Endpoint definitions, environment variables, deployment instructions, and the
operational contract remain owned by the [Relay README](../../relay/README.md).

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
bash scripts/bash/coverage/backend_coverage.sh
```

When test DSNs are not supplied, the script provisions temporary
`mysql:8.4` and `redis:7-alpine` containers and removes them on exit. The
cross-owner Network V2 contract gate is:

```bash
bash scripts/bash/contracts/network_v2_acceptance.sh strict
```
