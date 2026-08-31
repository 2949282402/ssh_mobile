> Last updated: 2026-08-31

# Front Overview

`front/` is the standalone React/Vite/TypeScript administration console for the
SSH Mobile control plane, Relay, and Telemetry suite. It owns browser
presentation, operator interactions, client routing, and client-side API integration—not
authentication policy, enrollment, Relay sessions, wire protocols, or SDK
behavior (Relay and SDK own those).

## UI Design System & Architecture

- **Visual Baseline**: Defined by `src/components/ui.tsx`, `src/styles.css`, and `src/layout/app-shell.tsx`. Overview, Devices, and Access serve as the core visual reference; all Telemetry views (Dashboard, Events, Diagnostics, Settings) strictly adhere to the same Design System.
- **Design Foundations**: IBM Plex Sans / IBM Plex Mono typography, canvas/paper surface elevation, restrained teal interactive accents, semantic status tones (`online`, `warning`, `danger`, `neutral`), 10px control radius, and 12-18px card/panel radii.
- **Component Ownership**:
  - `src/components/ui.tsx`: Generic, cross-feature Admin primitives (`Button`, `Badge`, `PageHeader`, `MetricTile`, `EmptyState`, `ErrorState`, `Pagination`, `CodeBlock`).
  - `src/features/<feature>/components/`: Feature-scoped reusable presentation (`TelemetryFilterPanel`, `TelemetryRecordCard`, `TelemetryTrendList`).
  - `src/features/<feature>/*-page.tsx`: Page assembly and route-level state orchestration.
- **Styling Policy**: Static presentation rules live in `src/styles.css`; dynamic data styles (e.g. calculated trend percentage widths) stay minimal in component logic. Form controls use `.form-control` / `.form-select` and never reuse `.button` classes.
- **Layering & State**: Directional dependency DAG (`Router/Layout -> Pages -> Feature Components/Shared Primitives/Hooks/Schemas`). Feature Components never execute raw HTTP. Server state belongs to TanStack Query; transient UI state belongs to local component state.

## Surfaces and Capabilities

- **Overview (`/overview`)**: Live Relay daemon snapshot (active devices, online peers, active sessions, memory/goroutine runtime metrics). Polled every 3 seconds.
- **Devices (`/devices`)**: Device registry catalog, presence badges, public endpoint inspection, and revocation confirmation dialog. Polled every 15 seconds.
- **Access (`/access`)**: Ephemeral Enrollment Token view (short-lived 30s cache, masked by default) and token rotation.
- **Telemetry Suite**:
  - **Overview Dashboard (`/telemetry`)**: Ingestion pipeline health, core business/session success rates, latency percentiles, delivery delay, and UTC hourly/daily trend bars.
  - **Event Explorer (`/telemetry/events`)**: Multi-tier filterable event stream with expandable technical metadata, error stack traces, and JSON property viewers.
  - **Diagnostic Stream (`/telemetry/diagnostics`)**: 5-second polling diagnostic feed with Redis hot cache / MySQL authoritative fallback indicators.
  - **Policy & Retention Settings (`/telemetry/settings`)**: Dynamic client upload thresholds, special trigger toggles, and server-side retention cleanup lifecycle parameters.

## Canonical Documents & Validation

- Complete design and architecture: [`docs/architecture/FRONT_ADMIN_UI_ARCHITECTURE.md`](../../docs/architecture/FRONT_ADMIN_UI_ARCHITECTURE.md)
- Workspace agent constraints: [`front/AGENTS.md`](../../front/AGENTS.md)
- Local workspace contract: [`front/README.md`](../../front/README.md)
- Front checks: `npm run typecheck`, `npm run typecheck:tests`, `npm run lint`, `npm run test:run`, `npm run build`.
