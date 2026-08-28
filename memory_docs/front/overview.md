> Last updated: 2026-08-28

# Front Overview

`front/` is the standalone React, Vite, and TypeScript administration console
for the SSH Mobile control-plane, Relay service, and Telemetry & Observability suite.

It owns browser presentation, administrator interactions, and client-side API
integration. It does not own authentication policy, device enrollment, Relay
sessions, wire protocols, or network SDK behavior; those belong to `relay/`
and the SDK domain.

Maintained feature surfaces:
- Dashboard: active devices, relay connections, bandwidth, and presence.
- Devices: registered device catalog, online status, and revocation.
- Telemetry Suite:
  - Overview: ingest totals, error rates, device counts, and hourly trends.
  - Event Explorer: filterable audit log by event name, severity, feature, and device.
  - Diagnostics Stream: near-realtime diagnostic log feed backed by Redis Stream hot cache / MySQL.
  - Policy & Retention Settings: dynamic upload policy editor and data retention controls.

Start with:

- the [Front README](../../front/README.md);
- the [Front package manifest](../../front/package.json);
- the [Backend overview](../backend/overview.md) when an API or authentication contract changes;
- the [Telemetry ADR](../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md) for telemetry contracts and schema.

Administrator credentials, enrollment tokens, and sessions must not be stored
in browser storage or URLs. Use the Front README and code as the current-state
source rather than duplicating endpoint or polling details here.

## Validation gates

Run the Front checks from the `front/` directory:

```bash
npm run typecheck
npm run lint
npm run test:run
npm run build
```

The periodic Front coverage gate is independent from the daily full regression
gate and runs from the repository root:

```bash
bash scripts/bash/coverage/front_coverage.sh
```

It enforces the documented statements, lines, functions, and branches
thresholds for `front/src`, with each Vitest metric set to 90%.
