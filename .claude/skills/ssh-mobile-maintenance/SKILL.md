---
name: ssh-mobile-maintenance
description: Use when modifying or debugging this SSH Mobile Flutter project, especially SSH/tmux sessions, SFTP file operations, AI chat, OpenAI-compatible LLM streaming, AI tool definitions, settings persistence, logs, navigation behavior, Android device launch/install failures, README updates, project documentation, shared agent memory, or the project skills used by Codex and Claude Code.
---

# SSH Mobile Maintenance

## Quick Start

Before changing code, inspect the nearest feature under `lib/features/`. The project now uses a pure feature-first MVVM split: feature-owned state/actions live in `viewmodels`, feature-owned models/forms live in `models` or `views`, UI view files live in `lib/features/<feature>/views/` along with their part files or child widgets in `widgets/`, and protocol/storage infrastructure stays in `lib/services/` plus `lib/core/services/`. Keep changes narrow and run validation afterward.
Resolve the local Flutter SDK dynamically; different machines may use different
SDK locations:

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter -and $env:FLUTTER_ROOT) {
  $candidates = @(
    (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'),
    (Join-Path $env:FLUTTER_ROOT 'bin/flutter')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      $flutter = $candidate
      break
    }
  }
}
if (-not $flutter) {
  throw 'Flutter SDK not found. Add flutter to PATH or set FLUTTER_ROOT.'
}
& $flutter analyze
& $flutter build apk --debug
```

Do not hardcode local SDK, toolchain, or resource absolute paths in source,
docs, skills, or memory. Prefer commands on `PATH`, environment variables such
as `FLUTTER_ROOT`, `ANDROID_HOME`/`ANDROID_SDK_ROOT`, and `JAVA_HOME`,
`xcode-select` on macOS, and repo-relative paths for repository resources.

Read `AGENT_MEMORY.md` before non-trivial code, documentation, or skill changes.
Update it with concise durable notes when a project decision, recurring pitfall,
or maintenance lesson should be shared across Codex and Claude Code sessions.

## Maintenance Rules

- Preserve user work in the git tree. Do not revert unrelated dirty files.
- Keep source and docs in UTF-8 without BOM.
- Prefer existing services and interfaces over duplicating protocol logic.
- Route SSH, SFTP, LLM, AI tool, and failure logs through `AppLogService`.
- Keep shared UI behavior aligned with `lib/theme/app_theme.dart` and
  `AppSettings`.
- Build primary workspaces from the shared design system in
  `lib/theme/app_theme.dart` and `lib/widgets/app_surface.dart`. Prefer
  `AppPageSurface`, `AppPageHeader`, `AppIconBadge`, and `AppEmptyState` over
  page-local colors, shadows, icon tiles, and empty-state layouts.
- Validate SSH credentials before saving a server.
- Respect `serverPlatform`: Linux can use tmux; native Windows servers use plain
  SSH unless the user is really targeting WSL or another Linux-like shell.
- Keep secrets out of exports, logs, AI tool results, and docs. Stored API keys
  and credentials belong in secure storage, not plain preferences.
- Growth-oriented structured data belongs behind repository interfaces and the
  `StorageService` facade, with Drift implementations under `lib/data/`.
  Small settings stay in SharedPreferences; credentials stay in secure storage.
  Drift metadata may be plaintext for query/sort needs, but sensitive AI
  message content, context, attachments, traces, todoSteps, and Playbook content
  must be field-encrypted before SQLite writes. Production database open
  failures must not silently fall back to an in-memory database. Legacy
  plaintext Drift rows from the initial migration must be re-encrypted by
  `drift_sensitive_fields_encrypted_v1` before considering storage migration
  complete. That startup re-encryption runs in small retryable batches, marks
  completion only after all batches succeed, and logs row counts only.
- Keep SSH Host Key checks centralized in `SshHostKeyPolicy`. UI-initiated
  first use may prompt for TOFU confirmation, but AI tools and background SSH
  service code must never auto-trust unknown or changed host keys.
- When features, navigation, settings, tools, or platform behavior change,
  update this skill and `README.md` in the same task.
- Keep `.agents/.../SKILL.md` and `.claude/.../SKILL.md` synchronized with
  `scripts/sync_agent_skills.ps1`.

## Current Product Shape

### Connections and Terminal

Primary entry points are `lib/features/connection/models/connection.dart`,
`lib/features/connection/viewmodels/connection_viewmodel.dart`,
`lib/features/connection/views/add_edit_screen.dart`,
`lib/features/terminal/viewmodels/terminal_viewmodel.dart`,
`lib/features/home/views/home_screen.dart` (along with its `widgets/` part files), and `lib/features/terminal/views/terminal_screen.dart` with
their `widgets/` part files.

- Keep saved-connection CRUD, validation, and verify-before-save flow in
  `ConnectionViewModel` plus repository/service seams rather than burying that
  logic in page widgets.
- Terminal session orchestration belongs in `TerminalViewModel` and
  `SshService`; keep screen state limited to layout, route args, and short-lived
  UI affordances.
- Window names stay stable because they bind tmux or plain-session restoration
  state.

### LLM Chat and Tools

Primary entry points are `lib/features/ai_chat/viewmodels/ai_chat_viewmodel.dart` (split into approvals and slash command extensions),
`lib/features/ai_chat/services/`, `lib/services/llm_chat_service.dart`,
`lib/services/ai_tool_service.dart` (with `client_tools.dart` split into schema and impl files), and `lib/features/ai_chat/views/llm_chat_screen.dart`
with its `widgets/` part files.

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
  MCP clients must not silently execute write/destructive tools and should get
  `approval_required` until an app approval queue exists.

### SFTP

Primary entry points are `lib/features/sftp/viewmodels/sftp_viewmodel.dart`,
`lib/services/sftp_service.dart`, and `lib/features/sftp/views/sftp_screen.dart` with
its `views/` parts.

- Keep multi-server switching warm when practical.
- Restore the last remote path after reconnect.
- Recent and favorite SFTP paths are per server and Drift-backed. Keep them out
  of the SFTP protocol layer; record successful directory opens through the
  service/facade path.
- Require typed-name confirmation before delete.
- Use dedicated editor/viewer pages for larger previews and text edits.
- Read download, preview, and edit size limits from `AppSettings` instead of
  hardcoding screen-local constants.
- Encrypt SFTP preview/download cache files with `DataProtectionService`.
  Secret-bearing paths such as `.ssh`, `.env`, private keys, token files,
  cloud credential folders, `/etc/shadow`, `/etc/sudoers`, and
  `/proc/*/environ` must not be cached.
- Delete SFTP cache when a saved connection is removed or explicitly forgotten.
- Keep upload, download, preview, edit, and delete behavior aligned across
  mobile, Windows, and macOS.

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
- Snapshot modes do not require root, enabling non-root Linux and Windows
  monitoring, while management tabs (Users, Sessions, Power) and management
  modes require root Linux connections.
- Root management connections must follow the selected connection. Do not let
  connect or async tab activation rewrite `selectedConnectionId`, and do not
  auto-run `refreshAllData()` after connect.
- Collect data with read-only one-shot SSH exec commands. Do not attach to tmux
  or interactive terminal sessions.
- Linux probes use `/proc` and `df -P`; Windows probes use the PowerShell JSON
  path in `ServerStatusProbe`.
- Sampling failures should back off cleanly and always clear in-progress flags.
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
- Keep the AI chat page alive across page switches.
- Keep custom mobile navigation items exposed as a single semantic button with
  a localized label and selected state; exclude duplicate icon/text semantics.
- Backup/import/export covers saved servers, restorable windows, terminal
  history, AI settings, AI chats, AgentRunMetrics, Playbooks, SFTP
  recent/favorite paths, and custom skills, but never passwords, private keys,
  API keys, tokens, or other secrets.
- Backup imports must enforce size, count, field-length, and schema limits
  before replacing local state, and high-risk content such as playbooks,
  custom prompts, shortcuts, and AI skills must remain user-approved import
  surface.
- Fresh installs and missing preference fallbacks default to Chinese and light
  theme.
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
