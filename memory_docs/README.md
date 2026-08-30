> Last updated: 2026-08-30

# Project Memory

`memory_docs/` stores concise, verified, reusable project facts. It is not a
changelog, full architecture specification, or test report. Load only domains
selected by the [Memory Map](../.agents/skills/ssh-mobile-maintenance/references/memory-map.md):

- `client/`: Flutter Apps, Core/Feature packages, SSH infrastructure;
- `sdk/`: Dart contracts, native bindings, Rust runtime, wire protocol;
- `backend/`: Go control plane and Relay;
- `front/`: React administration console.

Formal decisions/designs stay in `docs/adr/`, `docs/architecture/`, and focused
documents; code/tests define current behavior. Business behavior uses the
test-first procedure in the [Maintenance Workflow](../.agents/skills/ssh-mobile-maintenance/references/workflow.md).

## Validation and CI

`scripts/bash/` and `scripts/powershell/` mirror functional categories. Keep
same-relative `.sh`/`.ps1` arguments, environment, scope, timeouts, cleanup, and
exit semantics aligned; use the host-native tree.

本地 aggregate CI 仅在用户明确提及时运行。用户要求发起 PR 时完成最小
format/diff/focused 检查后可提交、推送并发起 PR，由 GitHub Actions 的并行 jobs
作为 CI 基准。未执行、遗漏、GAP、超时或失败都不是 PASS；发起 PR/CI 后不主动
观察或解读 GitHub，不批准或合并，合并权由用户决定。

Full local CI and repeat-run parameters are owned by
[Validation](../.agents/skills/ssh-mobile-maintenance/references/validation.md), not
duplicated here. `full_test.sh` does not collect Flutter coverage by default.

For large refactors, coverage changes, or release review, use the four independent
owner gates from the repository root:

```bash
bash scripts/bash/coverage/front_coverage.sh
bash scripts/bash/coverage/backend_coverage.sh
bash scripts/bash/coverage/client_coverage.sh
bash scripts/bash/coverage/sdk_coverage.sh
```

Each gate enforces 90% for its documented scope; new hand-written production
files also need an independent test and 90% file-level coverage. The former
`coverage_test.sh`/`.ps1` names remain client aliases. Scope, Docker services,
and the WSL Flutter workaround are in [`docs/COVERAGE_POLICY.md`](../docs/COVERAGE_POLICY.md).
The native Windows MSI/client workflow remains in
[`client/current-state.md`](client/current-state.md) and must keep WSL/WiX ICE
environment gaps visible.

Maintenance governance is [Skill & Memory Maintenance](../docs/agent/skill-memory-maintenance.md).
