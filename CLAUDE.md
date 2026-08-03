# CLAUDE.md

> 最新更新时间：2026-07-29

Use `AGENTS.md` as the authoritative repository guide for structure, coding
rules, commands, testing, documentation markers, and security expectations.
Do not duplicate those rules here.

For non-trivial repository work:

1. Read `AGENT_MEMORY.md`.
2. Use `.claude/skills/ssh-mobile-maintenance/SKILL.md`.
3. Load only the task-specific code and references routed by that skill.

The Claude skill mirrors
`.agents/skills/ssh-mobile-maintenance/SKILL.md`. After editing the canonical
Codex copy, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Check
```

Use one of the script's restore modes only if the check reports a missing or
divergent copy.

Keep `AGENT_MEMORY.md` as a compact set of current, non-obvious decisions.
Replace stale entries instead of using it as a changelog.
