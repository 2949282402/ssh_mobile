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
