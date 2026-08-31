> Last updated: 2026-08-31

# Front Workspace Agent Constraints

## Ownership and boundaries

`front/` is the standalone React + Vite + TypeScript browser control plane for the SSH Mobile Relay and Telemetry administration console.

### Front owns:
- Browser presentation and user interactions.
- SPA client routing and navigation shell (`src/layout/`).
- Client API adapters and HTTP request layer (`src/api/`).
- Zod schema DTO validation contracts (`src/schemas/`).
- Server query caching and mutation lifecycle orchestration (`src/hooks/`).
- Page-local and component-transient UI state (`useState`, local refs).
- Control plane accessibility (semantic HTML, keyboard navigation, ARIA).
- Responsive layouts and media breakpoints (`1100px`, `900px`, `760px`).

### Front does NOT own:
- Authentication policy and credential verification (Relay owns).
- Relay session lifecycle, bandwidth limits, and proxy forwarding.
- Wire protocols, packet codecs, and encryption handshakes (SDK/Relay own).
- Telemetry event definitions, taxonomy, and catalog contracts (Telemetry protocol owns).
- Server-side retention, data purging, and database execution (Relay owns).
- Device enrollment tokens, public key identity, and presence discovery (Relay owns).
- Native SDK behavior and transport drivers (SDK owns).

## React layer architecture

Front code is structured as a directional dependency DAG with strict layer boundaries:

```text
App / Router
├── Layout
└── Feature Pages
    ├── Feature Components
    │   ├── Shared UI Primitives
    │   └── Schema Types
    ├── Shared UI Primitives
    ├── Query Hooks
    │   ├── API Adapters
    │   ├── Query Keys
    │   └── Schema Types
    └── Schema Types

API Adapters
├── HTTP Client
├── Canonical Routes
└── Zod Schemas
```

- **Feature pages** assemble feature components and shared primitives, and bind query hooks; pages must not execute raw `fetch()` or construct unvalidated API calls directly.
- **Feature components** are presentation-only, importing shared UI primitives and schema types; they never perform direct HTTP requests or import hooks/API adapters.
- **Shared UI primitives** (`src/components/ui.tsx`) remain strictly feature-agnostic and never depend on feature components, pages, hooks, or schemas.
- **Query hooks** encapsulate TanStack Query caching, polling intervals, query keys (`src/api/query-keys.ts`), and error normalization (`ApiRequestError`).
- **API adapters** encapsulate the typed HTTP request layer, error handling, and canonical routes with Zod schemas.
- **Strict Invariants**: Lower layers never reverse-depend on or import from upper layers. Server state is exclusively managed by TanStack Query; page-transient state (search drafts, expanded cards, modal open state) is managed by local component state (`useState`, local refs). Never duplicate server cache into secondary global state stores.

## UI design system and styling rules

- **Design Language**: Control plane aesthetic with IBM Plex Sans / IBM Plex Mono typography, canvas/paper surfaces, restrained teal interactive accents, subtle borders, and semantic tones (`online`, `warning`, `danger`, `neutral`).
- **Styling Policy**: Static presentation rules belong in `src/styles.css`; dynamic data-driven values (e.g. calculated trend percentage widths) stay in component inline styles or CSS custom properties.
- **Form Controls**: Use dedicated form primitives (`.form-control`, `.form-select`, `.form-field`, `.form-check`). Never reuse `.button` or `.button--quiet` classes as inputs or selects.
- **Component Distribution**:
  - `src/components/ui.tsx`: Generic, cross-feature Admin primitives (`Button`, `Badge`, `PageHeader`, `MetricTile`, `EmptyState`, `ErrorState`, `Pagination`, `CodeBlock`).
  - `src/features/<feature>/components/`: Feature-specific reusable presentation (`TelemetryFilterPanel`, `TelemetryRecordCard`, `TelemetryTrendList`).
- **No External UI Frameworks**: Do not introduce Tailwind, Material UI, Ant Design, shadcn, Chakra, Bootstrap, or CSS-in-JS libraries.
- **Responsive Policy**: Follow existing breakpoints (`1100px`, `900px`, `760px`). Do not invent per-page custom breakpoint systems. Long technical IDs, JSON payloads, and stack traces must overflow gracefully without breaking page containers.
- **Accessibility**: Use semantic HTML elements (`<button>`, `<input>`, `<select>`, `<nav>`, `<article>`), explicit focus rings, keyboard activation for expand/collapse actions, and descriptive `aria-label` / `aria-expanded` attributes.

## Testing and validation

- **Behavior-Driven Tests**: Write tests using Vitest and Testing Library under `tests/` or alongside feature files (`*.test.tsx`). Test user-observable behavior (queries, filters, pagination, form submissions, accessibility roles) rather than internal React state or brittle DOM structure.
- **Validation Commands**:
  ```bash
  npm run typecheck
  npm run typecheck:tests
  npm run lint
  npm run test:run
  npm run build
  ```
- Repo root preflight:
  ```bash
  git diff --check
  ```
