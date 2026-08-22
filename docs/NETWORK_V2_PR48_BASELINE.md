> Last updated: 2026-08-21

# PR48 Network V2 Baseline

This document freezes the PR48 implementation state used for the PR49
acceptance and architecture-hardening work. It is a historical execution
record; current behavior remains authoritative in code and tests.

## Repository state

- Commit SHA: `929a711cbf82de26a24f9aa4f8fa18c707c01f38`
- Branch: `agent/network-v2-final-20260819`
- Working tree: clean before this baseline document was created
- Baseline date: 2026-08-21 (Asia/Singapore)

## Baseline validation

`bash scripts/network_v2_acceptance.sh baseline` passed: 13 contract tests ran,
with 10 passing cases and 3 test-defined skips.

`bash scripts/full_test.sh --no-bootstrap --no-coverage` completed with exit 1.
The local CI result was:

- PASS: native-network-quality, sdk-dart-quality, architecture-check,
  app-static-quality, workspace-core-quality, workspace-features-quality,
  app-unit-shard-0, app-unit-shard-1, android-build.
- FAIL: `front-quality` because Docker Hub could not fetch the anonymous token
  for the Node image (`EOF`); `relay-quality` because `govulncheck` could not
  fetch the vulnerability index (`EOF`); `protocol-v2-contract` because its
  final Dart dependency update terminated during the package handshake.
- WSL-only skips: terminal smoke build, Windows build, macOS build, iOS build,
  and App coverage (coverage was explicitly disabled for this run).
- Remote CI status: not queried in this local baseline run.

## Completed

- Network Protocol V2 migration
- Peer ownership migration
- Relay V2
- SDK migration
- CI migration

## Pending

- Legacy ownership audit
- PathLease validation
- Connectivity stage validation
- Candidate cache validation
- Relay security validation
- FFI ABI validation
- SDK architecture cleanup

## Known risks carried into PR49

- The full local CI gate is not green because of the three failures recorded
  above; the external network failures must be separated from product failures
  during final validation.
- The eight required read-only architecture audits have not yet been completed.
- Network V2 acceptance remains subject to strict owner selectors and the
  Architecture Freeze Gate; SDK cleanup is not authorized until that gate is
  PASS.
- No protocol direction or existing architecture decision is changed by this
  baseline.
