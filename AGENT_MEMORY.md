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
