---
name: ssh-mobile-maintenance
description: Maintain and debug the SSH Mobile Flutter repository, including architecture, UI, SSH/SFTP, monitoring, AI tools, storage, security, platform builds, tests, and project documentation. Use for any non-trivial code, debugging, validation, documentation, or shared-agent-guidance change in this repository.
---

> 最新更新时间：2026-08-03

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

<<<<<<< HEAD
### LLM Chat and Tools

Primary entry points are `lib/features/ai_chat/viewmodels/ai_chat_viewmodel.dart`
and its focused extensions, `lib/features/ai_chat/services/`,
`lib/services/ai_tool_service.dart` and its functional modules, and
`lib/features/ai_chat/views/llm_chat_screen.dart` with its focused widgets.

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
- Client-side tools stay in `ClientSystemToolService` and
  `ClientWebViewService`, use the `client_` prefix, and return
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
- The local MCP Server lives in `lib/services/mcp/` and is implemented in
  Flutter/Dart, not native runners. It binds only to local hosts, serves
  Streamable HTTP JSON-RPC at `POST /mcp`, stores its Bearer token in secure
  storage, and reuses `AiToolService` through `McpToolExposurePolicy`; external
  MCP clients must not silently execute write/destructive tools. They enter the
  in-memory `McpApprovalQueue` and wait for approval from the local MCP Console;
  the queue is cleared when the MCP server stops and is never persisted. This
  boundary is not user-disableable: settings show it as locked, legacy false
  preferences are migrated to true, and the policy must still reject stale or
  injected false values.
- The Windows/macOS-only console is the `mcp_console` feature. Keep status, port
  checks, loopback authenticated self-tests, configuration copying, policy
  snapshots, redacted local activity, and the dedicated approval queue page
  under this feature. MCP activity is capped at 500 Drift records and must
  never include tokens, request arguments, tool output, peer/origin data,
  remote-resource details, or raw exceptions; it is not a backup-export
  payload. Approval previews must use the existing `AiToolApprovalRequest`
  redaction path and must not expose raw tool arguments.

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

Primary entry points are
lib/features/lan_share/lan_share_feature_scope.dart,
lib/features/lan_share/services/lan_receiver_coordinator.dart,
lib/features/lan_share/viewmodels/lan_share_viewmodel.dart,
lib/features/lan_share/views/lan_pairing_navigation_host.dart,
lib/features/lan_share/views/lan_pairing_screen.dart, and
lib/services/lan_share/lan_transfer_service.dart.

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

### Network Platform and Public Relay

Primary entry points are `native/network_core/`,
`packages/ssh_mobile_network_native/`, `lib/services/network/`,
`lib/services/relay/`, `lib/features/lan_share/views/vpn_p2p_share_view.dart`,
and `relay/`.

- Version every Dart/Rust FFI command and event. Unsupported versions must
  produce an explicit error; an unimplemented native route must return
  `NoRoute` and must never be presented as transfer success.
- Production LAN file sends go through the coordinator-injected
  `TransferTransport`; do not add an HTTPS/legacy file fallback during active
  development. Persist the actual direct/relay route and failure in LAN history.
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
- Keep relay frames and device state memory-only. Dashboard sessions use
  HttpOnly cookies, dynamic values use safe DOM APIs, and production clients
  connect through HTTPS/WSS with a valid certificate.

### Performance Monitor & System Administration

Primary entry points are
`lib/features/performance/viewmodels/performance_viewmodel.dart`,
`lib/services/performance_monitor_service.dart`,
`lib/services/server_status_probe.dart`, and
`lib/features/system_admin/views/system_admin_screen.dart` with
its child widgets.

- The performance monitor is integrated as the default "Monitor" tab in the
  System Administration console.
- Performance monitoring is user-started, supports multiple servers, and keeps
  at most ten minutes of in-memory samples.
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

- `lib/main.dart` composes infrastructure services and feature ViewModels
  through `MultiProvider`.
- `lib/features/settings/viewmodels/settings_viewmodel.dart` bridges
  `AppSettings` plus `StorageService`, while `lib/features/home/views/home_screen.dart`
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
- Keep the AI chat page alive across page switches.
- Keep custom mobile navigation items exposed as a single semantic button with
  a localized label and selected state; exclude duplicate icon/text semantics.
- Use `MobileUiMetrics` from `lib/utils/responsive.dart` as the single source
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
=======
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
>>>>>>> 48c06d47d96beeaa989fc2e41c8fb085bab717c0
