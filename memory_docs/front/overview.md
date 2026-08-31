> Last updated: 2026-08-30

# Front Overview

`front/` is the standalone React/Vite/TypeScript administration console for the
SSH Mobile control plane, Relay, and Telemetry suite. It owns browser
presentation, administrator interactions, and client-side API integration—not
authentication policy, enrollment, Relay sessions, wire protocols, or SDK
behavior (Relay/SDK own those).

Surfaces: dashboard (active devices, Relay connections, bandwidth, presence),
devices (catalog/status/revocation), and Telemetry (overview totals/errors/device
counts/UTC trends; filterable event explorer; Redis-hot-cache diagnostics feed
with MySQL fallback; dynamic policy/retention settings).

Start with [Front README](../../front/README.md) and its manifest. API/auth
changes also read [Backend overview](../backend/overview.md); cross-layer
telemetry reads [telemetry design](../../docs/数据埋点架构.md) and
[ADR-033](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md).
Never store administrator credentials, enrollment tokens, or sessions in browser
storage or URLs; README/code own endpoint and polling details.

Front checks and coverage gates are selected from the canonical
[Validation Matrix](../../.agents/skills/ssh-mobile-maintenance/references/validation.md).
