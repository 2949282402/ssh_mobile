# Agent Memory

This file is shared durable project memory for Codex and Claude Code. It is a
repository file, not live model memory: both agents must read and update it when
project-level decisions, recurring pitfalls, or maintenance notes should survive
across sessions.

## Rules

- Read this file before non-trivial code, documentation, or skill changes.
- Add concise dated notes for durable decisions and recurring project lessons.
- Prefer updating or replacing stale notes over appending duplicates.
- Do not store secrets, private keys, passwords, API keys, tokens, host
  credentials, or user-private data here.
- Do not store machine-local absolute SDK, toolchain, or resource paths here;
  use environment variables, discovery commands, or repo-relative paths.
- Keep notes short enough that agents can load the whole file without wasting
  context.

## Notes

- 2026-05-18: Codex and Claude Code share SSH Mobile maintenance guidance
  through `.agents/skills/ssh-mobile-maintenance/SKILL.md` and
  `.claude/skills/ssh-mobile-maintenance/SKILL.md`. Use
  `scripts/sync_agent_skills.ps1` to check or restore synchronization.
- 2026-05-18: Android native rewrite planning lives in
  `docs/ANDROID_NATIVE_REWRITE_GUIDE.md`; it is now a beginner-oriented
  step-by-step Kotlin + Compose + MVVM tutorial aligned with SSH/SFTP,
  monitor, AI tools, logs, settings, and backup behavior.
- 2026-05-27: `OverflowScrollText` can live inside `ExpansionTile` content, but
  it must use its own `PageStorageBucket`; otherwise Flutter may read the
  tile's stored expanded-state `bool` as a scroll offset and then trip
  follow-on widget-tree assertions around `SelectableText`.
- 2026-05-27: On the Servers, SFTP, and Performance Monitor pages, avoid
  top-level Provider subscriptions to whole health/status maps or whole monitor
  service state. Prefer per-card/per-panel `Selector` snapshots so one
  connection's sampling or SFTP state change does not rebuild the entire page.
- 2026-05-27: For the Servers page, cache lightweight SSH connection summaries
  in `SshService` and let the page select that cached overview instead of
  recomputing summaries from `ssh.sessions` inside the widget tree. For SFTP
  directory panes, prefer a session-side `entriesRevision` over `listEquals`
  on every `Selector` pass so large directories do not pay repeated O(n)
  equality checks.
- 2026-05-27: In the Performance Monitor page, keep Ports/Applications results
  cached per selected-server key inside the page state so switching tabs does
  not refetch snapshots unless the selection changes or the user explicitly
  refreshes.
- 2026-05-28: When wrapping `ReorderableListView.builder` items in `Selector`
  or another widget, keep the stable item key on the immediate widget returned
  by `itemBuilder`. A key on a descendant does not satisfy Flutter's reorderable
  list assertion.
- 2026-05-28: Keep app-wide settings dependencies narrow in page hot paths:
  prefer `context.select<AppSettings, AppLanguage>` or a page-specific value
  snapshot over `context.watch<AppSettings>()`, so unrelated setting changes do
  not rebuild full pages. AI chat streaming text is intentionally held in a
  local `ValueNotifier` and committed back to `AiChatRecord` only on
  completion/cancel/error; avoid per-token `_replaceChat`/whole-page `setState`
  regressions.
- 2026-05-28: The vendored xterm renderer treats new `TerminalStyle` and
  `TerminalTheme` object identities as cache-changing inputs. Keep those
  objects memoized for unchanged font/theme values; otherwise ordinary terminal
  screen rebuilds clear paragraph/color caches and can amplify font-scaling
  repaint artifacts.
- 2026-05-28: Android release builds intentionally set
  `usesCleartextTraffic=false`; debug/profile manifests override it for local
  provider testing only. Do not re-enable release cleartext unless a scoped
  network security config and README/ADR note are added.
- 2026-05-28: Core SSH/SFTP/LLM/AI tool and storage flows expose small Dart
  contracts for future fake injection. Backup imports intentionally clear any
  cached AI API key and ignore credential fields from JSON; users must
  reconfigure passwords, private keys, and API keys after importing.
- 2026-05-28: AI `web_search` is now local client WebView search only. It no
  longer stores provider/base URL settings, is enabled by default, and can be
  disabled by the user; keep search results client-side and tied to the current
  chat's WebView session. Prefer lightweight DuckDuckGo HTML results over Bing
  SERP DOM parsing for stability, and avoid viewport-geometry visibility checks
  in result extraction because AI browsing may run in a background WebView.
  Keep the configured per-call result count embedded in the `web_search` tool
  schema and aligned with the execution clamp.
- 2026-05-28: AI WebView browsing has a per-chat operation token. While active,
  the WebView UI is view-only; user interruption clears the token so the tool
  result reports interruption instead of continuing from a stale page.
- 2026-05-28: In LLM settings, leaving the API key field blank must preserve
  the saved secure-storage key. Only an explicit clear action should delete the
  stored key; otherwise model/base URL edits can silently break later chats.
- 2026-05-28: Cache fetched LLM model lists in local settings per normalized
  Base URL. Reopen the settings page from cache first, and treat manual refresh
  as the action that replaces the cached list.
- 2026-05-28: LLM settings are provider-aware now. Keep Base URL history in
  plain preferences, keep multiple API keys in secure storage with masked
  previews, show DeepSeek thinking controls only for DeepSeek-like models, and
  show OpenAI reasoning effort only for supported OpenAI reasoning model ids.
- 2026-05-28: AI client tools now include permission status, redacted client
  log queries, and chat-bound WebView state/navigation helpers behind
  `ClientSystemToolService` and `ClientWebViewService` adapters. Keep client
  file saves in the client-system adapter so SFTP downloads return save
  metadata rather than raw file contents to the model.
- 2026-05-28: `sftp_write_text` is a detached path-based SFTP tool that always
  requires user approval. Reuse the app SFTP edit/download size settings in AI
  tools, and keep the approval card showing server, remote path, byte count,
  and a short content preview before any remote write executes.
- 2026-05-28: AI tools now use a shared `ToolSecretPolicy` to redact tool
  arguments/results/traces and to block likely secret-bearing paths and
  environment-dump commands before the model sees them. Do not expose saved SSH
  passwords, private keys, API keys, tokens, backup JSON, raw terminal
  history, or secret-path file contents through any future tool.
- 2026-05-28: Saved-server tool coverage now flows through
  `ServerCatalogAdapter`, monitor coverage through
  `PerformanceMonitorToolAdapter`, and detached SFTP path operations through
  expanded `SftpClientAdapter` helpers (`stat/upload/mkdir/rename/delete`).
  Keep new AI tool work on these adapters so tests can inject fakes and so
  secrets remain outside the model-visible layer.
