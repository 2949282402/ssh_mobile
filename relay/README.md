> Last updated: 2026-08-11

# SSH Mobile Control and Relay Server

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

This Go service provides SSH Mobile's memory-only device control plane and
WebSocket relay. The standalone React + Vite + TypeScript administration UI is
in `../front/` and is served by the `front` Compose service. Relay does not
embed or serve the dashboard UI. It does not persist transfer frames,
filenames, credentials, or device state. Restarting the process disconnects all
peers and requires devices to enroll again.

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
| `RELAY_CREDENTIAL_TTL` | Device credential lifetime, using Go duration syntax |
| `RELAY_SESSION_TTL` | Relay session lifetime, using Go duration syntax |
| `RELAY_ADMIN_SESSION_TTL` | Dashboard administrator session lifetime, using Go duration syntax |
| `RELAY_MAX_CONNECTIONS` | Positive maximum number of Relay connections |
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

## Security model

- Enrollment accepts protocol version 1 and binds a credential to the device
  ID and Ed25519 public key.
- Authenticated WebSocket requests sign the HTTP method, path, and a fresh
  32-byte nonce. Replayed nonces are rejected.
- Credentials are accepted only while the matching device enrollment exists in
  the current process. Revocation closes an active socket immediately.
- Browser WebSocket upgrades use the standard same-origin policy. Native
  clients without an `Origin` header remain supported.
- Dashboard API routes require an authenticated HttpOnly-cookie session. The
  front-end renders dynamic device data through React text nodes and loads no
  external scripts or fonts.
- Caddy applies restrictive framing, content-type, referrer, and content
  security headers.

Because device state is intentionally memory-only, restart is a security
boundary: all clients must enroll again.

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

Admin HTTP failures use a separate versioned error shape:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Administrator authentication failed."
  }
}
```

The admin API currently uses an in-memory HttpOnly session. CSRF header
binding, origin/fetch-metadata validation, and login rate limiting are planned
for the next security phase.

The service rejects unsupported protocol versions and does not provide a v1
compatibility fallback, a `/v1/control` route, or a Dart-side Relay data path.

## WebSocket protocol v1

- The server sends `{"type":"ready","protocol_version":1,"device_id":"..."}`
  after authentication and hub admission. Clients must not report a connection
  before validating this frame.
- `heartbeat` receives `heartbeat_ack`. Transfer control types are `offer`,
  `accept`, `resume`, `complete`, `complete_ack`, and `cancel`.
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
go vet ./...
go test ./...
```
