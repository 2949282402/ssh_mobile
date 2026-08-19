> Last updated: 2026-08-19

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
| `RELAY_HTTP_PORT` | Host port for Caddy HTTP |
| `RELAY_HTTPS_PORT` | Host port for Caddy HTTPS |
| `RELAY_CADDY_IMAGE` | Caddy image and version, normally `caddy:2.8-alpine` |
| `CADDY_HTTP_PORT` | Caddy's internal HTTP listener port |
| `CADDY_HTTPS_PORT` | Caddy's internal HTTPS listener port |
| `RELAY_INTERNAL_PORT` | Internal Go Relay listener port |
| `FRONT_INTERNAL_PORT` | Internal Nginx front-end listener port |
| `RELAY_STORAGE_MODE` | Device-plane storage backend: `memory` (default, process-local) or `mysql` (durable enrollment/revocation; requires Redis) |
| `RELAY_DATABASE_URL` | MySQL DSN (requires `parseTime=true&loc=UTC`), required when `RELAY_STORAGE_MODE=mysql` |
| `RELAY_REDIS_URL` | Redis URL for the shared state layer (presence, nonce, admin sessions, cross-instance events); required when `RELAY_STORAGE_MODE=mysql` |
| `RELAY_INSTANCE_ID` | Stable per-instance identity recorded in presence; defaults to a random value per process |
| `RELAY_PRESENCE_TTL` | Presence key lifetime (device heartbeat renews it); default `60s` |
| `RELAY_CREDENTIAL_TTL` | Device credential lifetime, using Go duration syntax |
| `RELAY_SESSION_TTL` | Relay session lifetime, using Go duration syntax |
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
| `RELAY_TRUSTED_PROXY_CIDRS` | Comma-separated trusted-proxy CIDRs; empty (default) never honors `X-Forwarded-For`/`X-Real-IP` for the login limiter |
| `RELAY_ENROLLMENT_TOKEN` | Random enrollment secret, at least 16 characters |
| `RELAY_CREDENTIAL_KEY` | Base64url-encoded random key containing at least 32 bytes |
| `RELAY_ADMIN_USER` | Dashboard administrator username |
| `RELAY_ADMIN_PASSWORD` | Random dashboard password, at least 12 characters |

Compose derives the Go `RELAY_ADDR` from `RELAY_INTERNAL_PORT`; direct
standalone Go execution may set `RELAY_ADDR` separately. Never commit real
values. Generate independent secrets with a cryptographically secure generator.

## Docker Compose production deployment

Docker Compose is the only supported deployment path. The supplied topology
keeps the Go service and the front-end container on an internal network and
uses Caddy for HTTPS/WSS termination and same-origin routing.

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
ignored entirely.

## Security model

- Enrollment accepts protocol version 1 and binds a credential to the device
  ID and Ed25519 public key.
- Authenticated WebSocket requests sign the HTTP method, path, and a fresh
  32-byte nonce. Replayed nonces are rejected.
- Credentials are accepted only while the matching device enrollment exists in
  the current process. Revocation closes an active socket immediately.
- Browser WebSocket upgrades use the standard same-origin policy. Native
  clients without an `Origin` header remain supported.
- Dashboard API routes require an authenticated HttpOnly-cookie session. Every
  state-changing administrator request rejects cross-site Origin or Fetch
  Metadata values; requests carrying a body must use `application/json`. Login
  attempts are rate-limited per client IP and username and return a generic
  response with a bounded `Retry-After` hint.
- The login limiter trusts the immediate peer's `RemoteAddr` by default and
  ignores `X-Forwarded-For`/`X-Real-IP`. Forwarding headers are honored only
  when that peer is inside an explicitly configured `RELAY_TRUSTED_PROXY_CIDRS`
  boundary, which prevents a direct deployment from rotating headers to evade
  the limiter.
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
- `POST /api/admin/v1/access/enrollment-token/rotate`: authenticated token rotation
- Legacy `/api/*` dashboard routes are removed; they are not compatibility aliases.
- `POST /v1/devices/enroll`: protocol-v1 device enrollment
- `POST /v1/devices/refresh`: re-issue a short-lived credential for an
  enrolled device, without requiring the enrollment token
- `GET /v1/connect`: authenticated relay WebSocket
- No separate control WebSocket route is exposed; device traffic uses the v1
  authenticated Relay connection.
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

`POST /v1/devices/refresh` accepts `{device_id, public_key, nonce, signature}`
and returns the same shape as enroll (`{credential, expires_at, server_time,
protocol_version}`). The Ed25519 signature covers the exact transcript
`"POST\n/v1/devices/refresh\n" + nonce`; the nonce is 32 bytes and is consumed
with the same per-device replay protection (max 128 live nonces, 5-minute TTL).
An unknown `device_id` returns `404` with code `1` and tells the client to
re-enroll; the refresh endpoint never issues the enrollment token.

Admin HTTP failures use a separate versioned error shape:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Administrator authentication failed."
  }
}
```

The admin API uses an HttpOnly session stored in the cache layer (memory by
default, Redis when `RELAY_REDIS_URL` is set). Administrator sessions, enrolled
devices, revocation tombstones, transfer sessions, pending per-device output,
and login limiter entries are all bounded by the `RELAY_MAX_*` settings above.
Revocation tombstones are also credential-expiry-aware: a tombstone is kept only
while the revoked device's current credential could still be presented, and once
the bounded memory store is saturated with still-in-force tombstones, new
revocations fail closed instead of evicting an older one. In `memory` mode every
entry is cleared on restart; in `mysql` mode enrolled devices and revocation
tombstones are durable. The configured enrollment secret always remains the
process configuration value.

The Go HTTP server applies read, write, and idle timeouts plus a bounded
request-header size. Shutdown is signal-driven: HTTP graceful shutdown (up to
15s) is followed by closing the in-memory Hub and waiting for its peer and
pruning goroutines to converge, bounded by a 5s hub-close budget. The Compose
relay service sets `stop_grace_period: 30s`, which exceeds the full 20s
shutdown budget so Docker does not SIGKILL the process mid-sequence.

The service rejects unsupported protocol versions and does not provide a v1
compatibility fallback, a `/v1/control` route, or a Dart-side Relay data path.

## WebSocket protocol v1

- The server sends `{"type":"ready","protocol_version":1,"device_id":"..."}`
  after authentication and hub admission. Clients must not report a connection
  before validating this frame.
- `heartbeat` receives `heartbeat_ack`. Transfer control types are `offer`,
  `accept`, `resume`, `complete`, `complete_ack`, and `cancel`.
- `crypto_handshake` is an additional bounded opaque control type for the
  Session's Noise XX application E2EE exchange; the Relay only validates the
  routing envelope and never parses Noise payloads or Session keys.
- The server removes client-supplied identity fields and adds the authenticated
  `sender_id` to every forwarded transfer control frame.
- A 32-character lowercase hexadecimal `session_id` identifies one in-memory
  transfer. Only the sender may offer, stream binary chunks, and complete; only
  the receiver may accept, resume, and acknowledge completion. Either side may
  cancel.
- Binary frames use a 25-byte header: one kind byte (`0x10`), 16 session bytes,
  and an unsigned 64-bit big-endian sequence, followed by opaque ciphertext.
- Sending all bytes is not success. The sender reports success only after the
  receiver validates the transfer and returns `complete_ack`.

## Validation

```sh
go fmt ./...
go test ./...
go test -race ./...
go vet ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
```

### Network v2 Phase 0 contract matrix

From the repository root, run the non-mutating characterization matrix for
the committed Relay v2 fixtures and cross-owner evidence inventory:

```sh
bash scripts/network_v2_acceptance.sh baseline
```

The strict entry point additionally runs the owning Rust and Go selectors and
fails while any matrix case is still `characterized` or `gap`:

```sh
bash scripts/network_v2_acceptance.sh strict
```

The baseline is not a claim that final acceptance is complete; the open cases
remain recorded in `protocol/contract_tests/acceptance_matrix.json`.

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
