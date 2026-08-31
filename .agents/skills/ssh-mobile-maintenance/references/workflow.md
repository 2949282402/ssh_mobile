> Last updated: 2026-08-31

# Maintenance Workflow

Use after the canonical Skill and [Memory Map](memory-map.md) scope the task.

## 1. Baseline and risk

1. Read the request literally; separate required outcomes from suggestions.
2. Inspect `git status --short`; keep pre-existing changes out unless included.
3. Locate affected code, tests, contracts, and callers with `rg`/`rg --files`.
4. Read nearest `AGENTS.md`, Workspace Member `README.md`, routed Memory, and
   only the ADR/Architecture files selected by the map.
5. For bugs, reproduce/trace the failing state before assigning a cause; for
   reviews, gather evidence without an unsolicited fix.

Before editing, list the changed public contract, implementation/lifecycle/
storage/validation owners, callers, security-sensitive data, remote effects,
compatibility bridges, generated artifacts, and platform-specific behavior.
Follow a changed API to every caller; add a Domain only when its boundary shape,
semantics, errors, state, lifecycle, or ownership changes. Prefer the existing
owner; a new service/database/protocol path/dependency/compatibility layer needs
evidence that the current boundary cannot own it.

## 2. Implement with test-first evidence

Observable/automatable behavior—including state, protocol/API, security,
persistence, lifecycle, concurrency/ordering, cancellation/timeout/retry, and
errors—uses Red → Green → Refactor at the lowest reasonable layer:

```text
pure unit → repository/service/ViewModel → contract → widget → integration → E2E
```

When a contract crosses Dart↔Rust FFI, Protobuf/wire, Flutter↔native,
Relay HTTP/WebSocket, Redis/MySQL, multi-instance, or App Shell↔Feature, add
the focused cross-boundary gate after the fast test proves local behavior.

For a bug: read implementation/tests, add one stable regression test, run it and
confirm Red is the target defect, make the smallest production change to Green,
refactor, then run the focused test, package suite, and affected contract/
integration/acceptance/race gate. For a feature: state Given/When/Then for each
observable behavior, add and run its failing test before implementation, then
Green/refactor before the next behavior. For risky uncovered code, first add a
characterization test; a deliberate contract change needs a new failing
expectation. If automation is unrealistic, record why and use the nearest
contract evidence.

Assert public results, persisted state, emitted events, returned errors,
ownership/release effects, protocol compatibility, and security invariants—not
private fields, incidental collection shape, private call order, or mock calls
alone unless that interaction is the contract (for example, close once or retry
at most N times). Never fix Red by weakening/deleting/skipping an assertion,
accepting the defect, or adding test-only production hooks. Coverage is evidence,
not a reason to test trivial getters/constructors/branches.

Docs/comments/formatting, generated code/FFI bindings, export-only files,
behavior-free configuration, and pure visual spacing/color/radius/typography do
not mechanically require TDD; test UI business state at unit/ViewModel level,
key widget behavior in widgets, critical flows in integration, and visual
contracts with goldens only when warranted.

High-risk focus: `native/network_core` (peer/session/path/lease, Direct/Relay,
recovery, Delivery/Stream/Transfer, E2EE, races); `relay` (HTTP/WebSocket,
enrollment/auth/anti-replay, reservation/rate limits, MySQL/Redis, multi-instance,
admin sessions); `connection_core` (Drift, credentials/Host Keys/migration);
`ssh_core` (Pool/Lease/refcount/idle/shutdown); `network_sdk`/native binding
(JSON/error/refresh, facade/realtime, dispose, Dart↔Rust parity); `feature_ai`
(tool loop/approval/budget/plan/cancel/provider/trace); `feature_sftp`
(fingerprint, browse/preview/edit/transfer/delete, fail-closed); other Features
(ViewModel/reducer/repository/parser/state/service behavior).

Keep Views for UI composition, ViewModels for state/actions, Services/Modules for
orchestration, Repositories for persistence, and injected adapters for platform/
protocol behavior. Pair create/start/stop/dispose under one owner. Preserve
cancellation, timeout, ordering, backpressure, bounded allocation, and fail
closed paths. Change generator sources/manifests/public entry points with their
generated output/callers. Keep tests deterministic and rewrite corrupted docs as
UTF-8.

## 3. Validate and synchronize

Format touched languages, run focused checks first, then the owning package
analyze/test commands and only the architecture/workspace/native/backend/front/
platform gates reached by the change. Agent-doc changes use the documentation
checks in [Validation](validation.md); every change ends with `git diff --check`
and complete status/diff review. Never call an unrun check PASS.

Update only the Owner whose fact changed: Skill/reference for Agent rules,
Memory for costly current facts, package README/AGENTS for local contracts, ADR
for rationale, Architecture for complete design, Git for history. Do not add
timelines, temporary failures, test results, machine paths, or duplicate formal
design to Memory. `.agents/` is the canonical Skill source; there is no mirror.

## 4. PR and CI handoff

PR creation/update follows the Skill's handoff rule: inspect the full worktree,
run `git diff --check`, formatting, and requested/necessary focused checks; run
aggregate local CI only when the user explicitly mentions it
(`scripts/bash/ci/full_test.sh` on Linux/WSL or the PowerShell counterpart on
native Windows). A GAP, timeout, failure, omission, or unrun check is not PASS.
After minimum preflight, a requested branch may be committed, pushed, and
opened (prefer draft) for GitHub Actions' independent parallel jobs. Record the
changed contract, its regression/characterization evidence, focused gates, and
any unrun or unprotected edge before handoff. Immediately start a temporary,
commit-bound background watcher (for example, `gh run watch <run-id>
--exit-status > <temp-log> 2>&1 &`). If it fails, inspect the failed-job logs,
make the smallest safe fix, run permitted focused/static checks, commit/push,
and restart the watcher for the new SHA. Continue until the required checks pass
or a concrete blocker needs user input. Never approve or merge automatically;
the user decides merging.

## 5. Report or commit

Report outcome first, then files, commands actually run, exact gaps, and residual
risk. Commit only when requested/approved: stage explicit paths, review staged
diff, use a scoped imperative subject, verify status/commit, and exclude
unrelated changes, secrets, caches, temporary output, and machine paths.
