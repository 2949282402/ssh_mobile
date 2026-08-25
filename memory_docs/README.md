> Last updated: 2026-08-25

# Project Memory

This directory contains concise, current repository knowledge for maintenance
agents. It is not a changelog, an architecture specification, or a test report.

Load only the domains selected by the
[Memory Map](../.agents/skills/ssh-mobile-maintenance/references/memory-map.md):

- `client/`: Flutter Apps, Core and Feature packages, and SSH client infrastructure;
- `sdk/`: Dart network contracts, native bindings, the Rust network runtime, and wire protocol;
- `backend/`: the Go control plane and Relay;
- `front/`: the React administration console.

Detailed decisions remain in [`docs/adr/`](../docs/adr/), complete designs remain
in [`docs/architecture/`](../docs/architecture/) and focused project documents,
and current behavior remains authoritative in code and tests.

## Repository-wide validation

`scripts/bash/` and `scripts/powershell/` are mirrored by functional category.
Agents run the aggregate matching their host and maintain same-relative-path
`.sh`/`.ps1` pairs together. CI scope, arguments, environment, timeouts,
cleanup, and exit semantics cannot drift between the pair. Platform-only and
common PowerShell files live in their mirrored categories without fabricated
Bash implementations.

Before creating or updating a PR, run the environment-native aggregate after
dependencies are current. A documented platform or toolchain gap stays visible
and is never reported as a pass.

Recommended repeat-run parameters from the repository root are:

```bash
bash scripts/bash/ci/full_test.sh \
  --jobs 4 \
  --flutter-concurrency 2 \
  --melos-concurrency 1 \
  --melos-test-concurrency 1 \
  --app-timeout 20m \
  --no-bootstrap
```

The native Windows PowerShell 7 equivalent is:

```powershell
& .\scripts\powershell\ci\full_test.ps1 `
  -Jobs 4 -FlutterConcurrency 2 -MelosConcurrency 1 `
  -MelosTestConcurrency 1 -AppTimeout 20m -NoBootstrap
```

## Periodic coverage review

`full_test.sh` is the daily basic regression gate and does not collect Flutter
coverage by default. For a large refactor, a new feature, or release review,
run the independent owner gates from the repository root:

```bash
bash scripts/bash/coverage/front_coverage.sh
bash scripts/bash/coverage/backend_coverage.sh
bash scripts/bash/coverage/client_coverage.sh
bash scripts/bash/coverage/sdk_coverage.sh
```

Native Windows uses the same filenames under
`scripts\powershell\coverage\`; update and review both sides together.

Each gate enforces an 80% threshold on its documented scope. The former
`scripts/bash/coverage/coverage_test.sh` name remains a compatibility alias for the client
gate. Scope, failure interpretation, Docker-backed services, and the WSL
Flutter runner workaround are maintained in
[`docs/COVERAGE_POLICY.md`](../docs/COVERAGE_POLICY.md).
New hand-written production files have the stricter 90% file-level coverage
and corresponding-test requirement documented there.

The native Windows PowerShell 7 MSI packaging and client validation workflow is
maintained in [`client/current-state.md`](client/current-state.md). It is
platform-specific evidence and must keep any WSL or WiX ICE environment gap
visible.

Maintenance rules are defined by
[Skill & Memory Maintenance](../docs/agent/skill-memory-maintenance.md).
