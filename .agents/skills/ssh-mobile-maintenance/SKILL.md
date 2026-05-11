---
name: ssh-mobile-maintenance
description: Use when modifying or debugging this SSH Mobile Flutter project, especially SSH/tmux sessions, SFTP file operations, AI chat, OpenAI-compatible LLM streaming, AI tool definitions, settings persistence, logs, navigation behavior, Android device launch/install failures, README updates, or project documentation.
---

# SSH Mobile Maintenance

## Quick Start

Before changing code, inspect the existing pattern in `lib/screens/` and
`lib/services/`. Keep changes narrow and run validation afterward:

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
& 'E:\coding\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat' analyze
& 'E:\coding\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat' build apk --debug
```

If the local Flutter SDK path is different, discover it instead of hardcoding a
new path in source or docs.

## Maintenance Rules

- Preserve user work in the git tree. Do not revert unrelated dirty files.
- Prefer project services over duplicating protocol code.
- Write logs for SSH, SFTP, LLM requests, AI tools, and caught failures through
  `AppLogService` so the log page remains useful.
- Log entries should include a source file/line location when possible, and log
  page interactions should preserve long-press multi-select with batch delete.
- AI chat UI failures, settings save/refresh failures, missing or invalid API
  keys, and model request errors should all be visible in the log page with
  secrets redacted.
- Keep mobile, Windows, and macOS behavior consistent for shared SSH/SFTP
  features.
- Keep new UI consistent with `lib/theme/app_theme.dart`: use the app theme for
  colors, button/input/list/navigation styling, and avoid page-local palettes
  unless a protocol view such as the terminal requires it.
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
- When code changes add, remove, rename, or materially change files, features,
  navigation entries, settings, AI tools, dependencies, or platform behavior,
  update this skill and `README.md` in the same task so documentation stays in
  sync with the project.
- Windows installer packaging uses WiX Toolset v3 through
  `scripts/build_windows_msi.ps1` and `installer/windows/Product.wxs`; keep
  README build instructions aligned if MSI identity, output naming, shortcuts,
  or signing behavior changes.
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
  WeChat-like function panel. It currently exposes only Server selection and the
  Skills manager entry; do not re-add prompt templates or a temporary Skill
  picker to this panel unless the product direction changes.
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
  as collapsed chat trace details; keep them out of future model context.
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
- Store per-assistant-message token and elapsed-time metadata and render it as
  small, low-emphasis text below the message bubble.
- Throttle streaming UI updates so small SSE chunks do not rebuild Markdown on
  every token. Around 80ms per visible update keeps output responsive without
  making page switches stutter.
- While an assistant message is still streaming, render it as lightweight text
  and switch to Markdown after completion; continuous Markdown parsing is a
  common source of AI-page jank.
- If users report `too many tool rounds`, inspect both tool loop limits and
  whether the command whitelist blocks reasonable read-only discovery commands.
- If adding write-capable tools, preserve the approval gate: show the exact
  server and command in the chat page, execute only after approval, and let
  rejection abort the current operation so the user can give new instructions.
- Write-command approval panels must keep their action buttons visible. Put
  long commands in a bounded vertical/horizontal scroll area instead of letting
  the command text determine the panel height.
- Keep AI command execution on the plain one-shot SSH exec path. Do not attach
  tmux or reuse interactive terminal sessions for LLM tools.
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
- Require confirmation before delete.
- Prefer separate editor/viewer pages for larger editing and previews.
- Keep upload, download, edit, delete, preview behavior aligned across mobile,
  Windows, and macOS.

### Navigation and Chat UX

Current main page order is AI, Servers, Windows, SFTP, then Logs. The mobile
bottom navigation and desktop rail show only AI, Servers, Windows, and SFTP;
Logs sits at the far right in the `PageView`. App launch still defaults to the
Servers page even though AI is the first navigation item.

Use lazy page construction for the main `PageView` so adjacent heavy pages such
as AI chat do not eagerly load large histories during startup or server-page
navigation.

For smooth page swiping, keep heavy work out of drag time: pass an `active` flag
to heavyweight pages, load AI chat history only after the page settles active,
wrap page bodies in `RepaintBoundary`, pause non-active page tickers with
`TickerMode`, and use Provider `select` in `HomeScreen` so unrelated storage
notifications do not rebuild the whole shell.

For log-heavy flows, keep `AppLogService.entries` and level counts cached until
the log queue changes. Avoid recomputing reversed log lists and per-level counts
inside `DeveloperLogPage.build`.

Avoid allocation-heavy service getters in widgets that use Provider `select`.
Cache stable unmodifiable views for connection and SSH session collections, and
refresh those views only when the underlying collection membership or visible
metadata changes.

Use keyed animations for chat switching. Avoid an `AnimatedSwitcher` around a
`ListView` that shares a `ScrollController`, because it can briefly mount two
lists with the same controller.

Use `AutomaticKeepAliveClientMixin` for the AI chat page so streaming responses
continue while the user switches to another navigation page.

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
