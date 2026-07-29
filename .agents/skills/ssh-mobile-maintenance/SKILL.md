---
name: ssh-mobile-maintenance
description: Maintain and debug the SSH Mobile Flutter repository, including architecture, UI, SSH/SFTP, monitoring, AI tools, storage, security, platform builds, tests, and project documentation. Use for any non-trivial code, debugging, validation, documentation, or shared-agent-guidance change in this repository.
---

> 最新更新时间：2026-07-29

# SSH Mobile Maintenance

## Workflow

1. Read `AGENT_MEMORY.md` for the small set of non-obvious durable decisions.
2. Inspect `git status`, the owning feature, its tests, and only the relevant
   references below. Preserve unrelated user changes.
3. Put behavior in the owning layer and reuse existing interfaces before adding
   another abstraction or protocol path.
4. Keep the change scoped. Update user-facing docs only when behavior,
   configuration, navigation, dependencies, or platform support changes.
5. Run validation proportional to the change and report what was not verified.

Treat current code and tests as the behavioral source of truth. Treat
`AGENTS.md` as the source of truth for repository layout, conventions, commands,
Markdown update markers, and the full quality gate; do not repeat those details
in this skill or memory.

## Architecture Boundaries

- Keep feature-owned UI, models, services, and state under
  `lib/features/<feature>/`. Keep shared UI in `lib/widgets/` and `lib/theme/`;
  keep cross-feature protocol, security, and persistence infrastructure in
  `lib/services/`, `lib/core/services/`, and `lib/data/`.
- Do not add new application code to legacy `lib/screens/` or `lib/models/`.
- Keep screens focused on composition and transient presentation state. Put
  validation, async orchestration, repositories, and reusable state in
  ViewModels or services.
- Keep application-lifetime dependencies in `main.dart`; prefer feature-,
  route-, or view-scoped state for heavy or task-specific runtimes.
- Split by responsibility before a non-generated Dart file approaches 1000
  lines. Change generator inputs instead of editing generated files.
- Prefer narrow Provider subscriptions, stable snapshots, background parsing
  for large results, and existing protocol/repository interfaces.

## Safety Boundaries

- Store passwords, private keys, API keys, and tokens only in secure storage.
  Keep them out of logs, exports, traces, docs, tool arguments/results, and
  durable agent memory.
- Route AI tool visibility, approval, execution, and redaction through the
  existing exposure and `ToolSecretPolicy` boundaries. Remote writes and
  sensitive reads require approval; destructive shell deletion stays blocked.
- Run AI shell tools through one-shot SSH exec. Never reuse an interactive
  terminal or silently trust an unknown or changed host key.
- Keep structured growing data behind `StorageService` and Drift repositories.
  Encrypt sensitive fields before SQLite writes; never hide a production
  database-open failure with an in-memory fallback.
- Treat remote files and peer input as untrusted. Bound reads before allocation,
  keep secret-bearing paths out of caches, and preserve authentication,
  fingerprint pinning, integrity checks, and sandboxed receive paths.
- Respect `serverPlatform`: native Windows uses PowerShell/plain SSH behavior;
  Linux-only tmux and `/proc` assumptions must not leak into Windows paths.
- Route application diagnostics through `AppLogService`; do not add `print`
  diagnostics.

## Task Routing

Read only the rows relevant to the task.

| Task | Start with | Additional reference |
| --- | --- | --- |
| Architecture, MVVM, storage | Owning `lib/features/` code, `lib/data/`, `lib/services/storage_service.dart` | `docs/ADR_ENGINEERING_BASELINE.md` |
| Startup or service lifetime | `lib/features/startup/`, `lib/main.dart` | `docs/STARTUP_INITIALIZATION.md` |
| SSH, terminal, host keys | `lib/features/connection/`, `lib/features/terminal/`, SSH services | `docs/security_manual_regression.md` |
| SFTP, preview, cache | `lib/features/sftp/`, `lib/services/sftp_service.dart` | `docs/security_manual_regression.md`, `docs/PERFORMANCE_ACCEPTANCE.md` |
| AI chat, tools, plans, MCP | `lib/features/ai_chat/`, `lib/services/ai_tool*`, `lib/services/mcp/` | `docs/AGENT_RUN_TRACE.md`, `docs/security_manual_regression.md` |
| Monitoring or system admin | `lib/features/performance/`, `lib/features/system_admin/` | `docs/SYSTEM_ADMIN_MONITOR_INTEGRATION.md`, `docs/PERFORMANCE_ACCEPTANCE.md` |
| LAN share, native network, relay | `lib/features/lan_share/`, `lib/services/network/`, `native/network_core/`, `relay/` | `docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md`, relevant `docs/adr/ADR-*.md` |
| Shared UI or responsiveness | `lib/theme/app_theme.dart`, `lib/widgets/app_surface.dart`, `lib/utils/responsive.dart` | `docs/MOBILE_UI_QA.md` |
| Build, release, packaging | Platform directory and `scripts/` | `docs/RELEASE_CHECKLIST.md`, `docs/VALIDATION_REPORT.md` |
| Matching recurring regression | Nearest code and focused tests | `.agents/skills/ssh-mobile-maintenance/references/lessons.md` |

## Validation

- Format changed Dart files and run targeted `flutter analyze` plus the closest
  tests during the edit loop.
- Broaden to the full gate in `AGENTS.md` when changing shared infrastructure,
  protocols, persistence, security boundaries, generated models, or platform
  configuration.
- Regenerate and verify committed generated output after Drift or other codegen
  input changes.
- Resolve SDKs and toolchains from `PATH` or standard environment variables;
  never record machine-local absolute paths.
- After editing this skill, run
  `powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Check`.
  Use a restore mode only when the check reports a missing or divergent copy.
