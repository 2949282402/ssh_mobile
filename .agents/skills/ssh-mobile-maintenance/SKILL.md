---
name: ssh-mobile-maintenance
description: Maintain and debug the SSH Mobile Flutter repository, including architecture, UI, SSH/SFTP, monitoring, AI tools, storage, security, platform builds, tests, and project documentation. Use for any non-trivial code, debugging, validation, documentation, or shared-agent-guidance change in this repository.
---

> 最新更新时间：2026-08-09

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

App dependency ownership follows the same boundary: keep a third-party package in
`apps/ssh_mobile_full/pubspec.yaml` only when App `lib/`, `test/`, or `tool/`
imports it directly, or when the App Shell owns its platform adapter. Feature and
Core Packages declare their own terminal, AI, RAG, and database dependencies;
do not restore removed transitive App declarations merely because a workspace
lockfile still contains them for another Package.

During the modular migration, the full Flutter application is rooted at
`apps/ssh_mobile_full/`. Unless a path below is explicitly repository-level or
package-level, a leading `lib/`, `test/`, or `tool/` path is relative to that
app. The Dart native package is rooted at
`packages/infrastructure/ssh_mobile_network_native/`. The first Core contract
package is `packages/core/app_core/`; its production library is pure Dart and
must not depend on Flutter UI, SSH, Drift, Infrastructure, or Feature code.
The shared UI package is `packages/core/app_ui/`; it owns the public
`package:app_ui/app_ui.dart` theme, responsive metrics, and cross-feature UI
widgets. It must not depend on any Feature, SSH, network, database, or App
Service implementation.
The Connection domain package is `packages/core/connection_core/`; it owns
Connection models, repositories, the non-sensitive Drift database, Secure
Storage credentials, and Host Key contracts, but never Feature UI or SSH
session implementations.
The Connection UI/application package is
`packages/features/feature_connection/`; it owns the migrated connection editor
and ViewModel, consumes only Core repositories, and receives SSH/SFTP/monitoring
behavior through injected Capability Ports. The temporary legacy Storage bridge
lives in the App composition root, not in the Feature.
The Network Transport infrastructure package is
`packages/infrastructure/network_transport/`; it owns the App Scope
`NetworkRuntime` facade, lazy Capability state, transport contracts, and the
explicit native handle adapter. `AppRuntime` creates the sole instance; the
migrated LAN Feature consumes it through injected Ports, while native v1
construction remains in the App Shell adapter.
The SSH infrastructure package is `packages/infrastructure/ssh_core/`; it owns
the App Scope `SshSessionManager`, Lease/Pool lifecycle, platform-neutral Runtime
Adapter contracts, SSH Client/Host Key/command boundaries, and non-secret target
bindings. It must not depend on App Shell storage implementations or Features. The current app
keeps `SshService` as the same-instance compatibility surface until the Terminal
Pilot migrates its method API.

`apps/ssh_mobile_terminal/` is a separate minimal App Shell used for the
Terminal-only dependency crop. Its direct package dependencies are limited to
`app_core`, `app_ui`, `connection_core`, `network_transport`, `ssh_core`,
`feature_connection`, and `feature_terminal`; do not copy the Full App runtime or
add AI, RAG, MCP, WebView, LAN Share, or SFTP. Use the Feature's public
`TerminalFeatureScope` for Provider composition and keep App/Module owners
responsible for resource disposal. `flutter pub deps` must be checked at the app
node, because the workspace aggregate naturally lists other members.
The Terminal Feature package is `packages/features/feature_terminal/`; it owns
terminal UI, route-scoped ViewModels, terminal history metadata, and
`terminal.db`. It consumes `ssh_core.SshSessionManager` and App-defined Ports;
it must not construct or dispose App Scope SSH, Storage, or other Feature
implementations. The old App terminal files are compatibility exports/bridges.
The Monitoring Feature package is `packages/features/feature_monitoring/`; it
owns real-time monitoring models, probes/parsers, low-priority SSH Ports,
`MonitoringModule`, and route-scoped state. It has no `monitoring.db`; bounded
in-memory samples preserve the current behavior. `AppRuntime` owns the Module
and service, while old Performance Monitor paths are non-owning compatibility
bridges.
The System Administration Feature package is
`packages/features/feature_system_admin/`; it owns System Admin UI, route state,
management commands, lifecycle Module, and a local monitoring Capability
contract. It must not import `feature_monitoring` implementation. The App Shell
adapters in `apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart`
inject AppRuntime-owned SSH, Storage, SFTP, settings, logger, Host Key, and
Monitoring resources; the old System Admin paths remain compatibility bridges.
The SFTP Feature package is `packages/features/feature_sftp/`; it owns SFTP UI,
Route state, path-history/favorites Repository, and `sftp.db`. It consumes the
injected `ssh_core.SshSessionManager` and an App Shell backend Port; it must not
create or close App Scope SSH/SFTP resources. The old SFTP App files remain
compatibility bridges until later service-convergence Steps.
The LAN Share Feature package is `packages/features/feature_lan_share/`; it
owns discovery, pairing, HTTPS/WebSocket/Web Share transfer, the
`LanShareModule`, `LanShareHistoryRepository`, and `lan_share.db`. It may depend
on `network_transport`, `app_core`, and `app_ui`, but never SSH, another
Feature implementation, or App `/src/`. App settings, logging, data
protection, identity, and native v1 creation arrive through Ports from
`apps/ssh_mobile_full/lib/app/lan_share_feature_adapters.dart`. Old LAN paths
remain compatibility bridges during the staged migration.
The Playbook Feature package is `packages/features/feature_playbook/`; it owns
the Playbook UI, approval-aware sequential execution, encrypted run history,
and `playbook.db`. SSH, logging, and data protection arrive through injected
Ports, and AI callers use the public `PlaybookAutomationPort` contract. The
development refactor does not import old Playbook database records.
The RAG Feature package is `packages/features/feature_rag/`; it owns RAG
document parsing, retrieval modes, metadata Repository, bounded document cache,
route-scoped knowledge-base UI, and `rag.db`. AI callers use the public
`RagCapability` contract; settings, API-key access, logging, and embedding
clients arrive through Ports. The development refactor does not read or migrate
old RAG database files, and Drift must not store document正文 or large vectors.
The MCP Feature package is `packages/features/feature_mcp/`; it owns the local
MCP HTTP/JSON-RPC server, exposure/invocation policies, approval queue, console
UI, activity Repository, and `mcp.db`. App Shell adapters in
`apps/ssh_mobile_full/lib/app/mcp_feature_adapters.dart` provide settings,
logging, and the AI tool runtime. The package must not import AI Feature
implementation or App `/src/`; dangerous-tool `approval_required` behavior
must remain in its execution layer, and MCP activity must not return to the
shared business database or a unified storage facade.
The AI Feature package is `packages/features/feature_ai/`; it owns AI chat,
Agent, Skills, LLM providers/runtime, tool orchestration, AI WebView contracts,
and `ai.db`. `AiModule` lazily owns its database, Repository, provider/runtime,
and tool registry. App Shell adapters provide only public Ports and the
`app_core` Capability contracts actually used by AI; AI must not import another
Feature implementation or an App `/src/` path. The old App AI files are
non-owning compatibility surfaces.
The WebView Feature package is `packages/features/feature_webview/`; it owns
chat-bound WebView sessions, navigation UI, public-page search, visible-text
extraction, and the URL/sensitive-form security policy. `AppRuntime` owns its
`ClientWebViewService` and injects `AppLogger` plus the settings Port. AI must
consume WebView only through `AiWebViewPort`, never through this package's
`src/` implementation.
The Developer Feature package is `packages/features/feature_developer/`; it owns
Developer Log, Developer Panel, and diagnostics presentation. It observes only
the public `DeveloperLogPort`, `DeveloperSettingsPort`, and
`DeveloperDiagnosticsPort`; AppRuntime adapters provide redacted snapshots from
App-owned services. The lifecycle snapshot covers only owner-observable Module,
SSH, NetworkRuntime, database, Timer, and subscription resources; do not claim
global totals for legacy resources that have no diagnostics hook. AppRuntime's
debug-only release assertions must remain aligned with those observable Owners.
It must not import App Shell or another Feature implementation.
The App Shell keeps its root Provider limited to App Scope instances and Ports;
Feature ViewModels are created by Route Scope. Public route metadata is exposed
by Feature entrypoints and aggregated in
`apps/ssh_mobile_full/lib/app/navigation/`; the Shell must not import Feature
`/src/` implementations.
The SFTP Feature package is `packages/features/feature_sftp/`; it owns SFTP UI,
Route state, path-history/favorites Repository, and `sftp.db`. It consumes the
injected `ssh_core.SshSessionManager` and an App Shell backend Port; it must not
create or close App Scope SSH/SFTP resources. The old SFTP App files remain
compatibility bridges until later service-convergence Steps.
The Terminal Feature package is `packages/features/feature_terminal/`; it owns
terminal UI, route-scoped ViewModels, terminal history metadata, and
`terminal.db`. It consumes `ssh_core.SshSessionManager` and App-defined Ports;
it must not construct or dispose App Scope SSH, Storage, or other Feature
implementations. The old App terminal files are compatibility exports/bridges.

## Architecture Boundaries

- Keep feature-owned UI, models, services, and state under
  `apps/ssh_mobile_full/lib/features/<feature>/`. Keep shared UI in
  `packages/core/app_ui/` and import it through `package:app_ui/app_ui.dart`;
  old app theme/responsive/migrated-widget paths are compatibility exports;
  keep cross-feature protocol, security, and persistence infrastructure in
  `apps/ssh_mobile_full/lib/services/`, `apps/ssh_mobile_full/lib/core/services/`,
  and `apps/ssh_mobile_full/lib/data/`.
- Keep Core contracts under `packages/core/`. `app_core` owns lifecycle, Module,
  scoped logging contracts, bounded `LogBuffer`, disposable `LogSink`, and
  Capability contracts; it must not create global service instances or retain
  heavy runtime objects. The full App's database/disk/redaction adapter remains
  in `apps/ssh_mobile_full/lib/services/` until its later Plan Step.
- `connection_core` owns the Connection database and repository contracts.
  `AppRuntime` creates and closes its single `ConnectionDatabase`; the package
  must not create a global database. Passwords/private keys stay in
  `CredentialRepository` and Secure Storage, never in Connection Drift tables.
- `network_transport` must keep `NetworkRuntimeImpl` under App Scope ownership.
  Features may request public Capabilities but must not create a global network
  implementation or import another package's `/src/`.
- Run `dart run tool/architecture_check.dart` from the repository root before
  committing architecture work. Its explicit allowlist is the only place for
  approved Feature-to-Feature public boundaries and known legacy singleton
  compatibility names; do not silence a violation by adding a broad path
  exception.
- `ssh_core` must keep `SshSessionManager` and its Session Pool under App Scope
  ownership. A Feature may acquire/release a Lease but must not close a shared
  Session, import `flutter_background_service`, or perform platform checks.
- `feature_connection` must use only `connection_core` public contracts and its
  own public Capability Ports. It must not import `apps/ssh_mobile_full/lib/` or
  another Feature's `/src/`; `ConnectionViewModel` is Route/Provider scoped and
  never disposes App Scope SSH/SFTP resources.
- App Shell route composition belongs under `apps/ssh_mobile_full/lib/app/`.
  Root Providers may expose AppRuntime-owned instances and Ports only; route
  scopes own Feature ViewModels. Feature route contributions are metadata-only
  public API and are aggregated by `app/navigation/`; Core must not retain
  Widget, ViewModel, or Module instances.
- `feature_terminal` must keep `TerminalModule` as the owner of `terminal.db`
  and its repository. Route scope owns Terminal ViewModels and their
  subscriptions/controllers; disposing a route must not close the injected App
  Scope SSH Manager. Package consumers use only `package:feature_terminal/`.
- The Terminal-only App may validate composition with a minimal injected SSH
  Capability, but it must not duplicate the Full App's in-use SSH business
  implementation or create a second App Scope SSH owner. A later SSH method
  migration must preserve the same public contract and lifecycle rules.
- `feature_monitoring` must send all SSH sampling through its public Ports with
  `MonitoringRequestPriority.low`. `MonitoringModule` cancels polling on
  deactivate/dispose and must not create a permanent App-start timer or a
  `monitoring.db`. Package consumers use only
  `package:feature_monitoring/` and never import its `/src/`.
- `feature_lan_share` must keep `LanShareModule` as the owner of `lan_share.db`,
  its history Repository, and Receiver resources. `LanShareFeatureScope` only
  exposes the Coordinator-owned ViewModel. Receiver activation is explicit and
  configuration-controlled; compiling or importing the package must not start
  listeners. The Feature must not construct native network or SSH objects.
- `feature_playbook` must keep `PlaybookModule` as the owner of `playbook.db`,
  its Repository, and the execution Service. Approval fingerprints, immutable
  SSH target bindings, destructive-command restrictions, and secret filtering
  stay in the Service/Port layer rather than UI widgets. AI callers depend on
  `PlaybookAutomationPort`, never on another Feature's implementation or `/src/`.
- `feature_rag` must keep `RagModule` as the owner of `rag.db`, its Repository,
  bounded cache, and Service. `RagCachePolicy` enforces entry/total/source size,
  TTL, and eviction limits; AI callers depend on `RagCapability`, never on the
  RAG Service or another Feature's `/src/`.
- `feature_mcp` must keep `McpModule` as the owner of `mcp.db`, its activity
  Repository, HTTP server, and approval queue. Settings, logger, and AI tool
  execution arrive through public Ports from the App Shell. Keep approval
  target binding and `approval_required` in the execution layer, keep
  `McpApprovalRequest.opaqueHandle` in memory only, and ensure `dispose()` stops
  the server, rejects pending requests, and closes the module database.
- `feature_developer` must observe only public log/settings/diagnostics Ports.
  AppRuntime owns the adapters and the underlying logging, SSH, RAG, MCP, and
  monitoring resources; the Feature may render redacted snapshots but must not
  control or dispose those App Scope resources. Route-scoped frame callbacks,
  listeners, and memory-polling timers must be released by the ViewModel.
- `feature_terminal` must keep `TerminalModule` as the owner of `terminal.db`
  and its repository. Route scope owns Terminal ViewModels and their
  subscriptions/controllers; disposing a route must not close the injected App
  Scope SSH Manager. Package consumers use only `package:feature_terminal/`.
- Do not add new application code to legacy `lib/screens/` or `lib/models/`.
- Keep screens focused on composition and transient presentation state. Put
  validation, async orchestration, repositories, and reusable state in
  ViewModels or services.
- Keep application-lifetime dependencies in
  `apps/ssh_mobile_full/lib/app/app_runtime_factory.dart` and let
  `AppRuntime` own their lifecycle; `main.dart` should only delegate to
  `AppBootstrap`. Prefer feature-, route-, or view-scoped state for heavy or
  task-specific runtimes.
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
- Keep structured growing data behind the owning Feature/Core Repositories and
  their Drift databases.
  Encrypt sensitive fields before SQLite writes; never hide a production
  database-open failure with an in-memory fallback.
- Treat remote files and peer input as untrusted. Bound reads before allocation,
  keep secret-bearing paths out of caches, and preserve authentication,
  fingerprint pinning, integrity checks, and sandboxed receive paths.
- Respect `serverPlatform`: native Windows uses PowerShell/plain SSH behavior;
  Linux-only tmux and `/proc` assumptions must not leak into Windows paths.
- Route new module diagnostics through an injected `AppLogger` scope. The current
  full App adapts that contract through `AppLogService`; do not add `print`
  diagnostics or construct a new logging service in a Feature.

## Task Routing

Read only the rows relevant to the task.

| Task | Start with | Additional reference |
| --- | --- | --- |
| Architecture, MVVM, storage | Owning Feature/Core code, App Shell adapters, and module repositories | `docs/ADR_ENGINEERING_BASELINE.md` |
| Core contracts, logging, and Module lifecycle | `packages/core/app_core/lib/`, `packages/core/app_core/test/` | `docs/architecture/MODULAR_REFACTOR_PLAN.md` |
| Shared UI and responsiveness | `packages/core/app_ui/lib/`, `packages/core/app_ui/test/` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/MOBILE_UI_QA.md` |
| Connection domain, repositories, database, credentials, Host Key | `packages/core/connection_core/` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/security_manual_regression.md` |
| Connection Feature editor/ViewModel | `packages/features/feature_connection/`, `apps/ssh_mobile_full/lib/app/connection_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/security_manual_regression.md` |
| Connection Feature editor/ViewModel | `packages/features/feature_connection/`, `apps/ssh_mobile_full/lib/app/connection_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/security_manual_regression.md` |
| Startup or service lifetime | `lib/features/startup/`, `apps/ssh_mobile_full/lib/app/`, `apps/ssh_mobile_full/lib/main.dart` | `docs/STARTUP_INITIALIZATION.md` |
| SSH, terminal, host keys | `lib/features/connection/`, `lib/features/terminal/`, SSH services | `docs/security_manual_regression.md` |
| SFTP, preview, cache | `lib/features/sftp/`, `lib/services/sftp_service.dart` | `docs/security_manual_regression.md`, `docs/PERFORMANCE_ACCEPTANCE.md` |
| AI chat, Agent, Skills, LLM, tools, ai.db | `packages/features/feature_ai/`, `apps/ssh_mobile_full/lib/app/ai_feature_adapters.dart` | `docs/AGENT_RUN_TRACE.md`, `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_ai/README.md` |
| Client WebView, navigation, page text, search, security | `packages/features/feature_webview/`, `apps/ssh_mobile_full/lib/app/webview_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_webview/README.md` |
| Developer Log, Panel, diagnostics | `packages/features/feature_developer/`, `apps/ssh_mobile_full/lib/app/developer_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_developer/README.md` |
| App Shell, route scopes, navigation contributions | `apps/ssh_mobile_full/lib/app/`, `apps/ssh_mobile_full/lib/app/navigation/`, `packages/features/*/lib/*_feature.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `AGENTS.md` |
| MCP server, console, approval, mcp.db | `packages/features/feature_mcp/`, `apps/ssh_mobile_full/lib/app/mcp_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/security_manual_regression.md` |
| Monitoring or system admin | `lib/features/performance/`, `lib/features/system_admin/` | `docs/SYSTEM_ADMIN_MONITOR_INTEGRATION.md`, `docs/PERFORMANCE_ACCEPTANCE.md` |
| LAN share, native network, relay | `lib/features/lan_share/`, `lib/services/network/`, `packages/infrastructure/ssh_mobile_network_native/`, `native/network_core/`, `relay/` | `docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md`, relevant `docs/adr/ADR-*.md` |
| Network Transport facade and App Scope lifecycle | `packages/infrastructure/network_transport/`, `apps/ssh_mobile_full/lib/app/app_runtime.dart`, `apps/ssh_mobile_full/lib/app/app_runtime_factory.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md` |
| SSH Core sessions, Runtime adapters, Pool, Client, Host Key | `packages/infrastructure/ssh_core/`, `apps/ssh_mobile_full/lib/services/ssh_service.dart`, `apps/ssh_mobile_full/lib/app/app_runtime.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/security_manual_regression.md` |
| Terminal Feature, terminal.db, route lifecycle | `packages/features/feature_terminal/`, `apps/ssh_mobile_full/lib/app/terminal_feature_adapters.dart`, `apps/ssh_mobile_full/lib/app/terminal_ssh_capability_adapter.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_terminal/README.md` |
| Terminal Feature, terminal.db, route lifecycle | `packages/features/feature_terminal/`, `apps/ssh_mobile_full/lib/app/terminal_feature_adapters.dart`, `apps/ssh_mobile_full/lib/app/terminal_ssh_capability_adapter.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_terminal/README.md` |
| RAG Feature, rag.db, bounded cache, retrieval | `packages/features/feature_rag/`, `apps/ssh_mobile_full/lib/app/rag_feature_adapters.dart` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `packages/features/feature_rag/README.md` |
| Shared UI or responsiveness | `packages/core/app_ui/` | `docs/architecture/MODULAR_REFACTOR_PLAN.md`, `docs/MOBILE_UI_QA.md` |
| Build, release, packaging | Platform directory and `scripts/` | `docs/RELEASE_CHECKLIST.md`, `docs/VALIDATION_REPORT.md` |
| Matching recurring regression | Nearest code and focused tests | `.agents/skills/ssh-mobile-maintenance/references/lessons.md` |

## Validation

### LLM Chat and Tools

Primary maintained entry points are
`packages/features/feature_ai/lib/feature_ai.dart`,
`packages/features/feature_ai/lib/src/application/ai_module.dart`,
`packages/features/feature_ai/lib/src/data/repositories/ai_repository.dart`,
`packages/features/feature_ai/lib/src/chat/viewmodels/ai_chat_viewmodel.dart`,
and `packages/features/feature_ai/lib/src/tools/ai_tool_service.dart`. The old
App AI paths remain non-owning compatibility surfaces.

- Chat uses SSE streaming and must tolerate split `tool_calls` deltas.
- The `+` toolbar below the input row is the current entry point for server
  targeting, custom Skills, and the chat-bound WebView.
- Keep model selection in the LLM settings page, not on the chat page.
- New AI page entries start as unsaved drafts and are only persisted after the
  user sends a message.
- Chat history opens as a full-width overlay from the history button and loads
  lazily.
- The page supports user-message edit/resend, assistant regeneration, and
  branch-from-assistant flows with explicit confirmation for rewrite actions.
- Context windows are `259K`, `512K`, and `1M`; compress old history when
  estimated usage reaches 90%.
- DeepSeek `reasoning_content` must be passed through unchanged on tool rounds.
- `web_search` is a client-side tool backed by the current chat WebView.
- Multi-agent helpers run before the primary answer and never receive tool
  definitions or execute SSH/SFTP/client tools directly.
- AI chat replies, context compression, helper-agent calls, and tool rounds do
  not use a fixed LLM request timeout. Retry retryable network failures three
  times before surfacing the error. The stop button remains the user-controlled
  cancellation path.
- Per-request tool use has budget guardrails. The default budget is 20 tool
  calls, the first limit hit auto-extends by half, and every later extension
  requires an internal safety audit that can disable further tools and force a
  final no-tools summary.
- Agent loop round limits are separate from tool-call budgets. Balanced uses
  16 primary model rounds and approved +8 extensions, Deep uses 24/+12, and
  Unlimited removes only the primary loop round cap; tool budgets, approval
  gates, safety policies, and user cancellation remain active.
- State-changing tool actions must pause for the generic approval UI. Keep the
  approval model broader than `run_command`.
- `run_command` uses one-shot SSH exec, respects `serverPlatform`, and blocks
  delete/remove operations even when approval exists.
- Default AI planning stays in chat-bound `todoSteps` for the current request.
  Only create or run saved `Playbook` records when the user explicitly asks to
  save, reuse, manage, or execute a reusable script/playbook.
- Approved plan execution runs a client runtime health preflight before the
  execution prompt. Blocking client issues stop execution, warning issues
  require explicit user confirmation before continuing.
- Client-side tools stay in `ClientSystemToolService` and the
  `feature_webview`-owned `ClientWebViewService`, use the `client_` prefix, and return
  `execution: client`.
- Keep `client_check_runtime_health` as the aggregate client readiness tool for
  long-running agent execution, SSH keep-alive, SFTP transfers, and monitoring;
  it should reuse client network, battery, permission, and background-service
  adapters and redact raw payloads with `ToolSecretPolicy`.
- Route tool arguments, approvals, results, and trace content through
  `ToolSecretPolicy`.
- AI tools must block secret-bearing server paths, environment dumps, and cloud
  metadata endpoints. Remote log reads and ordinary SFTP file reads/downloads
  require user approval; sensitive SFTP paths are blocked.
- The local MCP Server lives in `packages/features/feature_mcp/` and is
  implemented in Flutter/Dart, not native runners. It binds only to local
  hosts, serves Streamable HTTP JSON-RPC at `POST /mcp`, stores its Bearer token
  in secure storage through the App Shell settings Port, and reuses
  `AiToolService` through an injected runtime adapter and separate exposure and
  invocation policies. The default `reviewConfiguredTools` mode queues only exposed tools
  selected for review when `approvalRequestFor` produces a dynamic request;
  `trustedAgent` directly executes exposed calls. The shared exposed set is
  persisted across both modes; missing preferences preserve current hard-allowed
  tools, while new Tool names stay unexposed after an explicit exposure change.
  Bound direct calls still use
  `executeApproved`, and both modes retain hidden-tool, target-binding,
  `ToolSecretPolicy`, input-validation, sensitive-path, and destructive-command
  safeguards. The in-memory `McpApprovalQueue` is cleared on exposure, policy,
  token, or server lifecycle changes and is never persisted.
- The Windows/macOS-only console is owned by the `feature_mcp` package. Keep
  status, port checks, loopback authenticated self-tests, configuration
  copying, policy snapshots, redacted local activity, and the dedicated
  approval queue page under this feature. The console is the only UI for per-Tool exposure and
  review configuration; hard-hidden and blocked rows remain disabled. MCP
  activity is capped at 500 records in `mcp.db` and must
  never include tokens, request arguments, tool output, peer/origin data,
  remote-resource details, or raw exceptions; it is not a backup-export
  payload. Approval previews must use the `McpApprovalRequest` contract and
  must not expose raw tool arguments; the App Shell may retain the original
  binding only in its process-local opaque handle.

### SFTP

Primary entry points are `lib/features/sftp/viewmodels/sftp_viewmodel.dart`,
`lib/services/sftp_service.dart`, and `lib/features/sftp/views/sftp_screen.dart` with
its `views/` parts.

- Keep multi-server switching warm when practical.
- Keep large directory entry construction and sorting off the UI isolate, and
  use asynchronous directory iteration for cache discovery and cleanup.
- Restore the last remote path after reconnect.
- SFTP error retry must distinguish a live session directory failure from a
  closed-session connection failure: refresh the current path when the client
  is open, otherwise reconnect the selected server with host-key confirmation.
- Recent and favorite SFTP paths are per server and Drift-backed. Keep them out
  of the SFTP protocol layer; record successful directory opens through the
  service/facade path.
- Require typed-name confirmation before delete.
- Use dedicated editor/viewer pages for larger previews and text edits.
- Read download, preview, and edit size limits from `AppSettings` instead of
  hardcoding screen-local constants.
- Bound every in-memory SFTP read while streaming, before full allocation. Read
  at most the caller limit plus one sentinel byte, invalidate over-budget cache
  entries before a bounded remote fallback, and bypass cache on explicit retry.
- Encrypt SFTP preview/download cache files with `DataProtectionService`.
  Secret-bearing paths such as `.ssh`, `.env`, private keys, token files,
  cloud credential folders, `/etc/shadow`, `/etc/sudoers`, and
  `/proc/*/environ` must not be cached.
- Delete SFTP cache when a saved connection is removed or explicitly forgotten.
- Manual directory refresh must bypass the short-lived directory cache. After
  a successful remote mutation, invalidate the target directory cache and each
  affected encrypted file cache entry before reloading remote metadata.
- Treat preview files as untrusted. Keep Markdown links inert without changing
  code spans/blocks, block external Markdown images, and render HTML only with
  JavaScript disabled, a deny-by-default CSP, denied permissions/navigation,
  and stale-load isolation. Enforce image byte, dimension, frame-count, and
  total animation-pixel budgets.
- Do not read or parse remote PDFs inline unless a future renderer can enforce
  page-count and geometry limits before native allocation. The current viewer
  identifies PDFs and directs the user to download and open them externally.
- Keep upload, download, preview, edit, and delete behavior aligned across
  mobile, Windows, and macOS.
- Keep the SFTP upload action on the active theme's secondary color; do not
  hardcode the former deep-purple action color.

### LAN Quick Share

Primary maintained entry points are
`packages/features/feature_lan_share/lib/feature_lan_share.dart`,
`packages/features/feature_lan_share/lib/src/application/lan_share_module.dart`,
`packages/features/feature_lan_share/lib/src/features/lan_share/services/lan_receiver_coordinator.dart`,
`packages/features/feature_lan_share/lib/src/features/lan_share/viewmodels/lan_share_viewmodel.dart`,
and `packages/features/feature_lan_share/lib/src/services/lan_share/lan_transfer_service.dart`.
The old `apps/ssh_mobile_full/lib/features/lan_share/**` and
`apps/ssh_mobile_full/lib/services/lan_share/**` paths are compatibility
surfaces until later cleanup.

- Initialize the LAN receiver independently from the selected home tab so a
  foreground peer invitation can open the pairing page from anywhere in the
  app.
- Keep one receiver-owned `LanShareViewModel` behind `LanShareFeatureScope`;
  the LAN home page plus root pairing and chat routes must reuse that instance
  instead of binding a second receiver or depending on a missing root provider.
- QR scans and device-list taps use the same short-lived pairing invitation
  flow. QR URLs carry the stable device ID and native transfer port; never use
  the Web Share HTTP port as the native pairing port.
- Pairing invitations only request navigation and never establish trust.
  Complete trust only after reciprocal PIN verification.
- Merge simultaneous invitations for the same device into the active pairing
  route. The active screen must accept its peer's incoming role transition so
  two outgoing initiators cannot remain stuck in pending_remote.
- Reciprocal verification is role-independent: either device may submit its
  PIN first, and pairing completes only after both directions are verified.
  Updating a reciprocal invitation must preserve PIN input already typed on
  the active route.
- Authenticate every post-pair native endpoint with the peer-specific bearer
  token and pin the peer certificate fingerprint. Never accept a remote
  `localPath`; receive files into the LAN sandbox and restrict recall cleanup
  to files owned by that sandbox.
- Bound pairing nonces, pending uploads, request bodies, names, sizes, and
  preview decoding. A failed upload must clear its pending reservation, delete
  partial data, and persist an incoming failed state rather than leaving the
  history entry pending.
- Web Share URLs use a short-lived random capability, and their APIs require
  the matching request header. Keep restrictive response headers and avoid
  permissive CORS.
- Android discovery must hold a multicast lock while active. Apple targets
  declare Bonjour/local-network access and network-server entitlement where
  required. The Windows installer firewall rule is scoped to the application
  and local subnet.
- Never log pairing PIN values.

### Playbook

Primary maintained entry points are
`packages/features/feature_playbook/lib/feature_playbook.dart`,
`packages/features/feature_playbook/lib/src/application/playbook_module.dart`,
`packages/features/feature_playbook/lib/src/application/playbook_service.dart`,
and `packages/features/feature_playbook/lib/src/data/repositories/
playbook_repository.dart`. The old App Playbook paths remain non-owning
compatibility surfaces; they are not a second production database owner.

- Keep `PlaybookModule` lazy and configuration-controlled. Activating the Module
  must not connect to SSH or start execution automatically.
- Persist `playbooks`, `playbook_runs`, and `playbook_run_steps` only through
  the Module-owned Repository and encrypt command/output JSON before Drift writes.
- Use immutable `ssh_core.SshTargetBinding` snapshots and action fingerprints
  for approved execution. Reject stale target or command snapshots before each
  persisted state update.
- Execute steps serially. Pause, skip, resume, and dispose must coordinate with
  the in-flight command so no superseded run can write later state.
- Keep destructive shell restrictions, approval checks, and secret filtering in
  the Service/Port layer; never recreate them in a Playbook widget or prompt.

### RAG

Primary maintained entry points are
`packages/features/feature_rag/lib/feature_rag.dart`,
`packages/features/feature_rag/lib/src/application/rag_module.dart`,
`packages/features/feature_rag/lib/src/application/rag_service.dart`,
`packages/features/feature_rag/lib/src/data/repositories/rag_repository.dart`,
and `packages/features/feature_rag/lib/src/data/cache/rag_cache_store.dart`.
The old App RAG paths remain non-owning compatibility surfaces.

- Keep `RagModule` as the sole owner of `rag.db`, its Repository, cache Store,
  and Service; AppRuntime owns the Module and routes own ViewModels.
- Persist only document/index/cache metadata in Drift. Document正文 and vectors
  belong in the bounded cache, protected by entry/total/source size limits,
  TTL, and LRU-style eviction.
- Keep AI callers on `RagCapability`; settings, API-key access, logs, and
  embeddings enter through Ports. Never import another Feature or `/src/`.
- Initialization/database errors must surface. Dispose the Service before the
  Module closes its database, and never log API keys, document text, or vectors.

### Network Platform and Public Relay

Primary entry points are `native/network_core/`,
`packages/infrastructure/ssh_mobile_network_native/`,
`packages/features/feature_lan_share/lib/src/services/network/`,
`apps/ssh_mobile_full/lib/app/lan_share_feature_adapters.dart`,
`apps/ssh_mobile_full/lib/services/network/`,
`apps/ssh_mobile_full/lib/services/relay/`,
`packages/features/feature_lan_share/lib/src/features/lan_share/views/vpn_p2p_share_view.dart`,
and `relay/`. The Feature consumes typed contracts; only the App Shell adapter
may construct the native v1 service.

- Keep the Dart/Rust FFI command and event contract on the current development
  protocol v1. Unsupported versions must produce an explicit error; an
  unimplemented native route must return `NoRoute` and must never be presented
  as transfer success.
- Production LAN file sends go through the coordinator-injected
  `NetworkService` and return `NetworkResult`; do not add a legacy transport,
  HTTPS file fallback, compatibility adapter, or second implementation. Persist
  the actual direct/relay route and stable failure code in LAN history.
- Keep command acceptance separate from final operation state. Public callers
  consume typed `NetworkEvent` values; retry decisions use `NetworkErrorCode`,
  never diagnostic message text.
- Register peer endpoints and pinned Ed25519/X25519 keys before connect.
  `PathManager` selection must drive the endpoint used by Quinn.
- Run blocking native event polling on a helper isolate. Stop the isolate and
  wait for its exit before destroying the Rust runtime handle.
- QUIC peer handshakes must bind the expected device identity and public key,
  protocol version, both fresh nonces, and both transcript signatures.
- Discover STUN candidates from the same bound UDP socket later handed to
  Quinn. Never advertise unspecified or loopback addresses as peer candidates.
- Authenticate hole-punch request/response packets with a session key and fresh
  nonce; reject reflected requests and unauthenticated datagrams.
- File manifests require a single safe filename plus a mandatory SHA-256.
  Resume only from an exact partial-file length, reject early EOF and final-file
  overwrite, and atomically rename only after size and hash verification.
- The Go relay requires explicit strong enrollment, credential-signing, and
  dashboard admin secrets. Device proofs sign method, path, and a one-use nonce;
  credentials are valid only for matching enrollment in the current process.
- Treat `relay/compose.yaml` with Caddy as the only supported and documented
  Relay production deployment. Use one attached
  `docker compose --env-file .env up --build` invocation for startup and
  combined service logs; do not restore direct Go or standalone `docker run`
  deployment instructions.
- Relay WebSockets are connected only after a protocol-v1 `ready` frame.
  Forwarded transfer controls carry the server-bound authenticated `sender_id`;
  enforce sender/receiver roles and report transfer success only after the
  receiver returns `complete_ack`.
- Configure native Relay only after runtime identity and explicit enrollment
  exist. Keep a single Relay socket per device ID, consume incoming native
  offer/chunk/control events, require explicit approval, and delete partial
  files on rejection, cancellation, expiry, or authentication failure.
- Keep Dart Relay limited to `RelayEnrollmentService` for enrollment, secure
  credential storage, and native configuration. The native runtime owns the
  Relay data plane and end-to-end encryption; do not restore a Dart Relay
  WebSocket, chunk cipher, transport adapter, or SFTP Relay path.
- Keep relay frames and device state memory-only. Dashboard sessions use
  HttpOnly cookies, dynamic values use safe DOM APIs, and production clients
  connect through HTTPS/WSS with a valid certificate.

### Performance Monitor & System Administration

Primary entry points are
`packages/features/feature_monitoring/` for the maintained monitoring service,
models, probes, Ports, Module, and ViewModel; the old
`lib/features/performance/viewmodels/performance_viewmodel.dart`,
`lib/services/performance_monitor_service.dart`, and
`lib/services/server_status_probe.dart` paths are compatibility surfaces.
System Administration is maintained in
`packages/features/feature_system_admin/`; its App Shell bridge is
`apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart`, while
`lib/features/system_admin/**` and `lib/services/system_admin_service.dart`
remain compatibility surfaces.

- The System Admin Feature receives monitoring through its own small Capability
  contract and does not import Monitoring implementation or another Feature.
- `SystemAdminModule` owns the management SSH session and command cancellation;
  the AppRuntime continues to own the injected SSH, Storage, SFTP, logger, and
  Monitoring resources.

- The performance monitor is integrated as the default "Monitor" tab in the
  System Administration console.
- Performance monitoring is user-started, supports multiple servers, and keeps
  at most ten minutes of in-memory samples.
- `MonitoringModule.activate()` restores module availability but intentionally
  does not start polling; existing user/tool start actions remain the polling
  owner. `deactivate()` and `dispose()` cancel timers and subscriptions.
- Monitoring SSH requests carry the low-priority marker so interactive
  Terminal work does not share the same scheduling priority. The current legacy
  adapter has no scheduler of its own, so it preserves the marker and delegates
  to the existing one-shot SSH path.
- The Monitor tab keeps its own multi-server selection; every other System
  Administration tab shares `SystemAdminViewModel.selectedConnectionId`.
- Ports, Applications, and Services each operate on one selected server and
  fetch on open or manual refresh.
- Single-server snapshot lists do not repeat the selected-server summary.
  Keep Ports/Services mode selectors centered without embedding another
  trailing action in their content toolbar.
- Snapshot modes do not require root, enabling non-root Linux and Windows
  monitoring, while management tabs (Users, Sessions, Power) and management
  modes require root Linux connections.
- Root management connections must follow the selected connection. Do not let
  connect or async tab activation rewrite `selectedConnectionId`, and do not
  auto-run `refreshAllData()` after connect.
- Users and Sessions tabs must select their list/loading state from
  `SystemAdminViewModel`, and manual root retries must load the active tab.
  Management fetch debouncing must remain awaitable; forced `refreshAllData`
  calls must complete Accounts, Sessions, Services, and Ports without a shared
  timer canceling earlier work.
- Do not add a global Refresh All action to the System Administration tab bar;
  the fixed top-right refresh affordance sits beside (not inside) the scrollable
  server selector and dispatches only to the active Ports, Applications,
  Services, Users, or Sessions tab. Monitor and Power do not show that action.
  Avoid restoring the obsolete generic workspace header/status layer.
- Collect data with read-only one-shot SSH exec commands. Do not attach to tmux
  or interactive terminal sessions.
- Linux probes use `/proc` and `df -P`; Windows probes use the PowerShell JSON
  path in `ServerStatusProbe`.
- Sampling failures should back off cleanly and always clear in-progress flags.
- Decode large one-shot command output and parse monitor/system-admin result
  sets on background isolates; only final state assignment and notifications
  belong on the UI isolate.
- Keep the foreground/background service path active while monitoring is
  running.
- Health scores and alerts are in-memory only; the Servers page may show a
  lightweight health chip.
- `get_server_status` and `generate_ops_report` should reuse the same probe
  logic as the monitor UI.

### Navigation and Settings

- `apps/ssh_mobile_full/lib/app/app_runtime_factory.dart` composes App Scope
  infrastructure services; `AppRuntime` owns them and
  `apps/ssh_mobile_full/lib/main.dart` only delegates to `AppBootstrap`.
  `SshMobileApp` exposes existing Runtime instances through `MultiProvider`.
- `lib/features/settings/viewmodels/settings_viewmodel.dart` bridges
  `AppSettings` plus injected Feature/Core Ports, while `lib/features/home/views/home_screen.dart`
  remains the navigation shell and settings entry surface.
- Main page order is Servers, SFTP, AI, System Admin, then Logs, and app launch
  lands on Servers.
- The shell has no global top app bar. On desktop, the navigation rail's
  settings button opens app settings from every main page. On mobile, app
  settings remain reachable from the Servers page. The AI header's settings
  button opens LLM settings and stays separate from app settings.
- Keep deferred page activation so heavy pages mount only when selected.
- Keep SFTP and System Administration server selector chrome shared through
  `lib/widgets/server_selector.dart`; feature bindings own single/multi-select
  state, connection actions, and status semantics.
  It remains an app-layer compatibility widget for now because its current
  parameter type is the legacy Connection Feature model; do not move it into
  `app_ui` until a business-neutral public contract exists.
- Keep the AI chat page alive across page switches.
- Keep custom mobile navigation items exposed as a single semantic button with
  a localized label and selected state; exclude duplicate icon/text semantics.
- Use `MobileUiMetrics` from `packages/core/app_ui/` as the single source
  for mobile chrome and control density. Its 1280-1440 px physical-short-edge
  interpolation lightly tightens 1.5K layouts and reaches standard chrome at
  2K; never use it to scale the user's system text setting.
- Keep adaptive window thresholds centralized in `AppBreakpoints`: server
  grids require 720 dp, the expanded navigation rail starts at 840 dp, and
  heights below 480 dp use the icon-only compact rail. Portrait phone grid
  preferences must fall back to the reorderable list without changing the
  stored preference.
- Keep the mobile Servers settings action visible and at least 48 dp. List
  drag handles also stay 48 dp even when visual content uses mobile density
  correction; reserve enough bottom scroll padding for app navigation and the
  system inset.
- Compute drawer width with `settingsDrawerWidthFor` so viewports below 320 dp
  are never over-constrained. Settings lists add `MediaQuery.viewPadding.bottom`
  to their final padding, language rows announce the localized label and current
  value, and segmented layout choices use the available row width instead of a
  fixed trailing box.
- Backup/import/export covers saved servers, restorable windows, terminal
  history, AI settings, AI chats, AgentRunMetrics, Playbooks, SFTP
  recent/favorite paths, and custom skills, but never passwords, private keys,
  API keys, tokens, or other secrets.
- Backup imports must enforce size, count, field-length, and schema limits
  before replacing local state, and high-risk content such as playbooks,
  custom prompts, shortcuts, and AI skills must remain user-approved import
  surface.
- Fresh installs and missing preference fallbacks default to Chinese, light
  theme, and the Monochrome palette. Keep Monochrome, Indigo, Ocean, Emerald,
  Rose, and Amber palettes synchronized across Material and Shad themes and
  included in settings backup/import.
- Keep the app root subscribed only to the immutable visual-theme snapshot.
  Cache Material and Shad theme objects, avoid nested theme interpolation, and
  keep terminal font or other feature settings from rebuilding the app shell.
- On macOS, keep `flutter_secure_storage` configured to avoid Keychain
  entitlement error `-34018`.
- Background notifications hide server names by default. Only show them when
  the user enables the notification privacy setting.
- Platform app icons are generated by `tool/generate_app_icons.dart`. Keep the
  geometric source in that tool and `assets/app_icon.svg` visually aligned.

### Android Device Launch

`INSTALL_FAILED_USER_RESTRICTED` usually means the phone blocked USB install or
the user canceled the install prompt; it is not a compile failure when the APK
was already built.

## References

- Read [references/lessons.md](references/lessons.md) when the task touches LLM
  streaming, DeepSeek errors, SFTP reconnects, navigation animation, README
  encoding, or Android install/debug issues.
- Before finishing a code-change task, check whether `README.md` or this skill
  needs to change. When citing entry points, prefer the current
  `lib/features/*` ViewModel/view path plus the coordinating screen/service over
  older screen-only descriptions.
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
