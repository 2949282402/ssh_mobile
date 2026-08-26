> Last updated: 2026-08-25

# Network v2 contract tests

This directory owns the Phase 0 characterization inventory for the frozen
network v2 plan. It validates committed Relay v2 fixtures, framing, route
separation, opaque payload boundaries, and the evidence matrix without editing
native, Relay, Dart, or generated-protocol ownership files.

Run the non-mutating baseline from the repository root:

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh baseline
```

The strict entry point also runs the owning Rust and Go selectors, then fails
if any matrix case is still `characterized` or `gap`:

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh strict
```

The committed matrix is the final acceptance inventory. A baseline pass checks
the fixtures and evidence topology; strict acceptance is green only when every
case is `covered` and the owning Rust/Go selectors pass.
