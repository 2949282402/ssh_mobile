---
name: ssh-mobile-maintenance
description: Use when modifying or debugging this SSH Mobile Flutter project, especially SSH/tmux sessions, SFTP file operations, AI chat, OpenAI-compatible LLM streaming, AI tool definitions, settings persistence, logs, navigation behavior, Android device launch/install failures, README updates, project documentation, shared agent memory, or the project skills used by Codex and Claude Code.
---

# SSH Mobile Maintenance

## Quick Start

Before changing code, inspect the existing pattern in `lib/screens/` and
`lib/services/`. Most large screens and services are split with `part` files
under feature folders, so follow the nearest feature's composition style rather
than adding new flat files. Keep changes narrow and run validation afterward.
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
<<<<<<< HEAD
- Keep source and docs in UTF-8 without BOM.
- Prefer existing services and interfaces over duplicating protocol logic.
- Route SSH, SFTP, LLM, AI tool, and failure logs through `AppLogService`.
- Keep shared UI behavior aligned with `lib/theme/app_theme.dart` and
  `AppSettings`.
- Validate SSH credentials before saving a server.
- Respect `serverPlatform`: Linux can use tmux; native Windows servers use plain
  SSH unless the user is really targeting WSL or another Linux-like shell.
- Keep secrets out of exports, logs, AI tool results, and docs. Stored API keys
  and credentials belong in secure storage, not plain preferences.
- When features, navigation, settings, tools, or platform behavior change,
  update this skill and `README.md` in the same task.
- Keep `.agents/.../SKILL.md` and `.claude/.../SKILL.md` synchronized with
  `scripts/sync_agent_skills.ps1`.
=======
- Use UTF-8 for all source and data files. Avoid UTF-8 with BOM, and when writing or rewriting files, enforce UTF-8 (without BOM) encoding to prevent string corruption.
- Prefer project services over duplicating protocol code.
- Prefer the exposed service contracts (`SshClientAdapter`, `SftpClientAdapter`,
  `LlmClientAdapter`, `AiToolExecutor`, and storage repository interfaces) when
  adding controllers or tests so fake implementations can replace real network
  and credential-backed services.
- Write logs for SSH, SFTP, LLM requests, AI tools, and caught failures through
  `AppLogService` so the log page remains useful.
- Log entries should include a source file/line location when possible, and log
  page interactions should preserve long-press multi-select with batch delete.
- AI chat UI failures, settings save/refresh failures, missing or invalid API
  keys, and model request errors should all be visible in the log page with
  secrets redacted.
- Keep mobile, Windows, and macOS behavior consistent for shared SSH/SFTP
  features.
- When adding or editing a saved server, validate the SSH login with the
  submitted host, port, username, password, and/or private key before saving.
  On failure, keep the user on the form and guide them to correct the
  connection details.
- Saved servers include a `serverPlatform` selection, defaulting to Linux.
  Windows servers must use plain SSH mode in the app; native Windows OpenSSH
  does not provide tmux unless the user is really connecting to WSL or another
  Linux-like shell with tmux installed.
- Keep new UI consistent with `lib/theme/app_theme.dart`: use the app theme for
  colors, card surfaces, drawers, bottom sheets, segmented controls, expansion
  tiles, scrollbars, progress indicators, button/input/list/navigation styling,
  and avoid page-local palettes unless a protocol view such as the terminal
  requires it.
- Keep the main application font family centralized in `AppSettings` and
  `AppTheme`. Do not set unrelated page-local font families for normal UI text;
  vary only size, weight, color, and emphasis. If adding font choices, prefer
  system-installed or clearly open-licensed fonts, and do not bundle or
  redistribute font files unless the license has been verified and documented.
- Prevent Flutter `RenderFlex overflowed ... on the bottom` regressions: dialogs,
  bottom input panels, keyboard-adjacent controls, compact mobile editors, and
  expandable toolbars must be wrapped in `SingleChildScrollView`, `ListView`, or
  otherwise bounded with `Expanded`/`Flexible` so small screens, landscape,
  large fonts, and IME insets cannot make a `Column` exceed its parent.
- When text cannot be fully displayed, prefer making that region scrollable
  before shrinking fonts or hiding content. For long unbroken text such as file
  paths, commands, API errors, stack traces, model names, and logs, use a
  scrollable text container such as `OverflowScrollText` over clipping or
  unreadable ellipsis. Use wrapping text for prose, but horizontal scrolling for
  machine strings that users need to inspect or copy exactly.
- Keep model configuration in the LLM settings dialog. Do not add another model
  selector on the chat page. On mobile, prefer the dedicated settings page over
  an `AlertDialog` so saving API keys does not collide with route teardown.
- In LLM settings, a blank API key field means "keep the saved key". Require an
  explicit clear action before deleting the stored API key so model or base URL
  changes cannot wipe credentials accidentally.
- Cache fetched LLM model lists locally per Base URL and reuse that cache when
  reopening settings; the refresh button should update the cache explicitly
  instead of forcing a network fetch on every visit.
- Keep LLM settings provider-aware: Base URL history is local plain-text
  history, API key history is stored in secure storage with masked previews,
  DeepSeek thinking controls appear only for DeepSeek-like model ids, and
  OpenAI reasoning effort controls appear only for supported OpenAI reasoning
  model ids.
- Keep AI server tools safe by default: read-only diagnostics run directly, any
  command that may write or change server state must pause for explicit human
  approval in the chat page, and credential exposure remains blocked.
- AI `run_command` must enforce the saved server platform. Linux servers accept
  Linux/POSIX diagnostics; Windows servers require explicit `cmd /c` or
  PowerShell/pwsh commands. Do not silently run a Linux command on Windows or a
  Windows command on Linux.
- Delete/remove commands are blocked for AI tools, even with user approval.
  This includes common Linux deletion commands, Windows `del`/`rd`/`Remove-*`,
  and resource deletion verbs such as `docker rm`, `kubectl delete`, `sc delete`,
  and `reg delete`.
- If a Windows tool command returns an access-denied/elevation error, return a
  clear permission message explaining that the current account lacks permission
  and that the user needs an Administrator/elevated account or explicit access.
- When code changes add, remove, rename, or materially change files, features,
  navigation entries, settings, AI tools, dependencies, or platform behavior,
  update this skill and `README.md` in the same task so documentation stays in
  sync with the project.
- Codex reads `.agents/skills/ssh-mobile-maintenance/SKILL.md`; Claude Code
  discovers `.claude/skills/ssh-mobile-maintenance/SKILL.md`. Keep those two
  skill files synchronized with `scripts/sync_agent_skills.ps1`. Prefer
  `-Mode Link` on Windows workspaces so edits to either path affect the same
  physical file; use `-Mode Check` before finishing skill changes.
- Treat `AGENT_MEMORY.md` as the shared durable memory surface for Codex and
  Claude Code. It is not runtime model memory, so store only concise, non-secret
  project notes that should survive across sessions.
- Windows installer packaging uses WiX Toolset v3 through
  `scripts/build_windows_msi.ps1` and `installer/windows/Product.wxs`; keep
  README build instructions aligned if MSI identity, output naming, shortcuts,
  or signing behavior changes.
- Android release builds disable cleartext traffic by default. Keep debug and
  profile cleartext allowances only for local provider testing, and do
  not re-enable release cleartext without a documented network-security reason.
- When writing or changing code, add concise maintenance comments for non-obvious
  behavior, lifecycle constraints, protocol quirks, safety gates, or context
  management decisions. Avoid noisy comments that only restate the code.
- Optimize RAG storage by partitioning the database: keep document lists and lightweight metadata in `rag_metadata.json` and store heavy text chunks and embeddings in separate document-specific files (`rag_doc_[docId].json`). Always offload heavy operations (such as similarity calculations, BM25 indexing, and JSON encoding/decoding) to background Isolates via `compute()`.
- Implement caching for SFTP directory entries with an appropriate Time-To-Live (TTL, e.g., 30 seconds) to avoid redundant network fetch on frequent navigation. Downloaded files and image thumbnails should be cached using SHA-256 keyed temporary files, and checked against remote file size/modified timestamp before reusing them.
- Avoid memory growth and UI chart lag in Performance Monitor by downsampling historical metrics data. Group and average samples (e.g. into 10-second averages) when data points grow older than a threshold (e.g. 5 minutes).
- Limit the size of developer logs using an auto-rotation strategy (e.g. max 5MB per file, rotating up to 3 archive files) to prevent local storage bloat, and perform log file writes asynchronously using a queue.

>>>>>>> 4b1dcc59f0cd32d1daff6a438b0c1d8810e30ef2

## Current Product Shape

### LLM Chat and Tools

Primary entry points are `lib/services/llm_chat_service.dart`,
`lib/services/ai_tool_service.dart`, and `lib/screens/llm_chat_screen.dart`
with its `lib/screens/llm_chat/` part files.

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
- State-changing tool actions must pause for the generic approval UI. Keep the
  approval model broader than `run_command`.
- `run_command` uses one-shot SSH exec, respects `serverPlatform`, and blocks
  delete/remove operations even when approval exists.
- Client-side tools stay in `ClientSystemToolService` and
  `ClientWebViewService`, use the `client_` prefix, and return
  `execution: client`.
- Route tool arguments, approvals, results, and trace content through
  `ToolSecretPolicy`.

### SFTP

Primary entry points are `lib/services/sftp_service.dart`,
`lib/screens/sftp_screen.dart`, and `lib/screens/sftp/`.

- Keep multi-server switching warm when practical.
- Restore the last remote path after reconnect.
- Require typed-name confirmation before delete.
- Use dedicated editor/viewer pages for larger previews and text edits.
- Read download, preview, and edit size limits from `AppSettings` instead of
  hardcoding screen-local constants.
- Keep upload, download, preview, edit, and delete behavior aligned across
  mobile, Windows, and macOS.

### Performance Monitor

Primary entry points are `lib/services/performance_monitor_service.dart`,
`lib/services/server_status_probe.dart`,
`lib/screens/performance_monitor_screen.dart`, and
`lib/screens/performance_monitor/`.

- The monitor page has four tabs: Performance, Ports, Applications, and
  Services.
- Performance monitoring is user-started, supports multiple servers, and keeps
  at most ten minutes of in-memory samples.
- Ports, Applications, and Services each operate on one selected server and
  fetch on open or manual refresh.
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

- Main page order is AI, Servers, SFTP, Performance Monitor, then Logs.
- App launch still lands on Servers even though AI is the first navigation item.
- The shell has no global top app bar. App settings open from the AI page's
  explicit settings button, and LLM settings stay separate.
- Keep deferred page activation so heavy pages mount only when selected.
- Keep the AI chat page alive across page switches.
- Backup/import/export covers saved servers, restorable windows, terminal
  history, AI settings, AI chats, and custom skills, but never passwords,
  private keys, API keys, tokens, or other secrets.
- Fresh installs and missing preference fallbacks default to Chinese and light
  theme.
- On macOS, keep `flutter_secure_storage` configured to avoid Keychain
  entitlement error `-34018`.

### Android Device Launch

`INSTALL_FAILED_USER_RESTRICTED` usually means the phone blocked USB install or
the user canceled the install prompt; it is not a compile failure when the APK
was already built.

## References

- Read [references/lessons.md](references/lessons.md) when the task touches LLM
  streaming, DeepSeek errors, SFTP reconnects, navigation animation, README
  encoding, or Android install/debug issues.
- Before finishing a code-change task, check whether `README.md` or this skill
  needs to change.
