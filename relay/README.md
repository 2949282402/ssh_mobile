> Last updated: 2026-07-28

# SSH Mobile Control & Relay Server

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

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
2. Copy `.env.example` to `.env`:
   - Linux / macOS: `cp .env.example .env`
   - Windows PowerShell: `Copy-Item .env.example .env`
3. Start the service:

   ```sh
   docker compose --env-file .env up --build -d
   docker compose logs -f caddy relay
   ```

The host exposes Caddy on ports 80/443; the Go relay stays on an internal Docker network. Caddy persists certificate state only. Do not add a relay data volume: sessions and relay frames are intentionally memory-only.

## Detailed `.env` Configuration Guide

### 1. How to Copy `.env`

- **Linux / macOS Bash**:
  ```bash
  cd relay
  cp .env.example .env
  ```
- **Windows PowerShell**:
  ```powershell
  cd relay
  Copy-Item .env.example .env
  ```

### 2. Parameter Category Guide

| Parameter Name | Requirement | Default / Example | Description |
|---|---|---|---|
| `RELAY_PUBLIC_DOMAIN` | **MUST Modify** | `relay.example.com` | Public DNS domain name mapped to your server. **Do NOT include `http://` or `https://` prefix**. Caddy uses this domain to automatically request and renew SSL/TLS certificates via ACME. |
| `RELAY_ENROLLMENT_TOKEN` | **Optional** | (Auto-generated) | Admin secret required for new device enrollment. If left empty, a secure random token is generated at startup and shown in the Web Admin Dashboard. For production, set to your custom secret. |
| `RELAY_CREDENTIAL_KEY` | **Optional** | (Auto-generated) | Master HMAC key used to sign client credentials. Must be a base64url random string of at least 32 bytes. If left empty, automatically generated. |
| `RELAY_HTTPS_PORT` | **Optional** | `443` | External HTTPS / WSS port. If port 443 is already occupied on your host, change to another port (e.g., `8443`). |
| `RELAY_HTTP_PORT` | **Optional** | `80` | External HTTP port used by Caddy for ACME HTTP validation. |

### 3. Critical Rules & Guardrails (Do NOT Modify / Danger Zone)

1. ❌ **Do NOT commit the real `.env` file to source control**: Contains your real domain and secrets. `.env` is ignored by `.gitignore`.
2. ❌ **Do NOT add persistent data volumes to the relay container**: The relay is strictly **memory-only and stateless**. Persisting frames or logs to disk breaks security guarantees.
3. ❌ **Do NOT expose the Go backend port directly to the public internet**: The Go server listens on internal port `:8080` behind Caddy, which handles SSL/TLS termination and reverse proxy protection.

## Web Admin Dashboard & Endpoints

- **`GET /`**: Web Admin Dashboard (HTML/CSS/JS interface for monitoring active sessions, enrolled devices, and security credentials).
- **`GET /api/stats`**: Returns JSON telemetry (active peers, active sessions, system uptime, Go memory alloc, enrolled devices list).
- **`POST /api/token/rotate`**: One-click regeneration of the admin Enrollment Token.
- **`POST /api/devices/revoke`**: Revokes an enrolled device and forcibly closes its active WebSocket connection.
- **`POST /v1/devices/enroll`**: Device enrollment and credential issuance (requires `EnrollmentToken`).
- **`GET /v1/control`**: WebSocket control channel for heartbeat and peer presence notifications.
- **`GET /healthz`**: Returns `HTTP 204` health status.
