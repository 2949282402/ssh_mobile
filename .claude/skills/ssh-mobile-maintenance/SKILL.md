---
name: ssh-mobile-maintenance
description: Use when modifying or debugging this SSH Mobile Flutter project, especially SSH/tmux sessions, SFTP file operations, AI chat, OpenAI-compatible LLM streaming, AI tool definitions, settings persistence, logs, navigation behavior, Android device launch/install failures, README updates, project documentation, shared agent memory, or the project skills used by Codex and Claude Code.
---

# SSH Mobile Maintenance

## Quick Start

Before changing code, inspect the existing pattern in `lib/screens/` and
`lib/services/`. Keep changes narrow and run validation afterward. Resolve the
local Flutter SDK dynamically; different machines may use different SDK
locations:

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

## Common Workflows

### LLM Chat and Tools

Use `lib/services/llm_chat_service.dart` for provider protocol behavior and
`lib/services/ai_tool_service.dart` for model-callable tools.

- Stream chat with SSE (`stream: true`) and surface chunks immediately to the UI.
- Tool calls may arrive split across multiple SSE deltas. Accumulate id, name,
  and argument fragments before executing tools.
- The chat input `+` toolbar should stay below the input row as a compact
  WeChat-like function panel. It exposes Server selection, the Skills manager,
  and the current chat session's WebView entry; do not re-add prompt templates
  or a temporary Skill picker to this panel unless the product direction changes.
- On Windows and macOS, the AI chat input uses desktop shortcuts: Enter sends
  the message and Ctrl+Enter inserts a newline. Keep mobile keyboard behavior
  independent so phone users can still enter multiline text naturally.
- The same toolbar includes a Skills entry that opens the custom AI Skills
  manager. Keep skill storage in `StorageService`, and keep the manager page
  theme-aware, bilingual, and flexible enough for SKILL.md-style content,
  references, templates, and maintenance notes. Custom skills have an enabled
  flag; disabled skills remain editable but should not appear in chat selection
  or be injected into request context. On compact mobile widths, use separate
  list/editor tabs instead of squeezing the skill list above the editor.
- Toolbar-selected target servers should be represented as user-message
  `contextText` rather than changing the main system prompt, so provider prompt
  caches stay useful.
- DeepSeek thinking mode can return `reasoning_content`. If the response has
  tool calls, pass `reasoning_content` back unchanged in the assistant tool-call
  message. Surface reasoning, tool requests, tool results, and approval outcomes
  as collapsed chat trace details, and include those trace details in
  assistant `contextText` memory so later turns can inspect server state. The
  LLM settings page exposes DeepSeek-only `thinking` and `reasoning_effort`
  controls; send those parameters only to DeepSeek API hosts, not to generic
  OpenAI-compatible aggregators.
- Internet search for the LLM is exposed as an optional client-side
  `web_search` function tool backed by the current chat session's local
  WebView. Keep it disabled until the user enables it; return cited result URLs
  in the tool result. Do not rely on DeepSeek Chat Completions having hosted web
  search; its documented tools are function tools. OpenAI hosted web search
  should be handled by a separate Responses API adapter.
- AI WebView browsing uses a per-chat operation token. While the token is
  active, the WebView page is view-only and the user must tap Interrupt before
  manual address-bar, navigation, refresh, or page-touch actions are enabled.
- Client device tools must use the `client_` prefix, state clearly in their
  descriptions that they run on the SSH Mobile client device rather than a
  server, and return `execution: client`. Keep OS/device client tool logic in
  `ClientSystemToolService` instead of mixing it into SSH/SFTP code. Client
  tools currently cover time, device info, network info, battery status,
  opening app settings, clipboard writes, reminders, and current-chat WebView
  plain-text reading. Keep WebView session state in `ClientWebViewService`; it
  is keyed by AI chat id, should survive returning from the WebView route, and
  should be cleared when that chat history is deleted. Client reminders may use
  in-memory local notifications; Android system alarms should go through the
  native `ssh_mobile/client_system` MethodChannel and
  `AlarmClock.ACTION_SET_ALARM`. Android-only client diagnostics such as
  network and battery details should return a graceful unsupported payload on
  other platforms.
- Track context window usage with the selected 259K, 512K, or 1M limit. When
  estimated usage reaches 90%, call the current model to summarize older
  history before continuing the user request. Keep token estimation out of the
  hot build path by caching per active chat/message fingerprint.
- Keep the primary system prompt stable for cache hits. If old history is
  compressed, pass the summary as a normal assistant memory message instead of
  injecting dynamic system text.
- Preserve full chat display text, but avoid sending every stored byte back to
  the model. Long generated documents, HTML, or multi-code-block outputs should
  use compact message context such as `AiChatMessageRecord.contextText`.
- When editing a past user message or regenerating an assistant reply, truncate
  messages after that point and regenerate fresh assistant text, traces, token
  stats, and `contextText`. Chat branches should copy messages through the
  selected assistant reply and continue with the same context slimming rules.
- New AI page entries should open an unsaved empty draft chat by default.
  Persist the chat only after the user sends a message.
- Add a second confirmation step for destructive/rewrite actions on the AI chat
  page: both branch creation and assistant reply regeneration should require
  explicit user confirmation before executing.
- Store per-assistant-message token and elapsed-time metadata and render it as
  small, low-emphasis text below the message bubble.
- Throttle streaming UI updates so small SSE chunks do not rebuild Markdown on
  every token. Markdown is rendered during streaming for readability, so keep
  visible updates batched and avoid adding extra work to the hot message build
  path. During streaming, throttle context-token estimation, coalesce
  scroll-to-bottom requests, jump instead of animating repeated streaming
  scrolls, and avoid resorting the chat list for every partial assistant
  update. Keep history drawer slide/drag animation local to the overlay rather
  than rebuilding the whole chat page each frame.
- Tool rounds are intentionally unbounded; if a model loops, rely on the chat
  stop button and inspect whether the command whitelist blocks reasonable
  read-only discovery commands.
- Keep a visible stop button during LLM streaming. Cancelling should close the
  active HTTP stream, reject any pending tool approval, and save the partial
  assistant message with a cancellation trace.
- If adding write-capable tools, preserve the approval gate: show the exact
  server and command in the chat page, execute only after approval, and let
  rejection abort the current operation so the user can give new instructions.
- Write-command approval panels must keep their action buttons visible. Put
  long commands in a bounded vertical/horizontal scroll area instead of letting
  the command text determine the panel height.
- Keep AI command execution on the plain one-shot SSH exec path. Do not attach
  tmux or reuse interactive terminal sessions for LLM tools.
- AI tools must handle Windows and Linux/Unix targets. Use the saved
  `serverPlatform` when available, and call `detect_os` before emitting
  OS-specific commands when the target is still unclear. Keep Windows
  diagnostics read-only by default (`cmd /c ver`, `dir`, `type`, `tasklist`,
  `netstat`, `ipconfig`, safe PowerShell `Get-*` queries), keep non-delete
  write operations behind the existing approval gate, and keep delete/remove
  operations blocked.
- AI one-shot diagnostic commands may search slow paths on real servers, so
  their timeout should be user-configurable, shared with LLM request timeouts,
  and should return a tool result explaining the timeout instead of crashing the
  chat turn. Chat timeout errors should offer a Continue action that sends a
  short follow-up from the existing context rather than forcing regeneration.

### SFTP

Use `lib/services/sftp_service.dart` for connection/session behavior and
`lib/screens/sftp_*.dart` for UI.

- Keep multi-server switching warm when possible.
- Remember the last remote path per connection and restore it after reconnect.
- Let users collapse the SFTP server selector after choosing a server. On
  desktop, preserve a narrow status rail; on mobile, preserve a compact current
  server bar so users can expand it again without losing context.
- Require typed-name confirmation before SFTP delete. The user must enter the
  exact file or directory name, and `SftpService.deleteEntry` must receive and
  verify that name before deleting.
- Prefer separate editor/viewer pages for larger editing and previews.
- Normal SFTP downloads may be larger than preview/edit files; keep preview and
  editor limits protective, but allow ordinary file downloads up to the current
  download cap.
- The settings drawer owns client-side SFTP limits for normal downloads, text
  preview, rich preview, and text editing. Read those values from
  `AppSettings` at the UI entry points instead of hardcoding service constants
  into screens.
- Keep upload, download, edit, delete, preview behavior aligned across mobile,
  Windows, and macOS.

### Performance Monitor

Use `lib/services/performance_monitor_service.dart` for sampling,
`lib/services/server_status_probe.dart` for read-only Linux status commands and
parsers, and `lib/screens/performance_monitor_screen.dart` for UI. The monitor
page uses the same server selector/collapse pattern as SFTP, supports
multi-select on the Performance tab, and must stay silent until the user taps
Start. Starting monitoring freezes the selected server set for that run,
collapses the server selector, clears previous samples, and creates fresh
in-memory series for the selected servers. Keep at most ten minutes of samples
in memory and never persist monitor samples.

Collect server metrics with read-only one-shot SSH exec commands; do not attach
to tmux or interactive terminal sessions. Dispatch by the saved server platform:
Linux reads `/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`,
and `df -P`; Windows uses the PowerShell status probe in `ServerStatusProbe` and
parses CPU, memory, disk usage, listening ports, and process memory from its JSON
payload. The performance page has three internal tabs: Performance, Ports, and
Applications. Performance sampling is user-started and app-scoped; Ports and
Applications only allow one selected server each and keep their selections
isolated from Performance and from each other. They only fetch when their tab is
opened or refreshed. Starting
performance monitoring should collapse the configuration panel and show elapsed
monitoring time in the collapsed header. Disk usage and individual line charts
should be collapsible. Multi-server charts should support grouping by a
user-selected number of servers per chart, with 1, 3, and 5 as presets plus a
custom count. Sampling failures should back off by increasing the effective
refresh interval and should not show noisy banners while the user is working.
Keep the performance command tolerant of `df` variants: some BusyBox/minimal
Linux systems do not support `df -B1`, so parse usable `/proc` output even when
the disk-usage subsection has to fall back or is unavailable. Always clear
sampling-in-progress flags in a `finally` path so a failed probe cannot block
future samples. If a one-shot SSH probe is interrupted by a transient network
drop, retry once with a fresh one-shot SSH connection before surfacing the
sampling failure.
Keep the existing foreground background service/power-lock path active when
monitoring starts so sampling has the best chance to continue when the app is
backgrounded.

Port monitor rows should show compact port/process summaries by default and
keep address, protocol, state, and process details collapsed until the user
expands the row. Ports and Applications refresh buttons should be disabled
while their current fetch is still in flight.

The monitor service also owns lightweight in-memory health state. Health scores
combine the latest sample, disk usage, and sampling errors; recent alerts should
stay in memory only and be lightly deduplicated so threshold crossings do not
spam the UI. The Servers page may show the latest health chip from the monitor
service, but it should keep using lightweight snapshots outside Sliver item
builders instead of watching the full service inside each card.

The `get_server_status` AI tool should use `ServerStatusProbe` so LLM-accessible
server status matches the monitor page parsers. Keep this tool read-only and on
the one-shot SSH exec path. `generate_ops_report` should also stay read-only,
reuse `ServerStatusProbe`, and return structured health, risk, port, and process
data so the model can write a user-facing operations report.

### Navigation and Chat UX

Current main page order is AI, Servers, SFTP, Performance Monitor, then Logs.
Terminal window management is embedded in the Servers page: each server card has
a default-collapsed window section that lists only that server's terminal
windows, and the connection history action sits in the server/window overview
header. The mobile bottom navigation and desktop rail show AI, Servers, SFTP,
and Performance Monitor; Logs sits at the far right in the `PageView`. App
launch still defaults to the Servers page even though AI is the first navigation
item.

The app shell does not use a global top app bar. App settings live in the left
drawer, with the app title shown inside the drawer. Open app settings from the
AI page's explicit App settings button instead of a left-edge drawer gesture, so
the main `PageView` can keep horizontal page swiping on the AI page. Keep the
LLM settings button separate from app settings. AI chat history must open only
via the top-left history button and should display as a full-width overlay with
an explicit close button.

Mobile bottom navigation is persistent by default. Do not reintroduce automatic
collapse unless the product direction changes. Keep mobile UI density adapted
through `lib/utils/responsive.dart` so 1.5K-class phones do not render
noticeably larger than 2K-class phones.

Use deferred page activation for the main `PageView` so adjacent pages stay
blank and do not mount their data subscriptions until they are selected. While
a selected page is activating, show only the shared centered loading indicator.
The AI page should load only settings and an unsaved draft on first activation;
after it has been opened, keep the active draft/chat widget state alive across
navigation page switches. Saved chat history is loaded lazily when the history
panel is opened, with a blank panel body and loading indicator during the read.

For smooth page swiping, keep heavy work out of drag time: pass an `active` flag
to heavyweight pages, load AI chat history only after the page settles active,
wrap page bodies in `RepaintBoundary`, pause non-selected page tickers with
`TickerMode`, and keep page-specific Provider `select` calls inside the page
body instead of the top-level `HomeScreen` shell.

For log-heavy flows, keep `AppLogService.entries` and level counts cached until
the log queue changes. Avoid recomputing reversed log lists and per-level counts
inside `DeveloperLogPage.build`. Coalesce log notifications so noisy SSH/LLM
diagnostics do not rebuild the log page for every single line. Keep filtered log
lists and entry id sets cached in `AppLogService` rather than rebuilding them in
the log page. Do not capture a fresh current stack trace for intercepted
`debugPrint` lines or background-isolate log relays; those high-frequency logs
should skip source lookup unless an explicit stack trace is already available.

Coalesce SFTP service notifications during connect, refresh, upload, download,
save, and delete flows. State should still update immediately in memory, but UI
listeners should not be notified multiple times inside the same frame-sized
window.

Avoid allocation-heavy service getters in widgets that use Provider `select`.
Cache stable unmodifiable views for connection and SSH session collections, and
refresh those views only when the underlying collection membership or visible
metadata changes. Server overview cards should select a lightweight session
summary rather than the full `SshSession` list, so terminal window rename/font
changes do not rebuild the whole server list.

The embedded terminal windows list should select immutable window snapshots with
value equality instead of the raw `SshSession` list, so `SshService` view
refreshes do not rebuild the list unless displayed window metadata actually
changed.

Batch terminal history writes before encrypting and appending them to disk.
Encrypting every small stdout/stderr chunk can cause terminal jank on noisy SSH
sessions even when the visible terminal renderer is frame-throttled.
Keep terminal visible writes capped per frame so large command output cannot
monopolize rendering. Keep the interactive xterm scrollback bounded and avoid
rebuilding the terminal view for scrollbar metric changes; full raw output
belongs in encrypted terminal history. Shortcut key usage tracking should
persist in the background without notifying the shortcut panel on every key tap.
The visible shortcut bar uses a saved manual order, not LRU sorting; long-press
dragging reorders commands, and custom commands still need an explicit delete
path. Terminal font controls intentionally allow a very small minimum size so
phone users can trade readability for denser terminal output when needed.

Use keyed animations for chat switching. Avoid an `AnimatedSwitcher` around a
`ListView` that shares a `ScrollController`, because it can briefly mount two
lists with the same controller.

Use `AutomaticKeepAliveClientMixin` for the AI chat page so streaming responses
continue while the user switches to another navigation page.

Keep `StorageService` list data cached for AI chats, AI skills, tmux restore
records, and terminal history records. High-frequency saves should mutate the
cached list and write it back, rather than decoding the full JSON payload before
every single save. Debounce those list writes and flush pending protected-pref
writes when the app enters inactive/paused/detached lifecycle states.

Terminal pages should select only the active session metadata needed by the
app bar. Avoid `context.watch<SshService>()` in the terminal screen body,
because unrelated session metadata notifications can otherwise rebuild the
whole terminal chrome.

Open the settings drawer only from the settings icon, not from a Servers-page
swipe; horizontal swipes on Servers should continue to page navigation. Keep
data export/import there. Backup JSON should include saved servers, restorable
windows, terminal history, AI settings, AI chats, and custom skills, but must
not export passwords, private keys, API keys, tokens, or other secrets. Imports
should leave those credential fields empty so users reconfigure them.

Fresh installs and missing preference fallbacks should default to Chinese and
light theme. Preserve saved user language/theme preferences during startup.

On macOS, configure `flutter_secure_storage` with
`MacOsOptions(usesDataProtectionKeychain: false)` for v10+ or
`MacOsOptions(useDataProtectionKeyChain: false)` for older versions unless the
Xcode project also carries the required Data Protection Keychain signing
entitlements; otherwise saving server passwords, private keys, or API keys can
fail with Keychain error `-34018`.

On the AI page, a clear left-edge-to-right swipe should open the chat history
panel from the left with a finger-tracking slide, without blocking normal
horizontal page navigation.

### Android Device Launch

`INSTALL_FAILED_USER_RESTRICTED` usually means the phone blocked USB install or
the user canceled the install prompt. It is not a Gradle or Flutter compile
failure when the APK was already built successfully.

## References

Read [references/lessons.md](references/lessons.md) when the task touches LLM
streaming, DeepSeek errors, SFTP reconnects, navigation animation, README
encoding, or Android install/debug issues.

Before finishing any code-change task, check whether `README.md` or this skill
needs to change. Prefer small documentation updates over letting docs drift.
