> Last updated: 2026-08-27

# Backend Overview

`relay/` contains the Go Backend services for SSH Mobile, structured as two independent services:

1. **Relay Backend** (`cmd/relay`, `internal/relay`):
   - Owns V2 device bootstrap (`/v2/devices/enroll`, `/v2/devices/refresh`).
   - Owns long-lived V2 control plane (`/v2/control`) and data plane (`/v2/relay/*`).
   - Owns device lifecycle, credentials, presence, and durable MySQL/Redis state.
   - Exposes authenticated internal management API (`/internal/v2/*`).

2. **Admin Backend** (`cmd/admin`, `internal/admin`):
   - Owns administrator authentication, session store, rate limiter, and public REST API (`/api/admin/v1/*`).
   - Communicates with Relay via `RelayManagementClient` over private HTTP (`/internal/v2/*`).
   - Holds no database, Redis, or signing keys.

3. **Telemetry & Observability Pipeline** (`internal/telemetry`):
   - Owns public device telemetry ingestion, HMAC verification, device auth, and dynamic policy (`/api/v1/telemetry/*`).
   - Owns admin telemetry query endpoints (`/api/admin/v1/telemetry/*`: overview, events, diagnostics stream, settings).
   - Dedicated persistence: isolated Analytics MySQL schema and optional Redis Stream cache for live diagnostic logs.
   - Permanent idempotency receipts (`telemetry_ingest_receipts`) immune to retention purge.
   - Decoupled observability architecture adhering to [ADR-033](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md).

Canonical operational and API documentation:

- [Relay README](../../relay/README.md)
- [Root Compose topology](../../compose.yaml)
- [Root Caddyfile](../../Caddyfile)
- [Backend current state](current-state.md)
- [Telemetry Architecture ADR](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md)
- [Relay Bootstrap Protocol V2 Contract](../../protocol/RELAY_BOOTSTRAP_V2_CONTRACT.md)
- [Relay Protocol V2 Wire Contract](../../protocol/RELAY_V2_CONTRACT.md)
