> Last updated: 2026-08-23

# Repository Bootstrap

SSH Mobile is a cross-platform Flutter SSH/SFTP client with monitoring,
LAN sharing, client-side AI tools, a native Rust network SDK, a Go Relay/control
plane, and a React administration console.

This file is the repository entry point, not a complete architecture guide or
command catalog.

## Required reading chain

Memory routing always begins here: before loading any scoped Memory (Domain or
Feature), local `AGENTS.md` contract, ADR, or Architecture document, read this
bootstrap file first — it is the required entry for memory discovery.

For every non-trivial task:

1. Read the [canonical maintenance Skill](.agents/skills/ssh-mobile-maintenance/SKILL.md).
2. Use the [Memory Map](.agents/skills/ssh-mobile-maintenance/references/memory-map.md)
   to identify only the relevant Domain and Feature Memory.
3. Discover and read local `AGENTS.md` files from each target path toward the
   repository root. For a Workspace Member, also read its `README.md`.
4. Add precise ADRs or Architecture documents only when the Memory Map's
   escalation conditions apply.

Knowledge ownership and update rules are defined by
[Skill and Memory Maintenance](docs/agent/skill-memory-maintenance.md). The
[Project Memory root](memory_docs/README.md) indexes scoped current knowledge.

Code and tests are authoritative for current behavior. Accepted ADRs are
authoritative for architectural decisions. A nearer `AGENTS.md` supplements or
tightens this file and cannot relax repository-wide safety rules.

## Top-level Domains

- `apps/`, `packages/core/`, `packages/features/`, and
  `packages/infrastructure/ssh_core/` are the Client Domain.
- `native/network_core/`, `protocol/`, and the `network_sdk`,
  `network_transport`, and `ssh_mobile_network_native` packages are the SDK Domain.
- `relay/` is the Backend Domain.
- `front/` is the Front Domain.
- `docs/`, `tool/`, `scripts/`, `.github/`, and installer/platform directories
  are repository-level support areas routed by the behavior they own or verify.

Every Workspace Member under `apps/` and `packages/` keeps a concise
`README.md`, `AGENTS.md`, `pubspec.yaml`, `lib/`, and `test/`. The README owns
package responsibility, public API, dependencies, database, lifecycle owner,
and validation entry points. The local AGENTS file owns edit scope, forbidden
dependencies, API/storage/release constraints, and required tests. Keep all 21
local contracts; do not replace them with project Memory.

## Repository-wide boundaries

- Put implementation in its owning App, Core, Feature, Infrastructure, SDK,
  Backend, or Front layer. Use public package entry points; do not import another
  package's `/src/` or copy an implementation across owners.
- App Scope, Module Scope, and Route Scope resources require explicit owners and
  release paths. A borrower releases its lease/subscription, not the owner's
  session, database, native handle, or runtime.
- Feature/Core structured data stays in the owning database. App diagnostics
  stay separate. A production database-open failure must not silently select an
  in-memory fallback.
- Passwords, private keys, API keys, tokens, server credentials, and user-private
  data stay out of source, logs, tests, fixtures, screenshots, docs, traces,
  exports, Skill, and Memory. Use platform secure storage for secrets.
- Remote writes and sensitive reads retain explicit approval, immutable target
  binding, secret redaction, host-key verification, and fail-closed execution.
  Do not weaken destructive-command, sensitive-path, sandbox, transport-auth,
  Delivery, Session-routing, or E2EE protections.
- Edit generator inputs rather than generated output. Regenerate committed
  artifacts only when their source changes and review the generated diff.
- Route diagnostics through the injected logger; do not add ad hoc `print` calls.
- Preserve unrelated worktree changes. Avoid destructive Git/file operations and
  do not broaden a diagnosis, review, or docs-only request into implementation.

## Documentation and validation

Every maintained Markdown file places its update marker at the beginning,
immediately after YAML front matter when present. Use `Last updated: YYYY-MM-DD`
for English-first documents and `最新更新时间：YYYY-MM-DD` for Chinese-first
documents, and update it whenever content changes.

Use the canonical Skill's
`.agents/skills/ssh-mobile-maintenance/references/validation.md` to choose checks
proportional to the touched owner and risk. Package-local commands remain in the
owning README/AGENTS. Always run `git diff --check`, inspect the final status and
diff, report checks actually run, and state exact environmental or scope gaps.

Before creating or updating a PR, run `scripts/full_test.sh` and the applicable
focused checks from WSL. `full_test.sh` is the daily basic regression gate and
does not collect Flutter coverage by default. For coverage-affecting changes,
large refactors, new feature review, or release acceptance, run the four
domain-specific gates: `scripts/front_coverage.sh`,
`scripts/backend_coverage.sh`, `scripts/client_coverage.sh`, and
`scripts/sdk_coverage.sh`. Each gate enforces an 80% line/metric threshold on
its documented owner scope and prints uncovered locations when it fails.
`scripts/coverage_test.sh` remains a compatibility alias for the client gate.
A stricter new-source rule also applies: every newly added hand-written
production source file must have corresponding independent tests and at least
90% file-level line coverage. Generated output, documentation, configuration,
test-only files, and platform boilerplate without coverable business logic are
excluded only when the owning validation report records the reason.
A failing or incomplete check blocks submission unless the user explicitly
accepts the documented environment gap. When tests, package membership,
project structure, CI scope, or test-selection rules change, update
`scripts/full_test.sh` in the same change. The canonical Skill and Project
Memory define the detailed PR gate and script-maintenance rules. Explicit
Windows platform checks use native PowerShell 7 (`pwsh.exe`) and a native
working directory; they never replace the WSL Linux gate.

`CLAUDE.md` is the Claude-specific thin bootstrap entry. It delegates repository
entry and memory routing to this `AGENTS.md` and the canonical `.agents` Skill,
and is not a second source of truth: do not hand-edit repository bootstrap
content into `CLAUDE.md` — keep canonical entry-point content in this file.

Stage and commit only when requested or explicitly required by an approved plan.
Stage explicit paths, keep commits coherent, and never include unrelated user work.



For long-running asynchronous work:
- Empty `write_stdin` polls MUST use `yield_time_ms >= 180000`;
prefer `300000` when intermediate output is not needed.
- `functions.wait` MUST use `yield_time_ms >= 180000`.
- `functions.exec` MUST set its outer `@exec yield_time_ms` at least
30000 ms longer than the longest nested tool wait, so the outer
code cell does not yield first.
- Do not apply the long wait to non-empty `write_stdin` calls that
send interactive input.
- These tools return early when the process or cell completes.
Do not wake the model merely to report that work is still running.
