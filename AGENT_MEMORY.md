# Agent Memory

> 最新更新时间：2026-07-29

This is the small durable memory shared by Codex and Claude Code. It records
current, non-obvious decisions that are expensive to rediscover from a single
file. It is not a changelog, architecture guide, test report, or feature list.

## Maintenance

- Read this file before non-trivial repository work.
- Replace or merge stale decisions instead of appending chronological notes.
- Keep implementation detail in code/tests and stable policy in `AGENTS.md`,
  the maintenance skill, ADRs, or focused docs.
- Never store secrets, user-private data, machine-local paths, temporary test
  results, completed migration phases, or claims such as "100% tests pass".

## Durable Decisions

### Runtime ownership

- Startup is intentionally lazy. Bootstrap loads preferences and storage;
  feature scopes own heavy ViewModels. `SshService.ensureInitialized()` gates
  SSH runtime work, `AiChatRuntimeFactory` owns the view-scoped chat runtime,
  and `LanReceiverCoordinator` exposes exactly one receiver-owned
  `LanShareViewModel` to the LAN page and pairing/chat routes.
- `StorageService.appDatabase` may be requested before async initialization.
  It must own one cached database instance, concurrent `init()` calls must share
  one future, Drift setup must reuse that instance, and log database binding
  must finish before storage reports readiness.
- During active development Drift remains one current schema at version 1.
  Schema changes regenerate `app_database.g.dart` and may require deleting the
  local development database; do not add compatibility migrations without an
  explicit release requirement.

### AI and security

- Tool visibility is an execution boundary, not only a model hint. Hidden tools
  must never reach approval, execution, cache, loop-guard, or budget paths.
  Connection requirements and execution-plan step gates are enforced again at
  execution time.
- Approved plan actions must flow through `AiToolService.execute` (or the
  equivalent provider path) so approval state cannot be bypassed. Default
  planning persists chat-bound `todoSteps`; create a reusable Playbook only
  when the user explicitly requests one.
- The local MCP server is loopback-only and reuses `AiToolService`.
  External write/destructive calls remain `approval_required`; this boundary is
  locked and must reject stale or injected settings that attempt to disable it.

### Network transfer

- LAN file sends use the injected `TransferTransport`; do not restore the
  legacy HTTPS file-send fallback. Native commands/events are versioned, peer
  identity and keys are pinned before connect, and success is reported only
  after receiver persistence and acknowledgement.
- Public relay frames remain memory-only and end-to-end encrypted. The only
  supported production deployment is `relay/compose.yaml` with Caddy; clients
  enroll explicitly, connect through HTTPS/WSS, and require receiver approval.

### UI and performance

- Primary workspaces reuse `AppPageSurface`, `AppPageHeader`, `AppSectionCard`,
  `AppEmptyState`, and the shared server selector. `MobileUiMetrics` and
  `AppBreakpoints` remain the sources for adaptive density and thresholds;
  never scale the user's system text setting.
- Terminal input keeps one multiline draft shared by the inline composer and
  advanced keyboard. Preserve IME composition, bracketed-paste submission,
  local command recall, direct terminal-key forwarding for an empty draft, and
  non-scrolling keyboard rows that fit available width.
