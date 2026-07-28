> Last updated: 2026-07-28

# SSH Mobile Control & Relay Server

This service is a memory-only control plane and WebSocket relay for SSH Mobile's Network Transfer / P2P fallback. It does not persist transfer frames, filenames, or raw file contents. Devices receive signed credentials after enrollment; restarting the relay drops live sessions but does not expose file contents.

## Quick Start (Zero Config)

The server runs out of the box with zero required environment variables. Missing tokens and HMAC keys are automatically generated at startup and displayed in the Web Admin Dashboard.

```sh
cd relay
go run ./cmd/relay
```

Open `http://localhost:8080` in any browser to open the **Web Admin Dashboard**, view the auto-generated `Enrollment Token`, monitor live WebSocket connections, and manage enrolled devices.

## Standalone Docker

```sh
docker build -t ssh-mobile-relay relay
docker run --rm -p 8080:8080 ssh-mobile-relay
```

You can optionally pass custom environment variables if desired:

```sh
docker run --rm -p 8080:8080 \
  -e RELAY_ENROLLMENT_TOKEN='custom-admin-token' \
  ssh-mobile-relay
```

## Production Docker Compose Deployment

The supplied Compose deployment uses Caddy to terminate HTTPS/WSS and obtain a public TLS certificate automatically.

1. Create a public DNS `A` or `AAAA` record for the relay host, then allow TCP port 80 and the configured HTTPS port through the firewall. Keep port 80 mapped for Caddy's ACME HTTP validation; set `RELAY_HTTPS_PORT` in `.env` when clients should use a non-default HTTPS/WSS port.
2. Copy `.env.example` to `.env`; set the real DNS name and optional secrets.
3. Start the service:

   ```sh
   docker compose --env-file .env up --build -d
   docker compose logs -f caddy relay
   ```

The host exposes Caddy on ports 80/443; the Go relay stays on an internal Docker network. Caddy persists certificate state only. Do not add a relay data volume: sessions and relay frames are intentionally memory-only.

## Web Admin Dashboard & Endpoints

- **`GET /`**: Web Admin Dashboard (HTML/CSS/JS interface for monitoring active sessions, enrolled devices, and security credentials).
- **`GET /api/stats`**: Returns JSON telemetry (active peers, active sessions, system uptime, Go memory alloc, enrolled devices list).
- **`POST /api/token/rotate`**: One-click regeneration of the admin Enrollment Token.
- **`POST /api/devices/revoke`**: Revokes an enrolled device and forcibly closes its active WebSocket connection.
- **`POST /v1/devices/enroll`**: Device enrollment and credential issuance (requires `EnrollmentToken`).
- **`GET /v1/control`**: WebSocket control channel for heartbeat and peer presence notifications.
- **`GET /healthz`**: Returns `HTTP 204` health status.
