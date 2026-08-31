> Last updated: 2026-08-31

# Front Web Admin Panel & UI Architecture

## 1. Scope and boundaries

The `front/` workspace contains the browser-based administration and observability console for SSH Mobile. Built as a Single Page Application (SPA) using React, TypeScript, and Vite, it serves as the unified operator control plane for the Relay service and the full-stack Telemetry suite.

### Ownership boundaries

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                           front/ (Browser SPA)                          │
│  - Operator Presentation & Layout     - Filter & Query State Orchestration│
│  - Navigation & AppShell Routing      - Accessible Keyboard & ARIA Layer │
│  - Typed API Adapters & Schemas       - Responsive Control Plane Views    │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ HTTP / REST (/api/admin/v1)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           relay/ (Go Backend)                           │
│  - Administrator Auth & Session       - Device Registry & Enrollment     │
│  - MySQL / Redis Persistence          - Telemetry Ingestion & Purging   │
│  - WebSocket v2 Data/Control Relay    - Active Session Forwarding        │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Front owns**: Operator UI presentation, view composition, client-side routing, query caching and polling lifecycle, user input validation, accessibility semantics, and responsive layout adaptations.
- **Front does not own**: Authentication decisions, credential hashing, Relay transfer sessions, device enrollment verification, backend database schemas, data purging execution, or native SDK telemetry capture.

---

## 2. Layer architecture

Front enforces a strict unidirectional dependency graph. Lower layers never depend on or import from upper layers.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Layout & Router (src/layout/app-shell.tsx, React Router)               │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ Feature Pages (src/features/<feature>/*-page.tsx)                      │
│   Overview | Devices | Access | Telemetry (Dashboard, Events, ...)      │
└──────────────┬───────────────────────────────────────────┬──────────────┘
               │                                           │
┌──────────────▼──────────────────────────┐ ┌──────────────▼──────────────┐
│ Feature Components                      │ │ Shared UI Primitives        │
│ (src/features/<feature>/components/*)   │ │ (src/components/ui.tsx,     │
│   TelemetryFilterPanel, RecordCard, ... │ │  confirm-dialog, toast)     │
└──────────────┬──────────────────────────┘ └──────────────┬──────────────┘
               │                                           │
               └─────────────────────┬─────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ Query & Mutation Hooks (src/hooks/)                                     │
│   TanStack Query orchestration, cache keys, polling, refetch logic      │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ API Request Adapters (src/api/)                                         │
│   HTTP client, error normalization (ApiRequestError), fetch wrappers   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ Runtime Validation & DTO Contracts (src/schemas/)                       │
│   Zod schemas, input/output TypeScript types                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### Layer responsibilities

1. **Schemas (`src/schemas/`)**: Source of truth for API payload contracts. Every incoming response is validated with Zod before consumption by hooks or views.
2. **API Adapters (`src/api/`)**: Pure async functions that invoke the browser `fetch` API. Handles query string serialization, request cancellation (`AbortSignal`), status code checking, and error payload extraction.
3. **Query Hooks (`src/hooks/`)**: Wraps TanStack Query (`useQuery`, `useMutation`). Centralizes query cache keys (`src/api/query-keys.ts`), cache garbage collection times (`gcTime`), staleness thresholds (`staleTime`), and retry policies (`shouldRetryApiRequest`).
4. **Shared UI Primitives (`src/components/`)**: Feature-agnostic UI building blocks (`Button`, `Badge`, `PageHeader`, `MetricTile`, `Pagination`, `CodeBlock`, `ConfirmDialog`, `Toast`).
5. **Feature Components (`src/features/<feature>/components/`)**: Reusable presentation components specific to a domain feature (e.g. `TelemetryFilterPanel`, `TelemetryRecordCard`, `TelemetryTrendList`).
6. **Feature Pages (`src/features/<feature>/`)**: Top-level page route components that assemble feature components and shared primitives, binding them to query hooks and local state.
7. **Layout (`src/layout/`)**: Application shell, persistent navigation sidebar, mobile drawer, topbar breadcrumb, and administrator session controls.

---

## 3. State ownership and lifecycle

Front categorizes application state into two mutually exclusive tiers:

| State Tier | Owner | Examples | Storage / Mechanism |
| :--- | :--- | :--- | :--- |
| **Server State** | TanStack Query | Device list, Relay runtime metrics, Telemetry overview, Events list, Diagnostics logs, Settings policy | In-memory query cache with automatic deduplication, polling intervals, and background revalidation. |
| **Local UI State** | React Component (`useState`, `useRef`) | Search draft text, active filter criteria, expanded record ID, confirmation dialog open/close, active tab | Local component memory. Cleared upon unmount or navigation. |

### Invariants:
- Server data is never copied into a secondary global state store (e.g. Redux or Zustand).
- Mutations invalidate or optimistically update the exact TanStack Query cache key via `queryClient.invalidateQueries` or `queryClient.setQueryData`.
- High-sensitivity credentials (such as the Relay Enrollment Token) are cached strictly in ephemeral memory with short Time-To-Live (30 seconds) and never written to `localStorage`, `sessionStorage`, or URL parameters.

---

## 4. API boundary and security

All network interactions pass through `/api/admin/v1/*` endpoints.

```text
Feature Page ──► Query Hook ──► API Adapter ──► Relay Backend Handlers
```

- **Authentication**: Authenticated sessions rely on an `HttpOnly`, `SameSite=Lax` cookie issued upon successful login at `/api/v1/auth/login`. The browser attaches the cookie automatically to same-origin requests.
- **Development Proxy**: In local development, Vite proxies API requests to the configured Relay daemon. In production, Caddy routes frontend assets and backend endpoints under the same origin.
- **Error Normalization**: All non-2xx responses are parsed into structured `ApiRequestError` instances carrying the HTTP status code, machine-readable error code, and localized operator message.

---

## 5. UI Design System

The SSH Mobile Web Admin Console follows a disciplined control plane design system engineered for high information density, technical clarity, and restrained visual hierarchy.

### 5.1 Foundations

- **Typography**:
  - Primary UI: `IBM Plex Sans`, `-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, `sans-serif`.
  - Technical / Monospace: `IBM Plex Mono`, `Cascadia Mono`, `monospace`.
  - Usage Rule: Monospace is strictly reserved for technical identifiers (`deviceId`, `traceId`, `eventId`, `sessionId`), network addresses (`IP:Port`), protocol versions, tokens, metric numbers, JSON payloads, and stack traces. Standard prose and labels remain in proportional sans-serif.
- **Color Palette & Semantics**:
  - Canvas: `var(--canvas)` (`#f2f6f5`) — Background substrate.
  - Paper: `var(--paper)` (`#ffffff`) — Elevated surface for cards, panels, and dialogs.
  - Ink: `var(--ink)` (`#1d2a2e`) — Primary headings and high-emphasis data.
  - Ink Soft: `var(--ink-soft)` (`#425256`) — Body copy, field labels, and secondary values.
  - Muted: `var(--muted)` (`#718184`) — Timestamps, metadata, captions, and descriptions.
  - Faint: `var(--faint)` (`#a8b7b7`) — Placeholder text, section tags, and subtle borders.
  - Line / Line Strong: `var(--line)` (`#d8e3e1`) / `var(--line-strong)` (`#c7d5d2`) — Structural dividing borders.
  - Teal: `var(--teal)` (`#176b73`) / `var(--teal-deep)` (`#0f545b`) / `var(--teal-pale)` (`#e4f1ef`) — Primary brand, active states, healthy/online indicators.
  - Amber: `var(--amber)` (`#c5892f`) / `var(--amber-pale)` (`#fff3dc`) — Warnings, stale cache notices, degraded health.
  - Coral: `var(--coral)` (`#b65347`) / `var(--coral-pale)` (`#fbe9e5`) — Critical errors, fatal failures, destructive actions.
- **Border Radii**:
  - Buttons / Inputs / Controls: `10px`
  - Inner badges / Small controls: `8px`–`10px`
  - Subordinate panels / Cards: `12px`–`15px`
  - Primary signal / visual hero cards: `18px`
  - Badges / Pills: `999px`
- **Elevation & Shadows**:
  - Card & Panel: `var(--shadow-soft)` (`0 18px 44px rgba(27, 56, 58, 0.07)`).
  - Modal Dialogs: `var(--shadow-dialog)` (`0 32px 90px rgba(23, 42, 46, 0.2)`).

### 5.2 Form Control System

Form inputs must never borrow button styles. Form controls use dedicated CSS classes:

- `.form-field`: Vertical container binding label, control, and description.
- `.form-label`: High-contrast field header.
- `.form-description`: Secondary guidance text.
- `.form-control`: Standard text, number, and search inputs with custom focus rings.
- `.form-select`: Dropdown control with unified border and focus styling.
- `.form-check`: Fully clickable row encapsulating checkboxes and descriptive labels.
- `.form-grid`: Responsive multi-column grid layout for form controls.

### 5.3 Shared Primitives

| Component | Responsibility | Location |
| :--- | :--- | :--- |
| `Button` | Action triggers supporting `primary`, `quiet`, `outline`, `danger`, `icon` variants with loading spin state. | `src/components/ui.tsx` |
| `IconButton` | Icon-only button with mandatory accessible `label` and tooltip. | `src/components/ui.tsx` |
| `Badge` | Status pill with semantic tones (`online`, `offline`, `warning`, `danger`, `neutral`) and optional pulse dot. | `src/components/ui.tsx` |
| `PageHeader` | Standard page top banner with eyebrow, title, description, and optional action slot. | `src/components/ui.tsx` |
| `MetricTile` | KPI indicator tile with accent color border, large value, and detail explanation. | `src/components/ui.tsx` |
| `SignalRail` | Connected pipeline flow diagram indicating node health and counts. | `src/components/ui.tsx` |
| `EmptyState` | Informative fallback display when queries return zero records. | `src/components/ui.tsx` |
| `ErrorState` | Alert container presenting API failure details with a retry button. | `src/components/ui.tsx` |
| `InlineNotice` | Subtle alert banner for warnings, stale cache indicators, or system notes. | `src/components/ui.tsx` |
| `Pagination` | Accessible pagination toolbar with previous/next triggers and current page indicator. | `src/components/ui.tsx` |
| `CodeBlock` | Monospace code/JSON/stack-trace container with horizontal scroll containment. | `src/components/ui.tsx` |
| `ConfirmDialog` | Modal confirmation prompt for high-impact actions (e.g. device revocation). | `src/components/confirm-dialog.tsx` |
| `ToastProvider` / `useToast` | Non-blocking global notification toasts for mutation outcomes. | `src/components/toast.tsx` |

---

## 6. Styling policy

1. **Static Presentation Belongs in CSS**: All static styling (layout, grid structure, padding, margins, borders, radii, typography, hover transitions, and media queries) must be defined in `src/styles.css` using semantic class names.
2. **Dynamic Runtime Data Rule**: Inline `style={{ ... }}` attributes are permitted only for truly dynamic runtime data (such as calculated percentage widths for trend bars) or dynamic CSS custom property overrides.
3. **No Magic Numbers**: Colors and radii must strictly use defined CSS custom properties.

---

## 7. Responsive architecture

Front adapts across three primary layout viewports:

```text
┌────────────────────────┬────────────────────────┬────────────────────────┐
│  Desktop (≥ 1100px)    │   Medium (760–1100px)  │   Mobile (320–760px)   │
├────────────────────────┼────────────────────────┼────────────────────────┤
│ - Sticky 250px sidebar │ - Sticky sidebar       │ - Collapsible drawer   │
│ - 4-column metric grid │ - 2-column metric grid │ - 1-column metric grid │
│ - Full filter grid     │ - Responsive wrapping  │ - Stacked filter panel │
│ - Table layout         │ - Horizontal scroll    │ - Card/list adaptation │
└────────────────────────┴────────────────────────┴────────────────────────┘
```

- Content scroll containers prevent window-level layout breaking.
- Monospace strings (Trace IDs, Session IDs, URLs, JSON payloads) use `overflow-x: auto` or ellipsis truncation to prevent viewport expansion on narrow devices.

---

## 8. Accessibility (a11y) standards

Accessibility is a non-negotiable quality gate for the Web Admin Console:

1. **Semantic HTML**: All interactive elements utilize native `<button>`, `<input>`, `<select>`, and `<nav>` tags.
2. **Keyboard Navigation**: Expandable cards, filter groups, dialogs, and pagination controls are fully operable via Tab, Enter, Space, and Escape keys.
3. **Focus Visibility**: Focus states feature high-visibility teal focus rings (`outline: 3px solid rgba(23, 107, 115, 0.28); outline-offset: 3px;`).
4. **ARIA Contract**: Dynamic regions use `aria-live="polite"`, expandable rows specify `aria-expanded`, and icon-only triggers provide explicit `aria-label` descriptors.
5. **Reduced Motion**: All animations and transitions respect operator preferences via `@media (prefers-reduced-motion: reduce)`.
6. **Color Independence**: Status information is never conveyed by color alone; every indicator combines color with text or icons.

---

## 9. Feature extension guidelines

When implementing a new Admin page or feature:

1. **Schema First**: Define API request parameters and response DTO schemas in `src/schemas/`.
2. **API Client**: Implement typed HTTP requests in `src/api/` with Zod validation.
3. **Query Hook**: Author custom `useQuery` / `useMutation` hooks in `src/hooks/` using established query keys.
4. **Evaluate Primitives**: Review `src/components/ui.tsx` for existing layout and display primitives.
5. **Feature Presentation**: Build feature-specific presentation components under `src/features/<feature>/components/`.
6. **CSS Convergence**: Add reusable presentation classes to `src/styles.css`, avoiding inline presentation styles in JSX.
7. **Behavioral Testing**: Write user-observable behavior tests in `tests/` verifying query rendering, filtering, pagination, and error recovery.
