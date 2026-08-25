> Last updated: 2026-08-25

# SSH Mobile Control and Relay Server

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

This Go service provides SSH Mobile's device control plane and WebSocket
relay. By default it is memory-only: no external storage, and restarting the
process disconnects all peers and requires devices to enroll again. With
`RELAY_STORAGE_MODE=mysql` (which requires `RELAY_REDIS_URL`) enrollment and
revocation are durable across a restart, and the shared presence/nonce/
administrator-session/event layer is active for the multi-instance design. The
standalone React + Vite + TypeScript administration UI is in `../front/` and is
served by the `front` Compose service. Relay does not embed or serve the
dashboard UI. It does not persist transfer frames or filenames, and never reads
device private keys or credential plaintext.

## `.env` configuration

All Compose deployment parameters come from `relay/.env`. The server fails
closed when a required secret is missing or weak; Compose also requires every
port, limit, duration, and image value to be present in that file.

| Variable | Requirement |
|---|---|
| `RELAY_PUBLIC_DOMAIN` | Public DNS name, or an explicit local `http://` address for local smoke testing |
| `RELAY_PUBLIC_URL` | Public Relay origin advertised in `RelayReserveResponse.relay_data_endpoint`; HTTPS is published as WSS, an explicit WSS origin is preserved, and HTTP/WS is accepted only on loopback for integration tests |
| `RELAY_HTTP_PORT` | Host port for Caddy HTTP |
| `RELAY_HTTPS_PORT` | Host port for Caddy HTTPS |
| `RELAY_CADDY_IMAGE` | Caddy image and version, normally `caddy:2.8-alpine` |
| `CADDY_HTTP_PORT` | Caddy's internal HTTP listener port |
| `CADDY_HTTPS_PORT` | Caddy's internal HTTPS listener port |
| `RELAY_INTERNAL_PORT` | Internal Go Relay listener port |
| `FRONT_INTERNAL_PORT` | Internal Nginx front-end listener port |
| `RELAY_STORAGE_MODE` | Device-plane storage backend: `memory` (default, process-local) or `mysql` (durable enrollment/revocation; requires Redis) |
| `RELAY_DATABASE_URL` | MySQL DSN (requires `parseTime=true` and UTC location semantics; canonical form uses `loc=UTC`), required when `RELAY_STORAGE_MODE=mysql` |
| `RELAY_REDIS_URL` | Redis URL for the shared state layer (presence, nonce, admin sessions, cross-instance events); required when `RELAY_STORAGE_MODE=mysql` |
| `RELAY_REDIS_PASSWORD` | Independent Redis password, at least 16 characters and required when `RELAY_STORAGE_MODE=mysql` |
| `MYSQL_ROOT_PASSWORD` | MySQL root password for the optional Compose `storage` profile |
| `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` | Database and application credentials used by the optional Compose `storage` profile |
| `RELAY_INSTANCE_ID` | Stable per-instance identity recorded in presence; defaults to a random value per process |
| `RELAY_PRESENCE_TTL` | Presence key lifetime (device heartbeat renews it); default `60s` |
| `RELAY_CREDENTIAL_TTL` | Device credential lifetime, using Go duration syntax |
| `RELAY_ADMIN_SESSION_TTL` | Dashboard administrator session lifetime, using Go duration syntax |
| `RELAY_MAX_CONNECTIONS` | Positive maximum number of Relay connections |
| `RELAY_MAX_ENROLLED_DEVICES` | Maximum number of enrolled devices held in memory |
| `RELAY_MAX_REVOKED_DEVICES` | Maximum number of revocation tombstones held in memory; new revocations fail closed at capacity |
| `RELAY_MAX_TRANSFER_SESSIONS` | Maximum number of active transfer sessions held in memory |
| `RELAY_MAX_PENDING_FRAMES_PER_DEVICE` | Maximum queued outbound frames per device |
| `RELAY_MAX_PENDING_BYTES_PER_DEVICE` | Maximum queued outbound bytes per device |
| `RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE` | Maximum inbound frames per device per second |
| `RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE` | Maximum inbound bytes per device per second |
| `RELAY_MAX_ADMIN_SESSIONS` | Maximum active administrator sessions held in memory |
| `RELAY_ADMIN_LOGIN_MAX_ATTEMPTS` | Login attempts allowed per IP and username window |
| `RELAY_ADMIN_LOGIN_WINDOW` | Administrator login limiter window, using Go duration syntax |
| `RELAY_ADMIN_LOGIN_BLOCK` | Administrator login block duration, using Go duration syntax |
| `RELAY_MAX_ADMIN_LOGIN_ENTRIES` | Maximum IP/username limiter entries held in memory |
| `RELAY_HTTP_READ_TIMEOUT` | HTTP request read timeout, using Go duration syntax |
| `RELAY_HTTP_WRITE_TIMEOUT` | HTTP response write timeout, using Go duration syntax |
| `RELAY_HTTP_IDLE_TIMEOUT` | HTTP keep-alive idle timeout, using Go duration syntax |
| `RELAY_HTTP_MAX_HEADER_BYTES` | Maximum HTTP request header bytes |
| `RELAY_TRUSTED_PROXY_CIDRS` | Comma-separated trusted immediate-proxy CIDRs; empty (default) ignores client-IP forwarding headers and `X-Forwarded-Proto` |
| `RELAY_NETWORK_SUBNET` | Optional Compose IPv4 subnet override for an isolated test project; defaults to `172.30.0.0/24` |
| `RELAY_CADDY_IP` | Optional static Caddy address inside that subnet; defaults to `172.30.0.10` and must match the trusted-proxy CIDR |
| `RELAY_ENROLLMENT_TOKEN` | Random enrollment secret, at least 16 characters |
| `RELAY_CREDENTIAL_KEY` | Base64url-encoded random key containing at least 32 bytes |
| `RELAY_ADMIN_USER` | Dashboard administrator username |
| `RELAY_ADMIN_PASSWORD` | Random dashboard password, at least 12 characters |

Compose derives the Go `RELAY_ADDR` from `RELAY_INTERNAL_PORT`; direct
standalone Go execution may set `RELAY_ADDR` separately. Never commit real
values. Generate independent secrets with a cryptographically secure generator.
Unset positive limits use documented finite defaults; an explicitly empty,
malformed, zero, or negative duration/limit fails configuration instead of
silently changing the deployment boundary.

`RELAY_PUBLIC_URL` is an HTTP edge origin, not a literal data-socket scheme:
`https://relay.example` is normalized to `wss://relay.example`, while a
loopback `http://127.0.0.1:<port>` test origin becomes `ws://127.0.0.1:<port>`.
Non-root paths (a trailing `/` is normalized away), queries, fragments,
embedded credentials, non-loopback HTTP/WS, and loopback HTTPS/WSS are rejected
so reservation tokens are never published to an attacker-selected or ambiguous
endpoint.

Redis client safety bounds are process-owned and cannot be weakened by query
parameters in `RELAY_REDIS_URL`: context cancellation is enabled, automatic
command retries are disabled, dial/read/write and pool-wait timeouts are each
2 seconds, and both pool size and maximum active connections are capped at 64.
Operation-specific caller deadlines remain the tighter bound where applicable.

## Docker Compose production deployment

Docker Compose is the only supported deployment path. The supplied topology
keeps Caddy/Front on the edge network and MySQL/Redis on a separate internal
state network that only Relay joins. Redis requires authentication and uses
`noeviction`, so memory pressure rejects state writes and Relay fails closed
instead of silently dropping nonce or administrator-session security state.
Caddy continues to own HTTPS/WSS termination and same-origin routing.

1. Point a public DNS `A` or `AAAA` record at the host and allow ports 80/443.
2. Copy `.env.example` to `.env` and replace every value, including ports,
   runtime limits, and administrator credentials:

   ```sh
   cp .env.example .env
   ```

   PowerShell:

   ```powershell
   Copy-Item .env.example .env
   ```

3. Build, start, and follow the deployment logs:

   ```sh
   docker compose --env-file .env up --build
   ```

   This single command attaches the combined `caddy`, `front`, and `relay` logs.

Caddy persists certificate state only. Do not add a relay data volume or
publish the internal Go port directly to the public internet.

Caddy terminates HTTPS/WSS and reverse-proxies to the Relay on the internal
network. The bundled Compose file gives the Caddy container a static internal
address (`172.30.0.10`) and `RELAY_TRUSTED_PROXY_CIDRS` defaults to that
address so the Relay honors Caddy's forwarded headers for per-client login
rate limiting. If you change the internal subnet, update
`RELAY_TRUSTED_PROXY_CIDRS` to match. To run the Relay without a trusted proxy
in front, set `RELAY_TRUSTED_PROXY_CIDRS=` (empty); forwarded headers are then
ignored entirely. The same immediate-peer boundary governs
`X-Forwarded-Proto`: only direct TLS or `https` reported by a trusted proxy can
set an administrator cookie's `Secure` attribute or make the admin Origin check
use the HTTPS scheme. An untrusted peer cannot spoof the scheme to change cookie
or same-origin decisions.

## Security model

- Enrollment accepts protocol version 1 and binds a credential to the device
  ID and Ed25519 public key.
- Authenticated v2 WebSocket requests carry a canonical positive Unix-seconds
  `X-Relay-Timestamp` and a fresh 32-byte nonce. Their Ed25519 proof signs
  `GET\n<path>\n<timestamp>\n<nonce>` exactly, with no trailing newline;
  replayed nonces and proofs outside the inclusive ±300-second window are
  rejected.
- Credentials are accepted only while the matching durable enrollment and
  enrollment generation remain current. Revocation closes active Control and
  RelayData sockets, including an active data counterpart, immediately.
- Browser WebSocket upgrades use the standard same-origin policy. Native
  clients without an `Origin` header remain supported.
- Dashboard API routes require an authenticated HttpOnly-cookie session. Every
  state-changing administrator request rejects cross-site Origin or Fetch
  Metadata values; requests carrying a body must use `application/json`. Login
  attempts are rate-limited per client IP and username and return a generic
  response with a bounded `Retry-After` hint.
- The login limiter trusts the immediate peer's `RemoteAddr` by default and
  ignores `X-Forwarded-For`/`X-Real-IP`. Client-IP forwarding headers and
  `X-Forwarded-Proto` are honored only when that peer is inside an explicitly
  configured `RELAY_TRUSTED_PROXY_CIDRS` boundary. This prevents direct clients
  from rotating source headers to evade the limiter or spoofing HTTPS for
  administrator cookie and Origin policy.
- The front-end renders dynamic device data through React text nodes and loads
  no external scripts or fonts.
- Caddy applies restrictive framing, content-type, referrer, and content
  security headers.

In the default `memory` mode, device state is intentionally process-local, so
restart is a security boundary: all clients must enroll again. In `mysql` mode
enrollment and revocation persist, so a restart no longer clears them; treat the
database credentials and the durable enrollment data as sensitive state.

## Endpoints

- `GET /`: front-end SPA through Caddy; the Go Relay has no embedded dashboard
- `POST /api/admin/v1/auth/login`: dashboard administrator login
- `POST /api/admin/v1/auth/logout`: dashboard administrator logout
- `GET /api/admin/v1/auth/session`: current administrator session status
- `GET /api/admin/v1/overview`: authenticated runtime and relay overview
- `GET /api/admin/v1/devices`: authenticated device registry snapshot
- `POST /api/admin/v1/devices/{deviceId}/revoke`: authenticated device revocation
- `GET /api/admin/v1/access/enrollment-token`: authenticated enrollment-token read
- `POST /api/admin/v1/access/enrollment-token/rotate`: authenticated process-local
  token rotation in `memory` mode; durable `mysql` deployments receive `409`
  and must rotate `RELAY_ENROLLMENT_TOKEN` for every instance before restart
- Legacy `/api/*` dashboard routes are removed; they are not compatibility aliases.
- `POST /v1/devices/enroll`: device credential enrollment endpoint
- `POST /v1/devices/refresh`: re-issue a short-lived credential for an
  enrolled device, without requiring the enrollment token
- `GET /v2/control`: authenticated long-lived control WebSocket
- `GET /v2/relay/{reservation_id}`: authenticated reservation-scoped opaque
  data WebSocket
- There is no `/v1/connect` route. Transport traffic is v2-only and uses the
  physically separate control and data WebSockets above.
- `GET /healthz`: health check (`204`)

Device HTTP failures use the stable v1 network error shape and never expose
raw server errors:

```json
{
  "code": 8,
  "message": "safe diagnostic",
  "operation": "connect_relay",
  "peer_id": "optional-device-id"
}
```

Device-plane errors may optionally carry a retry policy:
`retry_disposition` is one of `0` unspecified, `1` no_retry, `2`
retry_with_backoff, `3` retry_after, `4` refresh_credential_then_retry; when
`retry_disposition=3`, `retry_after_seconds` carries the delay. Both fields are
omitted when unspecified so existing clients remain backward-compatible.

Stable codes beyond the base set are:
- `12` credential expired. The connect path returns `401` with
  `retry_disposition=4` (refresh the credential, then retry); all other auth
  failures remain `2`.
- `13` device identity conflict. Enrolling an existing `device_id` with a
  different public key returns `409` and leaves the existing enrollment (and
  any active socket) untouched; same-key re-enrollment still succeeds and
  refreshes the credential TTL.
- Enroll `429` (device capacity) sets the HTTP `Retry-After: 30` header and
  emits `retry_disposition=3` with `retry_after_seconds=30`.

`POST /v1/devices/refresh` accepts
`{device_id, public_key, timestamp, nonce, signature}` and returns the same
shape as enroll (`{credential, expires_at, server_time, protocol_version}`).
`timestamp` is a required signed 64-bit Unix-seconds integer. The Ed25519
signature covers the exact transcript
`POST\n/v1/devices/refresh\n<timestamp>\n<nonce>` with no trailing newline.
Relay accepts both inclusive clock-skew boundaries (`server_time - 300 <=
timestamp <= server_time + 300`); a missing or non-positive timestamp returns `400`
`invalidArgument`, while a stale or future proof returns `401`
`authenticationFailed`. The 32-byte nonce is consumed once and expires at the
signed timestamp plus 301 seconds, with at most 128 live nonces per device. A
replay-protection cache failure returns `503` with `retry_with_backoff` and
never issues a credential. Same-key re-enrollment does not clear consumed
device-proof nonces, so it cannot reopen a refresh or WebSocket signature
inside the freshness window. There is no legacy transcript fallback. An unknown
`device_id` with a fresh request returns `404` with code `1` and tells the
client to re-enroll; the refresh endpoint never issues the enrollment token.

Both `GET /v2/control` and `GET /v2/relay/{reservation_id}` require
`X-Relay-Timestamp`, `X-Relay-Nonce`, and `X-Relay-Signature`. The timestamp is
a canonical positive Unix-seconds decimal, and the signature covers the exact
transcript `GET\n<path>\n<timestamp>\n<nonce>` without a trailing newline.
Relay accepts both inclusive ±300-second boundaries and consumes the nonce
until the signed timestamp plus 301 seconds. A missing, malformed, stale, or
future timestamp, a replay, or an unavailable replay-protection cache returns
`401` `authenticationFailed` and never upgrades the socket. Control and
RelayData build independent proofs; the retired timestamp-less transcript has
no fallback ([ADR-031](../docs/adr/ADR-031-relay-refresh-proof-freshness.md)).

Admin HTTP failures use a separate versioned error shape:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Administrator authentication failed."
  }
}
```

The admin API uses an HttpOnly session stored in the cache layer: memory mode
uses the process-local cache, while the MySQL composition uses Redis.
Administrator sessions, enrolled devices, revocation tombstones, transfer
sessions, pending per-device output, and login limiter entries are all bounded
by the `RELAY_MAX_*` settings above. In memory mode, replay-proof nonce buckets
use an earliest-expiry heap with bounded lazy cleanup: active windows survive
re-enrollment/revocation, while expired historical device buckets converge
without a whole-cache scan.
Revocation tombstones are also credential-expiry-aware: a tombstone is kept only
while the revoked device's current credential could still be presented, and once
the bounded memory store is saturated with still-in-force tombstones, new
revocations fail closed instead of evicting an older one. In `memory` mode every
entry is cleared on restart; in `mysql` mode enrolled devices and revocation
tombstones are durable. The configured enrollment secret always remains the
process configuration value.

The Go HTTP server applies read, write, and idle timeouts plus a bounded
request-header size. Shutdown is signal-driven: HTTP graceful shutdown (up to
15s) is followed by one 10s total Relay runtime budget. RelayData, Control/Hub,
and event reconciliation converge concurrently; Cache and Storage then close
concurrently inside whatever remains of that same budget. The Hub has a 5s
sub-budget, RelayData has a 5s graceful-plus-forced sub-budget, and queued
RelayDataClose frames get a 2s drain window before sockets are force-closed. A
dependency that ignores cancellation cannot make `Server.Close` unbounded. The
Compose relay service sets `stop_grace_period: 30s`, which
exceeds the full 25s shutdown budget so Docker does not SIGKILL the process
mid-sequence. MySQL and Redis startup similarly share one 15s total deadline.

The service rejects unsupported protocol versions and does not provide a v1
compatibility fallback, a `/v1/control` route, or a Dart-side Relay data path.

## Transport WebSockets

Transport traffic is v2-only. `/v2/control` carries authenticated protobuf
`RelayFrame` messages for control, discovery, signaling, and reservations;
`/v2/relay/{reservation_id}` carries only reservation-scoped `RelayDataFrame`
messages with opaque encrypted payloads. The two routes have separate writers,
admission rules, and lifetimes; a data frame on the control route (or a control
frame on the data route) is a protocol violation.

Each physical WebSocket independently authenticates with the timestamped
four-part proof described above. Sharing the Rust request builder does not
share a nonce, timestamped proof, socket, queue, or rate budget between Control
and RelayData.

After proof authentication, both routes use one 5s device-security admission
deadline across the per-device stripe wait, durable enrollment check, WebSocket
upgrade, non-routable registry staging, second durable enrollment/lease check,
and activation. The staged worker barrier prevents Ready, PairReady, or client
traffic from crossing a failed post-registration check; the stripe is released
as soon as the endpoint becomes reachable so a long-lived socket never blocks
revoke or re-enrollment.

Relay Data implementation ownership is explicit: `reservation.go` owns the
reservation model and memory/Redis TTL storage; `relay_data_admission.go` owns
authenticated device/role/token binding before upgrade; `relay_data_registry.go`
owns one-shot role slots, pairing, revocation, and shutdown indexing; and
`relay_data_connection.go` owns the socket pump and Ping/Pong liveness.
`relay_data_flow_budget.go` independently owns outbound backlog accounting and
the inbound rate window. The pump borrows only narrow reservation-lease and
pair-owner interfaces.

## Network Protocol v2 Relay contract

The v2 control/data wire contract is frozen at baseline commit
`6ec194bb3a66a748215d3abc11d6da84bd329619`; its schema and golden fixtures are
owned by [`protocol/RELAY_V2_CONTRACT.md`](../protocol/RELAY_V2_CONTRACT.md).
The v2 transport boundary is separate from the `/v1/devices/*` credential
endpoints; `/v1/connect` is not registered:

- `ConnectivityOffer` has no `target_device_id`. It is accepted only after a
  successful `ResolvePeerRequest`/READY response on the same long-lived control
  connection (Resolve → Offer gate). The gate is not held across the answer or
  direct-probe work. A successfully queued Offer also creates a separate,
  bounded 30-second fallback gate bound to that initiator connection,
  `attempt_id`, target device, and target connection; `RelayReserveRequest`
  consumes it once and must match every binding. Attempt and gate expiry use
  exact removable min-heaps, so an ordinary Offer never scans the bounded
  65,536-entry registries while holding the Hub lock. The authoritative Offer
  is also encoded before that lock; inside it the Relay only revalidates exact
  connection owners, commits the indexes, and performs a non-blocking enqueue.
- `RealtimeSignal` retains `target_device_id` and has no
  `sender_device_id`. The receiving runtime obtains the remote identity from
  its established realtime session binding and fails closed for an unknown
  binding.
- `RelayDataFrame` contains `RelayDataConnect`, `RelayDataPayload`,
  `RelayDataAck`, and `RelayDataClose`. There is no `RelayDataReady` protobuf
  message and no `ready` oneof field.
- After both role-specific Connect frames are admitted, PairReady is exactly
  one WebSocket Ping with payload
  `ssh-mobile-relay-paired-v1:<reservation_id>`. It is not a protobuf frame;
  both writer queues must accept their marker before the registry commits the
  pair, and each endpoint remains unable to forward data until its own marker
  has actually been written. Receiver FIFO ordering keeps PairReady ahead of
  any payload. The server's 30 s Ping / 15 s Pong liveness uses the same single
  outbound writer but a distinct `ssh-mobile-relay-keepalive-v1` marker, so a
  keepalive can never be interpreted as a second PairReady.
- A same-role retry replaces an unpaired endpoint. A retry against an active
  pair invalidates and closes both old roles, becomes the first endpoint of a
  fresh pending pair, and requires the counterpart to reconnect before a new
  one-shot PairReady can be sent. An ordinary disconnect instead terminates the
  consumed reservation; later endpoints must obtain a new reservation rather
  than reuse its tokens.
- Reservation TTL controls pending admission only. An active data pair remains
  alive across reservation expiry and natural credential expiry; explicit
  device revocation atomically terminalizes pending endpoints, active endpoints,
  and the counterpart under the registry forwarding lock. Queued business
  frames are discarded, and revocation waits for any already-started socket
  write before returning. Protobuf encoding and allocation of the opaque frame
  happen before that lock; the critical section only rechecks state, reserves
  flow budget, and performs a non-blocking queue handoff.
- The device-scoped DiscoveryPublish fan-out budget survives reconnect and
  same-key re-enrollment. Its bounded-map slot is released only after a durable
  revoke/delete succeeds locally or an event/reconciliation read confirms that
  the durable enrollment is absent; delayed old-generation events cannot reset
  the current enrollment's budget.

Run `bash scripts/bash/contracts/relay_v2_contract.sh` to check the 22 frozen fixtures without
mutating the worktree. If `protoc` is unavailable, the script prints `NOT RUN` for descriptor
equality; that local result does not claim the complete descriptor gate passed.

## Validation

```sh
go fmt ./...
go test ./...
go test -race ./...
go vet ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
```

From the repository root, run `bash scripts/bash/contracts/admin_api_contract.sh` to verify
that responses emitted by the real Go administrator handlers still satisfy the
production Front request client and Zod schemas. The runtime fixture is written
only to a private temporary directory, redacts credentials, and is never
committed.

### Network v2 Phase 0 contract matrix

From the repository root, run the non-mutating characterization matrix for
the committed Relay v2 fixtures and cross-owner evidence inventory:

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh baseline
```

The strict entry point additionally runs the owning Rust and Go selectors and
fails while any matrix case is still `characterized` or `gap`:

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh strict
```

The baseline is not a claim that final acceptance is complete; the open cases
remain recorded in `protocol/contract_tests/acceptance_matrix.json`.

### Real client—Relay E2E

Component and contract tests, local Rust/in-memory integration tests, and a
real client—Go Relay deployment are separate evidence layers. The last layer
starts the Flutter/Dart and Rust clients as independent processes, routes them
through Caddy, and exercises the Go Relay's `/v1` enrollment/refresh,
`/v2/control`, and `/v2/relay/{reservation_id}` paths. A real Android/iOS
device-network run remains a separate physical-device validation.

From the repository root, use the WSL/Linux entry point:

```sh
bash scripts/bash/e2e/client_backend_e2e.sh smoke
bash scripts/bash/e2e/client_backend_e2e.sh strict
bash scripts/bash/ci/full_test.sh --with-client-backend-smoke --no-bootstrap
```

`smoke` covers enrollment and refresh, two authenticated control clients,
discovery/resolve/offer/answer, realtime signaling, reservation admission,
opaque data payloads, ACK/close, and the Caddy `/v2` route guard. It prints
`CLIENT_BACKEND_SMOKE_PASS`. `strict` additionally uses a short credential TTL
to verify expiry → refresh → reconnect and restarts Caddy and Relay before
printing `CLIENT_BACKEND_STRICT_PASS`.

Each run creates a private temporary Compose project, enrollment token,
credential key, network subnet, and data directory. The exit trap removes the
containers, volumes, network, and temporary files; no credential is written to
`relay/.env` or retained in the repository. Set both
`CLIENT_BACKEND_E2E_BASE_URL` and `RELAY_ENROLLMENT_TOKEN` to test an already
running deployment instead of starting Compose. Strict mode's isolated Compose
path also logs in to the admin API, revokes an online device, and asserts that
its control and data sockets close. Set `CLIENT_BACKEND_E2E_STORAGE=mysql` to
enable the MySQL/Redis Compose profile and verify the durable storage wiring;
HTTPS/WSS with a trusted test CA remains a release-profile matrix case and can
be supplied for an external deployment with `CLIENT_BACKEND_E2E_CA_FILE`; the
same CA must also be installed in the WSL/Linux system trust store used by the
Dart and WSS SDK clients. Memory-mode HTTP smoke does not claim those paths.

The route guard is intentional: unauthenticated `/v2/control` and
`/v2/relay/*` requests must return Relay's JSON `401`, never the Front SPA's
`text/html` response. A legitimate WebSocket upgrade is exercised by the live
Rust SDK clients after enrollment.

### Storage integration tests

The MySQL/Redis integration tests (`TestMySQLStore*`, `TestRedisStore*`,
`TestMultiInstance*`) skip unless `RELAY_TEST_MYSQL_DSN` and
`RELAY_TEST_REDIS_URL` are set. Start throwaway stores and run them with:

```sh
docker run -d --rm --name relay-test-mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=relay \
  -e MYSQL_USER=relay -e MYSQL_PASSWORD=relay mysql:8.4
docker run -d --rm --name relay-test-redis -p 6379:6379 redis:7-alpine

RELAY_TEST_MYSQL_DSN='relay:relay@tcp(127.0.0.1:3306)/relay?parseTime=true&loc=UTC' \
RELAY_TEST_REDIS_URL='redis://127.0.0.1:6379/0' \
go test ./...
```

go-sql-driver handles MySQL 8's default `caching_sha2_password` auth (RSA
exchange) automatically, so the DSN needs no extra auth parameter. Note that
`compose.yaml`'s storage profile uses `expose:` only and does not publish the
ports, so a test process dialing `127.0.0.1` cannot reach those services — use
the `docker run -p` one-liners above or a dev compose override that adds
`ports:`.
