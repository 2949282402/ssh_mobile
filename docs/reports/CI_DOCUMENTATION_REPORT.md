> Last updated: 2026-08-21

# CI / Documentation Audit

Status: BLOCKED

Scope: `.github/workflows`, `scripts`, README, ADR, `memory_docs`, and
`AGENTS.md`. This was a read-only audit; no implementation files were changed.

## Findings

- PASS: `protocol/contract_tests/acceptance_matrix.json` reports 60/60 cases as
  covered; the strict acceptance script and the focused protocol/architecture
  full-test jobs were observed passing in the audit environment.
- PASS: SDK package README/AGENTS contracts align with their manifests and the
  architecture/documentation checks passed.
- ARCHITECTURE RISK: `docs/NETWORK_FAULT_MATRIX.md:35-50` still describes
  Relay-to-Direct migration, transparent reconnect, unchanged SessionId, and
  route replacement, conflicting with
  `docs/adr/ADR-CONNECTION-LIFECYCLE-V2.md:73-104` and
  `memory_docs/sdk/features/transport-routing.md:29-45`.
- BUG: `scripts/network_v2_acceptance.sh:58-60` invokes Flutter tests without
  `--no-pub`, causing dependency resolution/downloads during a read-only gate.
- BUG: `scripts/full_test.sh:777-785` does not preflight `dart`/`flutter` for the
  protocol job; a missing tool appears as a product failure instead of an
  environment gap.
- TEST GAP: CI enforces App coverage (`.github/workflows/flutter.yml:435-598`),
  while `scripts/full_test.sh:62-64,947-958` disables it by default. The local
  command is not equivalent to CI coverage enforcement.
- TEST GAP: `test_frozen_network_contract.py:293-332` verifies declared owner
  tests but not that every matrix test is selected by the strict shell script.

## Required Changes

- Mark stale fault-matrix rows D/E/M/O/R as historical or rewrite them to the
  V2 lifecycle contract.
- Add `--no-pub` and tool preflight to the acceptance script, and preflight
  `dart`/`flutter` in the full-test protocol job.
- Align local and CI coverage policy; require `--with-coverage` for a complete
  local gate.
- Add mechanical matrix-to-selector validation and rerun the complete gate in
  an already provisioned environment.

## Risk

Implementation, ADR, and Memory are mostly V2-aligned, but the fault matrix
still directs validation toward retired lifecycle semantics. The current local
evidence does not prove complete CI or App coverage.
