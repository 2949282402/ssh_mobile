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
  chat's WebView session.
- 2026-05-28: AI WebView browsing has a per-chat operation token. While active,
  the WebView UI is view-only; user interruption clears the token so the tool
  result reports interruption instead of continuing from a stale page.
