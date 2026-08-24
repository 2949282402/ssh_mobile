最新更新时间：2026-08-19

# Coordinator checkpoint

Use one checkpoint per frozen-plan handoff. Keep each field evidence-backed;
`COMPLETED` means the referenced test or command passed, not merely that code
exists. Do not convert an unimplemented or unavailable check into a success
claim.

```text
Checkpoint: <phase / wave / timestamp>
Frozen SHA: <commit or working-tree baseline>

Architecture: COMPLETED | BLOCKED
Evidence: <paths, test names, or command output>

Tests: PASSED | FAILED | NOT RUN
Evidence: <exact commands and result summaries>

Cutover: COMPLETED | PARTIAL
Evidence: <old/new route or feature boundary, if applicable>

Retire: COMPLETED | DEFERRED
Evidence: <retired surface, or the explicit reason it remains>

Cleanup: COMPLETED | DEFERRED
Evidence: <inventory and exact paths>

Cross-agent conflicts: NONE | LIST
Details: <path ownership or unresolved overlap>

Docs impact: NONE | LIST
Details: <documents changed, or why no current fact changed>

Next contract: FROZEN | OPEN
Details: <remaining acceptance cases and owner>
```

## Required handoff rules

- Record the exact SHA or working-tree baseline before comparing results.
- List `NOT RUN` separately from `FAILED`; include environmental gaps such as a
  missing toolchain or unavailable integration service.
- Link each completed claim to an executable test, fixture, source symbol, or
  command result. Historical ADR text is not proof of current behavior.
- If a contract remains open, keep `Next contract: OPEN` and name the exact
  acceptance case rather than describing the architecture as complete.
