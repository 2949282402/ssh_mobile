> Last updated: 2026-08-28

# SSH Mobile Control, Relay, and Admin Backend Services

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

This module contains two standalone Go services for SSH Mobile:

1. **Relay Backend** (`cmd/relay`, `internal/relay`):
   - Handles device bootstrap (V2 only: `POST /v2/devices/enroll`, `POST /v2/devices/refresh`).
   - Manages the long-lived protobuf V2 control plane (`GET /v2/control`) and reservation-scoped opaque data plane (`GET /v2/relay/{reservation_id}`).
   - Sole owner of device lifecycle, cryptographic credentials, presence, and durable MySQL/Redis storage.
   - Exposes authenticated internal management endpoints (`/internal/v2/*`) protected by `RELAY_INTERNAL_TOKEN`.

2. **Admin Backend** (`cmd/admin`, `internal/admin`):
   - Handles administrator authentication, memory session storage, and rate limiting.
   - Serves the public Admin REST API (`/api/admin/v1/*`) consumed by the React console in `front/`.
   - Communicates with Relay via `RelayManagementClient` over private HTTP (`/internal/v2/*`).
   - Holds no database, Redis, or device credential keys.

The React + Vite + TypeScript administration console is in `../front/` and is served as static assets by the `front` Compose service behind Caddy.

## Endpoints

### Relay Public Endpoints
- `GET /healthz` — Service liveness probe (returns 204 No Content).
- `POST /v2/devices/enroll` — Device enrollment with `protocol_version=2`.
- `POST /v2/devices/refresh` — Device credential refresh with Ed25519 signature proof over V2 transcript.
- `GET /v2/control` — Long-lived WebSocket control plane (`RelayFrame` protobuf).
- `GET /v2/relay/{reservation_id}` — Reservation-scoped WebSocket data plane (`RelayDataFrame` protobuf).

There is no `/v1/connect` route; only the V2 control and relay data routes are supported.

### Relay Internal Endpoints (`Authorization: Bearer <RELAY_INTERNAL_TOKEN>`)
- `GET /internal/v2/status` — Point-in-time runtime snapshot (goroutines, memory, active transfers, device count).
- `GET /internal/v2/devices` — List of enrolled devices with presence status.
- `POST /internal/v2/devices/{deviceId}/revoke` — Authoritative device revocation across storage and sockets.
- `GET /internal/v2/access/enrollment-token` — Active enrollment token.
- `POST /internal/v2/access/enrollment-token/rotate` — Rotates enrollment token (memory mode).
- `POST /internal/v2/telemetry/attest` — Attests an existing Relay device proof for Admin telemetry; returns no secret and writes no Analytics state.

### Admin Public Endpoints (`/api/admin/v1/*`)
- `POST /api/admin/v1/auth/login` — Administrator login (sets HttpOnly session cookie).
- `POST /api/admin/v1/auth/logout` — Administrator logout (clears session).
- `GET /api/admin/v1/auth/session` — Session authentication check.
- `GET /api/admin/v1/overview` — Relay status overview.
- `GET /api/admin/v1/devices` — Device listing and presence.
- `POST /api/admin/v1/devices/{deviceId}/revoke` — Revoke a device.
- `GET /api/admin/v1/access/enrollment-token` — View enrollment token.
- `POST /api/admin/v1/access/enrollment-token/rotate` — Rotate enrollment token.
- `GET /api/admin/v1/telemetry/overview` — Telemetry overview metrics and error distribution.
- `GET /api/admin/v1/telemetry/events` — Filterable telemetry event explorer.
- `GET /api/admin/v1/telemetry/diagnostics` — Real-time diagnostic stream from Redis/MySQL.
- `GET /api/admin/v1/telemetry/settings` — Read dynamic policy and retention settings.
- `PUT /api/admin/v1/telemetry/settings` — Update dynamic policy and retention settings.

### Telemetry Public Endpoints (`/api/v1/telemetry/*`)
- `POST /api/v1/telemetry/enroll` — Device proof-of-possession enrollment; returns a one-time telemetry secret and stores only its hash.
- `POST /api/v1/telemetry/enroll/rotate` — Explicit credential rotation bound to a fresh Relay proof.
- `POST /api/v1/telemetry/auth` — Client device authentication and short-lived token issuance.
- `GET /api/v1/telemetry/policy` — Fetch active dynamic upload policy.
- `POST /api/v1/telemetry/ingest` — Ingest batch events/diagnostics with HMAC and idempotency.

Telemetry ingest is bounded for the supported 2C4G deployment: request bodies
are limited to 1 MiB, batches to 100 records, and at most four database writer
operations run concurrently by default (the writer limit is clamped to 4–8).
Authenticated devices use bounded token-bucket admission with TTL cleanup; the
bucket key is the device identity bound by the verified bearer token, never a
body-supplied identity. A full writer gate or exhausted device bucket returns
`429 Too Many Requests` with a bounded integer `Retry-After` header and a
structured `INGEST_OVERLOADED` or `INGEST_RATE_LIMITED` error. Body and batch
limits return `413 Request Entity Too Large` before persistence. Optional
`TELEMETRY_MAX_*`, `TELEMETRY_RATE_LIMIT_*`, and
`TELEMETRY_RETRY_AFTER_SECONDS` variables tune these limits within their hard
bounds; see `.env.example`.

## Deployment

Deploy using the root Docker Compose file:

```sh
# Copy environment file
cp .env.example .env

# Start services
docker compose up -d --build
```
