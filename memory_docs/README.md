> Last updated: 2026-08-20

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

[`scripts/full_test.sh`](../scripts/full_test.sh) is the maintained WSL entry
point for the Linux-runnable CI gates across the repository. It is an
integration surface, not a disposable convenience script. When tests are
added, removed, or renamed, package membership or project structure changes,
CI jobs change, generated checks change, or test exclusions, timeouts, and
Linux toolchain assumptions change, update `scripts/full_test.sh` in the same
change. Keep its job scopes, filters, environment-gap handling, and help text
aligned with the current CI and repository layout, then run the affected jobs
and the documentation checks.

Before creating or updating a PR, run the script from WSL after dependencies
are current. `--no-bootstrap` is appropriate only for a repeat run with
unchanged dependency inputs. A documented platform or toolchain gap must stay
visible in the result and must never be reported as a passed check; it does not
authorize a PR write without explicit user acceptance.

Recommended repeat-run parameters from the repository root are:

```bash
bash scripts/full_test.sh \
  --jobs 4 \
  --flutter-concurrency 2 \
  --melos-concurrency 1 \
  --melos-test-concurrency 1 \
  --app-timeout 20m \
  --no-bootstrap
```

Maintenance rules are defined by
[Skill & Memory Maintenance](../docs/agent/skill-memory-maintenance.md).
