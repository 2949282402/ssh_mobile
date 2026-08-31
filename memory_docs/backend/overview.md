> Last updated: 2026-08-30

# Backend Overview

`relay/` contains two independent Go services deployed by root Compose:

- Relay (`cmd/relay`, `internal/relay`): V2 enrollment/refresh, `/v2/control`,
  `/v2/relay/*`, device lifecycle/credentials/presence, durable MySQL/Redis
  state, and authenticated `/internal/v2/*` management.
- Admin (`cmd/admin`, `internal/admin`): administrator auth/session/rate limit
  and `/api/admin/v1/*`; calls Relay through `RelayManagementClient` over
  `/internal/v2/*` and does not own Relay device/live-state DB or signing keys.
- Telemetry (`internal/telemetry`) is a logical module inside Admin, not a third
  service. It owns device auth/ingestion/policy (`/api/v1/telemetry/*`), admin
  overview/events/diagnostics/settings (`/api/admin/v1/telemetry/*`), isolated
  Analytics MySQL, optional Redis hot cache, and permanent ingest receipts.

Canonical operations/API: [Relay README](../../relay/README.md),
[Compose](../../compose.yaml), [Caddy](../../Caddyfile), [current state](current-state.md),
[telemetry design](../../docs/数据埋点架构.md), [ADR-033](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md),
[Bootstrap V2 contract](../../protocol/RELAY_BOOTSTRAP_V2_CONTRACT.md), and
[Relay V2 wire contract](../../protocol/RELAY_V2_CONTRACT.md).
