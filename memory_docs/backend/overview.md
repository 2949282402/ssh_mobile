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

Canonical operational and API documentation:

- [Relay README](../../relay/README.md)
- [Root Compose topology](../../compose.yaml)
- [Root Caddyfile](../../Caddyfile)
- [Backend current state](current-state.md)
- [Relay Bootstrap Protocol V2 Contract](../../protocol/RELAY_BOOTSTRAP_V2_CONTRACT.md)
- [Relay Protocol V2 Wire Contract](../../protocol/RELAY_V2_CONTRACT.md)
