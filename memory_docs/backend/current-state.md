> Last updated: 2026-08-31

# Backend Current State

Root Compose deploys independent Relay (`cmd/relay`, `internal/relay`) and Admin
(`cmd/admin`, `internal/admin`) services. Relay exposes V2 enrollment/refresh,
protobuf `/v2/control`, reservation-scoped opaque `/v2/relay/{reservation_id}`,
and `RELAY_INTERNAL_TOKEN`-protected `/internal/v2/*`; legacy `/v1/*` bootstrap
is retired (404).
Admin exposes `/api/admin/v1/*` for login, sessions, overview, devices, revoke,
enrollment-token rotation, and telemetry; its memory session store is
single-replica, and Analytics MySQL-backed telemetry queries use isolated
`telemetry.Store` with Redis only as a best-effort diagnostics cache.

Device durable state is behind `Storage`: `memory` is process-local and clears on
restart; `mysql` persists enrollment/revocation and requires `RedisURL` for
shared presence, discovery, replay nonces, reservations, and events. Phase-one
topology is one Relay Control + one Relay Data instance; Redis is shared live
state, not global routing/data-node selection. Control peers live in Hub; data
endpoints live in an independent one-shot Relay Data registry.

## Enrollment, authentication, and admin

- Enrollment binds a signed HMAC credential to device identity; `Storage` keeps
  device ID, public key, and `protocol_version=2`. Re-enrollment with the same
  key advances generation and upgrades legacy rows. MySQL revocation is one
  device-row-locked transaction (tombstone + removal), serializing revoke and
  re-enroll.
- One `authenticatedRequest` gates device WebSockets: credential signature/
  expiry, Ed25519 proof, anti-replay nonce, enrollment-key match, revocation, and
  `ProtocolVersion == 2` all pass before Hub admission. Control and RelayData
  require positive Unix-seconds `X-Relay-Timestamp` and exact
  `GET\n<path>\n<timestamp>\n<nonce>` (no trailing newline), ±300s inclusive;
  nonce expiry is timestamp+301s. Bad/stale proof, protocol mismatch, or cache
  consume failure returns 401 without upgrading the socket.
- Refresh requires signed Unix-seconds timestamp and exact
  `POST\n/v2/devices/refresh\n<timestamp>\n<nonce>`; same ±300s window and
  timestamp+301s nonce retention. Replay-cache consume failure returns 503 and no
  credential. Expiry buckets drain at most eight unrelated expired buckets per
  consume; active proof windows survive enroll/revoke and empty historical
  buckets converge without a whole-cache scan ([ADR-031](../../docs/adr/ADR-031-relay-refresh-proof-freshness.md)).
- Admin uses a separate versioned API and HttpOnly cookie session. Memory uses
  process-local Cache; MySQL composition uses Redis. Relay accepts
  `X-Relay-Client-Addr` only from an immediate peer in
  `RELAY_TRUSTED_PROXY_CIDRS`; Admin's forwarded client-IP and
  `X-Forwarded-Proto` headers use its own `ADMIN_TRUSTED_PROXY_CIDRS`.
  Untrusted requests use their direct socket address and TLS state.
  Online statistics come from Cache presence.

## Presence, discovery, and Relay data

- `ResolvePeerRequest` is READY only when a valid presence lease and matching
  `discovery:{device_id}` snapshot both exist, with non-zero runtime epoch.
  Snapshots contain device ID, generation, opaque candidates, and capabilities;
  they are filled by the device, removed on connection replacement/offline, and
  TTL/sweeper is a backstop. Control sends advisory
  `PresenceHintSnapshot`/`PeerAvailableHint`/`PeerUnavailableHint`; Resolve is
  authoritative. Presence TTL is 60s, renewed every 20s; expiry clears discovery
  and updates hints/admin presence.
- Relay payloads and Session crypto stages are opaque; backend never owns
  plaintext/Application Root and never parses candidate endpoint semantics
  (ADR-017 boundary).
- Relay Data `PairReady` is one-shot per completed pair. Same-role retry replaces
  an unpaired endpoint; retry against an active pair closes both roles, starts a
  fresh pending pair, and requires the counterpart to reconnect. A surviving old
  endpoint never receives a second marker.
- Client requests require non-zero `request_id`; async connectivity/reservation
  also require `attempt_id`. Resolve uncertainty maps to `UNKNOWN`/
  `CONTROL_UNAVAILABLE`, never fail-open OFFLINE/READY; zero runtime epoch is not
  ready. Reservation consumes a bounded one-shot fallback gate from the same
  authenticated Control Resolve→Offer and must match attempt/target. Exact expiry
  indexes avoid global scans: ordinary Offer scans none, global capacity releases
  one heap root, and a full connection bucket checks only its fixed 64-entry
  reverse index. Offer is encoded/allocated before Hub mutex; the critical
  section rebinds exact owners, commits indexes, non-blocking-enqueues, and rolls
  back completely on failure.
- RelayData admission binds authenticated device, role, and token. Revocation
  closes pending/active pairs and counterparts. Forwarding allocates/encodes
  before the registry mutex, then only rechecks state, reserves flow budget, and
  non-blocking-enqueues. Revocation marks both roles terminal/detaches retry at
  one linearization point; writer drops queued business frames and waits for an
  already-started write. Shutdown closes all data endpoints.
- New Control/Data admission rejects expired credentials; natural expiry does not
  close an already Ready pair. Explicit revoke is authorization termination,
  closes all participants/counterpart, and fails closed on persistent store error.
  After Ready, reservation is consumed for new admission but active sockets keep
  in-memory authorization. PairReady is WebSocket Ping
  `ssh-mobile-relay-paired-v1:<reservation_id>`: both queues accept before commit
  and each endpoint forwards only after its marker is written. Keepalive uses the
  same writer with `ssh-mobile-relay-keepalive-v1` and 30s/15s Ping/Pong; active
  data is unaffected by reservation TTL/natural credential expiry.
- Relay Data storage, HTTP admission, pair registry, flow budget, and pump are
  separate owners. The pump borrows only reservation delete/renew and endpoint
  admit/release; it cannot access enrollment, presence, Admin, registry revoke
  internals, or mutate counters directly.

## Deployment and runtime bounds

- `RELAY_PUBLIC_URL` derives the data WebSocket origin: HTTPS→WSS, WSS preserved,
  loopback HTTP→WS. Root `/` is removed; non-root paths, query/fragment,
  credentials, and non-loopback cleartext are rejected.
- Redis enables cancellation, disables automatic retries, caps dial/read/write
  and pool waits at 2s, caps pool/active connections at 64, and ignores URL
  attempts to weaken bounds. MySQL/Redis startup shares a 15s deadline. Shutdown
  allows at most 15s HTTP graceful + 10s Relay runtime: RelayData, Hub, and event
  reconciliation converge concurrently, then Cache/Storage close concurrently;
  forced socket close follows bounded drain and cancellation cannot make Close
  unbounded.
- Constructors discard supplied DB/Redis URLs/passwords after setup. Hub retains
  only owned scalar routing/capacity/lifecycle capabilities, never startup
  endpoints/credentials. Memory mode restart clears device/Admin/Relay session
  state; MySQL keeps enrollment/revocation and devices continue working.
- Supported production topology is Docker Compose + Caddy; the bundled Compose
  stack defaults Relay to MySQL + Redis with persistent volumes. The `storage`
  profile additionally starts the Analytics MySQL/Redis services (one Control +
  one Data).

## Telemetry & Observability (`internal/telemetry`)

Telemetry is a separate logical boundary inside Admin, decoupled from Relay:

- Public endpoints are `POST /api/v1/telemetry/auth`,
  `POST /api/v1/telemetry/ingest`, and `GET /api/v1/telemetry/policy`; Admin
  endpoints are `/api/admin/v1/telemetry/*` for overview, event explorer,
  diagnostics feed, and policy/retention settings.
- Device auth signs `telemetry:auth:<deviceId>:<expEpoch>` with the
  `sha256Hex(secret)`-derived HMAC-SHA256 key, allows ±120s skew, and issues a
  two-hour token `<exp>.<hmac(tokenKey, "telemetry:auth:<deviceId>:<exp>")>`.
  Device IDs match `^[A-Za-z0-9._-]{1,128}$` (Relay identity and MySQL VARCHAR
  bound); ingest binds `X-Device-Id` to token HMAC.
- Missing/short (`<16`) `TELEMETRY_AUTH_SECRET` makes public auth/ingest return
  503. Persistence failure never switches to memory; client pending records stay
  retryable. Accepted records atomically insert `telemetry_events` (diagnostics
  use `record_type=diagnostic`) and permanent `telemetry_ingest_receipts`;
  duplicate `event_id` returns `already_seen` without changing raw rows.
- Before persistence: body ≤1 MiB, batch ≤100, writer semaphore non-blocking
  4 slots (configurable only 4–8), and bounded per-device token buckets with TTL
  cleanup. Saturation/bursts return 429 with bounded `Retry-After`; body/batch
  limits return 413. MySQL uses one batched receipt lookup + one transaction for
  multi-row event/receipt inserts, unique raw-event ID index, and bounded race
  retry. Memory/MySQL preserve partial rejected/duplicate/accepted ACKs alike.
- Scheduled retention purges by trusted server `received_at` with time/row bounds
  while preserving receipts. Redis is a bounded best-effort recent-diagnostics cache;
  filtered/unavailable queries fall back to MySQL. It is not an ingest queue or
  authoritative metrics source.

Endpoint/environment/deployment details remain in the [Relay README](../../relay/README.md).
Route/crypto references: [Relay control-plane architecture](../../docs/architecture/RELAY_CONTROL_PLANE.md),
[SDK transport routing](../sdk/features/transport-routing.md),
[ADR-018](../../docs/adr/ADR-018-relay-direct-upgrade.md),
[ADR-017](../../docs/adr/ADR-017-candidate-exchange.md),
[ADR-008](../../docs/adr/ADR-008-direct-relay-race.md), and
[ADR-028](../../docs/adr/ADR-028-forward-secret-session-e2ee.md).

Backend validation commands and 90% coverage/contract gates are owned by
[Validation](../../.agents/skills/ssh-mobile-maintenance/references/validation.md)
and the Relay contract.
