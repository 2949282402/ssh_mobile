> Last updated: 2026-08-13

# Maintenance Workflow

Use this sequence after the canonical Skill and
[Memory Map](memory-map.md) have scoped the task.

## 1. Establish the baseline

1. Read the request literally and separate required outcomes from suggestions.
2. Inspect `git status --short`; note every pre-existing modification and keep it
   out of the task unless the user explicitly includes it.
3. Locate affected code, tests, contracts, and callers with `rg` or `rg --files`.
4. Read the nearest `AGENTS.md`, Workspace Member `README.md`, routed Memory,
   and only the ADR/Architecture documents selected by the Memory Map.
5. For a bug, reproduce or trace the failing state before proposing the cause.
   For a review, gather evidence and do not implement an unsolicited fix.

## 2. Define ownership and risk

- List the public contract, implementation owner, lifecycle owner, storage
  owner, and validation owner affected by the change.
- Follow every changed public API to its callers. Add a Domain only when the
  boundary's shape, semantics, errors, state, lifecycle, or ownership changes.
- Identify security-sensitive data, remote effects, compatibility bridges,
  generated artifacts, and platform-specific behavior before editing.
- Prefer a focused correction within an existing owner. An additional service,
  database, protocol path, Feature dependency, or compatibility layer needs
  evidence that the current boundary cannot own the behavior.

## 3. Implement coherently

- Keep UI composition in Views, state/actions in ViewModels, orchestration in
  Services/Modules, persistence in owning Repositories, and platform/protocol
  behavior behind injected adapters.
- Keep create/start/stop/dispose paired under one explicit lifecycle owner.
- Preserve cancellation, timeout, ordering, backpressure, bounded allocation,
  and fail-closed security paths when changing asynchronous behavior.
- Change generator sources, manifests, and public entry points together with
  their generated output or callers when applicable.
- Make tests deterministic and independent of real credentials, networks, or
  user machines.
- Rewrite corrupted documentation as clean UTF-8; do not patch mojibake byte by byte.

## 4. Validate in layers

1. Format the touched language and run focused unit/widget tests first.
2. Run the owning package's required analyze/test commands.
3. Add architecture, workspace, native, backend, frontend, or platform checks
   only when the change reaches those boundaries.
4. Run documentation/link/Skill checks when Agent knowledge or shared docs change.
5. Run `git diff --check` and inspect the complete final diff.

The command matrix and environment-specific notes are in
[Validation](validation.md).

## 5. Synchronize canonical knowledge

Update a document only when its owned fact changed. Package contracts describe
local responsibility and required checks; Memory records scoped current
knowledge; ADRs record reasons; Architecture documents record complete design;
Git records execution history.

When changing the canonical Skill, update `.agents` first, generate the Claude
mirror with `SyncFromAgents`, and verify with `Check`. Do not copy references to
`.claude` and do not edit a Claude Skill as input.

## 6. Handoff or commit

- Report the outcome first, then relevant files, validations run, and any exact
  gap or residual risk.
- Do not claim success from a build command that never reached the changed code.
- If commits are requested, stage explicit paths, review the staged diff, use a
  scoped imperative subject, and verify the resulting status and commit.
- Never include unrelated user changes, secrets, temporary output, caches, or
  machine-specific files in a commit.
