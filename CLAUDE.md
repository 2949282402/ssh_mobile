> Last updated: 2026-08-13

# Claude Repository Bootstrap

SSH Mobile combines Flutter Client applications, modular Dart packages, a Rust
network SDK, a Go Relay/control plane, and a React administration console.

For every non-trivial task:

1. Read the root [repository bootstrap](AGENTS.md).
2. Follow the canonical
   [SSH Mobile maintenance Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md).
3. Route the task with the canonical
   [Memory Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md).
4. Load only the selected scoped Memory, nearest `AGENTS.md`, Workspace Member
   README, and conditionally relevant ADR/Architecture documents.

The `.claude/skills/` copy is a generated compatibility mirror. It is not the
source of truth and must not be edited as input. Canonical Skill references stay
under `.agents/skills/ssh-mobile-maintenance/references/`.

Preserve unrelated worktree changes, respect the task's requested action level,
and validate proportionally to the affected owner. Never put passwords, private
keys, API keys, tokens, server credentials, or user-private data in source,
logs, tests, fixtures, screenshots, docs, commits, Skill, or Memory.

Report the implemented or diagnosed outcome, checks actually run, and any exact
environmental or scope limitation. Do not claim an unrun check passed.
