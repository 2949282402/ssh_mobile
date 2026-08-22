> Last updated: 2026-08-22

# Network V2 Validation Report

This report is the current validation index for branch
`agent/network-v2-final-20260819`. Validation is anchored to base commit
`85663c93fd1881ad32a1924f6ca51623d6373640`; the final-fix changes are captured
in the subsequent functional commits on this branch.

## Contract and owner closeout

`protocol/contract_tests/acceptance_matrix.json` records 66/66 cases as
`covered`. `bash scripts/network_v2_acceptance.sh strict` is the strict entry
point and preserves the frozen Relay V2 wire shape: target-less
`ConnectivityOffer`, request/attempt correlation, fail-closed Resolve status,
and separate Control/Data channels.

The final-fix owner tests add concrete coverage for the Stage B transaction:
one authoritative Resolve, one Offer enqueue, and the same Resolve snapshot
used by the connectivity coordinator. The additive transaction type is an
internal Rust `network-relay` adapter surface; no protobuf fixture or public
Dart/FFI SDK surface was changed.

## Checks run for the final-fix working tree

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` — passed.
- `bash scripts/network_v2_acceptance.sh strict` — passed: the initial
  17-case contract inventory had 3 test-defined architecture-guard skips; the
  final strict pass ran all 17 cases, plus the selected Rust/Go/Dart owner
  suites and concrete RelayControlClient integration selector.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked` —
  passed: 24/24, including healthy-path Offer suppression, bounded active
  NOT_READY retry, and epoch-hint fencing.
- `cargo test -p network-relay --locked` — passed: 39/39.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1` — passed: 4/4.
- `cargo test --workspace --locked` — passed: all workspace crates.
- `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial` —
  attempted; front/native/SDK/Relay/protocol/workspace jobs passed, but the
  App Flutter shard stalled while loading tests in WSL. The run was stopped
  after the retry began and is not counted as a pass.
- `bash scripts/front_coverage.sh` — passed at 95.78% line coverage.
- `bash scripts/backend_coverage.sh` — passed at 82.1% filtered Go lines with
  Docker-backed MySQL/Redis.
- `bash scripts/sdk_coverage.sh` — passed at 90.67% Dart and 90.81% Rust lines.
- Focused App client coverage — attempted with a bounded 2-minute timeout; the
  Flutter VM Service did not become ready in WSL, so no client tests ran.
- `git diff --check` — passed.

## Not run on this host

- Windows desktop, macOS/Xcode, iOS/CocoaPods, and physical mobile lifecycle
  jobs require their native CI hosts.
- Real multi-host Relay deployment and full Stage C Direct-failure → Relay data
  integration require external services/devices; local Stage C evidence remains
  predicate-only.
