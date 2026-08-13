---
name: ssh-mobile-maintenance
description: Maintain and debug the SSH Mobile repository, including Flutter, Dart packages, the Rust network SDK, Relay, Admin UI, tests, documentation, and shared Agent guidance. Use for any non-trivial implementation, diagnosis, validation, or documentation change in this repository.
---

> Last updated: 2026-08-13

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
- Keep diagnostics behind the injected logger; do not add ad hoc `print` calls.
- Keep user-visible text in the owning localization/string contract.
- Add focused tests for changed behavior and regressions. Use fakes and bounded
  fixtures; tests must not require real SSH credentials or API keys.
- Follow local format and naming conventions. Do not split cohesive code merely
  to satisfy a line-count report.
- Develop and validate inside the WSL Linux environment: run every build, test,
  analyze, and validation command with the Linux toolchain inside WSL; never
  invoke Windows-hosted toolchains (Windows `dart`/`flutter`/`go`/`cargo`/`node`,
  `.bat`/`.cmd` launchers, `powershell.exe`, `cmd.exe`). See the Environment
  note in `references/validation.md`.

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

`.agents/skills/*/SKILL.md` is canonical. `.claude/skills/*/SKILL.md` is a
byte-identical generated mirror with no copied references. After a canonical
Skill edit, run the one-way sync and then the read-only check defined in the
validation reference. Never edit the Claude mirror as a source.

## Validation and completion

- Select checks from
  `.agents/skills/ssh-mobile-maintenance/references/validation.md` according to
  the actual touched owners and risk. Do not claim checks that were not run.
- Run `git diff --check` for every change. Review the final diff for unrelated
  files, generated noise, secrets, stale paths, and unintended API/ownership changes.
- If a required check cannot run, report the exact command and environmental or
  scope reason; distinguish that from a product failure.
- A task is complete only when requested behavior/documentation is implemented,
  focused regression coverage is present where appropriate, required owners and
  references are synchronized, and remaining validation gaps are explicit.
- Commit only when requested or when an approved plan explicitly requires
  commits. Stage explicit paths, keep each commit coherent, and never include
  unrelated user changes.
