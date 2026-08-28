---
name: ssh-mobile-maintenance
description: Maintain and debug the SSH Mobile repository, including Flutter, Dart packages, the Rust network SDK, Relay, Admin UI, tests, documentation, and shared Agent guidance. Use for any non-trivial implementation, diagnosis, validation, or documentation change in this repository.
---

> Last updated: 2026-08-28

# SSH Mobile Maintenance

## Canonical entry points

For every non-trivial task:

1. Inspect `git status` and preserve unrelated user work.
2. Read `.agents/skills/ssh-mobile-maintenance/references/memory-map.md` and
   load only the Domain, Feature, package contract, ADR, and Architecture files
   selected by that map.
3. Locate real owning paths with read-only search when the request names only a
   behavior. Do not route from a guessed feature name.
4. Read every `AGENTS.md` between each target path and the repository root. For
   a Workspace Member, also read its `README.md`.
5. Treat code and tests as current-behavior truth, Accepted ADRs as decision
   truth, and package contracts as local ownership/edit truth.

The longer execution sequence is in
`.agents/skills/ssh-mobile-maintenance/references/workflow.md`. Validation
selection is in `.agents/skills/ssh-mobile-maintenance/references/validation.md`.
Skill and Memory ownership is governed by
`docs/agent/skill-memory-maintenance.md`.

## Development phase

The repository is in active development. Adding or refactoring code does not
need to preserve compatibility with older versions: destructive refactoring is
allowed, with callers migrated as part of the change. Where a contract or
protocol carries a version number, use `V1`.

## Pull request preflight

Treat a request to create, update, submit, or publish a pull request (创建、更新
或提交 PR) as a validation-gated write operation. Before committing, pushing,
or invoking a GitHub PR write action:

1. Inspect the complete worktree and identify every affected owner.
2. Run the environment-native CI entry point:
   [`scripts/bash/ci/full_test.sh`](../../../scripts/bash/ci/full_test.sh) on
   Linux/WSL or
   [`scripts/powershell/ci/full_test.ps1`](../../../scripts/powershell/ci/full_test.ps1)
   on native Windows. Use `--no-bootstrap` or `-NoBootstrap` only when
   dependencies are current.
3. Run the focused and owner-specific checks selected by the Validation Matrix
   in addition to the local CI entry point when the change requires them.
4. Do not submit while any check is failing or incomplete. A documented
   platform or toolchain gap is not a pass: stop, report the exact gap, and
   require explicit user acceptance before proceeding with a PR write. A new
   or behavior-relevant gap always blocks the PR write.
5. After any code, test, dependency, project-structure, or CI-scope change,
   rerun the affected checks before the PR write action.

The PR write action is the final step: validation evidence must exist before
`git push`, PR creation, or PR update. The GitHub and Git Commit Skills provide
the write mechanics; this Skill owns the repository validation gate.

## Scope before implementation

- Classify the request as explanation/review, diagnosis, implementation, or
  monitoring. Do not mutate code for a diagnosis-only request.
- Identify all touched Domains and owners before editing. Calling an unchanged
  public API does not automatically expand the task into the provider Domain;
  changing its shape, semantics, lifecycle, errors, state, or owner does.
- Keep the smallest change that fully resolves the request. Reuse current
  contracts and owners before adding another abstraction, database, protocol
  path, singleton, or compatibility layer.
- Preserve active compatibility surfaces until their callers are migrated and
  the compatibility inventory permits removal.
- Do not broaden a docs-only or checker task into Flutter, Rust, Go, frontend,
  protocol, FFI, or database behavior changes.

## Test-first contract

Observable or automatable behavior changes must use test-first development.
Before production edits, identify the contract and lowest reasonable test
layer, then work in small Red → Green → Refactor increments. Bugs first receive
a failing regression test; risky untested code first receives a characterization
test.
The documented visual/generated/docs exceptions do not fabricate a Red step.
Never weaken or skip a failure or add test-only production coupling.

The canonical detailed procedure, high-risk owner matrix, exceptions, and
self-check are in [Maintenance Workflow](references/workflow.md). Existing test
commands and cross-boundary gates remain owned by
[Validation](references/validation.md) and local package contracts.

## Repository boundaries

- App Scope resources are constructed by the App composition root. Features
  consume injected Ports/Capabilities and release only resources they own.
- Route ViewModels, controllers, listeners, timers, streams, subscriptions,
  isolates, sessions, native handles, and databases require an explicit owner
  and release path.
- Feature packages do not import App Shell code, another Feature implementation,
  or another package's `/src/` files. Cross-package calls use public entry points.
- `ssh_core` is Client infrastructure. Network contracts, runtime facade, FFI,
  Rust core, and wire protocol route through the SDK Domain.
- The Terminal-only App remains a restricted composition slice and must not gain
  AI, RAG, MCP, WebView, LAN Share, SFTP, or Full App business implementations.
- Growing structured data belongs to the owning Feature/Core database. App logs
  remain separate. Production database-open failures never silently select an
  in-memory fallback.
- Passwords, private keys, API keys, tokens, and credentials stay in platform
  secure storage. Do not put secrets or user-private data in code, logs, docs,
  tests, fixtures, screenshots, traces, exports, or Agent knowledge.

## Security invariants

- Remote writes, uploads, renames, deletions, downloads, and sensitive reads
  require the existing explicit approval path. Approval binds to immutable
  target/action snapshots and stale snapshots fail closed.
- Hidden or unexposed tools never reach approval, execution, cache, loop guard,
  or budget paths. MCP review mode and all secondary authorization remain
  fail-closed.
- Keep destructive shell deletion blocked. Restrict environment dumps, cloud
  metadata, secret-bearing paths, and sensitive WebView targets/forms.
- Apply existing secret redaction to tool arguments/results, logs, traces,
  approval records, and persisted activity.
- Host-key verification, SSH lease ownership, bounded SFTP reads, receive
  sandboxes, transport authentication, Session routing, Delivery ordering, and
  E2EE rules must not be weakened to make a test or migration pass.
- Never invent credentials, contact real systems, or run device/network actions
  unless the user placed them in scope.

## Editing discipline

- Search with `rg`/`rg --files`. Inspect current implementations, callers, and
  focused tests before changing ownership or public behavior.
- Preserve existing worktree changes. Avoid destructive Git/file operations,
  broad rewrites, and edits outside the requested scope.
- Edit generator inputs rather than generated output. Regenerate committed
  artifacts only when their source changes, then verify the generated diff.
- Hand-written files over 500 lines require functional/responsibility
  decomposition; never use numbered chunks (`part_01`/`file_01`) or gratuitous
  over-splitting.
- Repository-owned tests/fixtures use dedicated `test/` or `tests/` roots.
  Required native same-package forms are Go `_test.go`, Rust
  `#[cfg(test)]`/`src/tests`, and TypeScript `.test`/`.spec`. Architecture CI
  runs this placement and numbered-path audit with a regression test.
- Keep diagnostics behind the injected logger; do not add ad hoc `print` calls.
- Keep user-visible text in the owning localization/string contract.
- Add focused tests for changed behavior and regressions. Use fakes and bounded
  fixtures; tests must not require real SSH credentials or API keys.
- Follow local format and naming conventions. Do not split cohesive code merely
  to satisfy a line-count report. The format gate runs at commit time via the
  `git-commit` Skill.
- Select scripts by the actual host: Linux/WSL runs `scripts/bash/**/*.sh`;
  native Windows runs `scripts/powershell/**/*.ps1` in PowerShell 7. Never
  cross-call Windows tools from WSL or require Bash from Windows.

## Documentation ownership

Update only the canonical owner whose fact changed:

- Agent work rules → this Skill or its references;
- task-to-knowledge routing → `memory-map.md`;
- current, non-obvious, costly project knowledge → the relevant `memory_docs/` file;
- package responsibility, API, storage, lifecycle, or required checks → local
  `README.md`/`AGENTS.md`;
- architectural rationale → a precise ADR;
- complete design/resource/dependency model → Architecture documentation;
- historical execution record → Git or an explicit historical report.

Do not append completion timelines, temporary failures, test pass rates,
machine paths, or duplicated ADR/Architecture text to Memory. Follow
`docs/agent/skill-memory-maintenance.md` when changing any Agent knowledge file.
Every maintained Markdown change updates its leading date marker.

`.agents/skills/*/SKILL.md` is canonical — there is no Claude mirror. Claude
Code loads Skills directly from `.agents/skills/`; do not create a second
`.claude` copy of any Skill.

## Validation and completion

- Select checks from
  `.agents/skills/ssh-mobile-maintenance/references/validation.md` according to
  the actual touched owners and risk. Do not claim checks that were not run.
- Tests, analyze, and vet run during implementation, per the checks below. The
  `git-commit` Skill does not re-run them at commit time — it enforces only the
  format gate on the changed files. Implementation validation gaps are reported
  explicitly rather than deferred to the commit step.
- Run `git diff --check` for every change. Review the final diff for unrelated
  files, generated noise, secrets, stale paths, and unintended API/ownership changes.
- The `scripts/bash/` and `scripts/powershell/` trees have identical functional
  subdirectory structures. Same-relative-path `.sh`/`.ps1` files are one
  maintenance unit; synchronize arguments, environment, steps, timeouts,
  cleanup, exit semantics, and scope in the same change. Keep both aggregate
  CI scripts aligned when CI behavior changes.
- If a required check cannot run, report the exact command and environmental or
  scope reason; distinguish that from a product failure.
- A task is complete only when requested behavior/documentation is implemented,
  focused regression coverage is present where appropriate, required owners and
  references are synchronized, and remaining validation gaps are explicit.
- Commit only when requested or when an approved plan explicitly requires
  commits. Stage explicit paths, keep each commit coherent, and never include
  unrelated user changes.
