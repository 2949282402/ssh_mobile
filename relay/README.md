> Last updated: 2026-08-07

# SSH Mobile Control and Relay Server

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

This Go service provides SSH Mobile's memory-only device control plane and
WebSocket relay. It does not persist transfer frames, filenames, credentials,
or device state. Restarting the process disconnects all peers and requires
devices to enroll again.

## Required configuration

The server fails closed when any required secret is missing or weak:

| Variable | Requirement |
|---|---|
| `RELAY_ENROLLMENT_TOKEN` | Random enrollment secret, at least 16 characters |
| `RELAY_CREDENTIAL_KEY` | Base64url-encoded random key containing at least 32 bytes |
| `RELAY_ADMIN_USER` | Dashboard administrator username |
| `RELAY_ADMIN_PASSWORD` | Random dashboard password, at least 12 characters |

Optional variables are `RELAY_ADDR` (default `:8080`),
`RELAY_CREDENTIAL_TTL` (default `24h`), `RELAY_SESSION_TTL` (default `15m`),
and `RELAY_MAX_CONNECTIONS` (default `2048`).

Never commit real values. Generate independent secrets with a
cryptographically secure generator.

## Docker Compose production deployment

Docker Compose is the only supported deployment path. The supplied topology
keeps the Go service on an internal network and uses Caddy for HTTPS/WSS
termination.

1. Point a public DNS `A` or `AAAA` record at the host and allow ports 80/443.
2. Copy `.env.example` to `.env` and replace every placeholder:

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

   This single command attaches the combined `caddy` and `relay` logs because
   those are the only services in `compose.yaml`.

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
- Dashboard API routes require an authenticated HttpOnly-cookie session and
  dynamic device data is rendered with safe DOM APIs.
- Caddy applies restrictive framing, content-type, referrer, and content
  security headers.

Because device state is intentionally memory-only, restart is a security
boundary: all clients must enroll again.

## Endpoints

- `GET /`: dashboard and static assets
- `POST /api/login`, `POST /api/logout`, `GET /api/auth-status`: dashboard auth
- `GET /api/stats`: authenticated in-memory telemetry
- `POST /api/token/rotate`: authenticated enrollment-token rotation
- `POST /api/devices/revoke`: authenticated device revocation
- `POST /v1/devices/enroll`: protocol-v1 device enrollment
- `GET /v1/connect`: authenticated relay WebSocket
- No separate control WebSocket route is exposed; device traffic uses the v1
  authenticated Relay connection.
- `GET /healthz`: health check (`204`)

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
go test ./...
```
