> Last updated: 2026-08-22

# Network V2 Validation Report

This report is the current validation index for branch
`agent/network-v2-final-20260819`. The validation base commit is
`b61347cbbb062a079ef1e6daa7f82c50123a799f`; final-fix changes remain
intentionally uncommitted in the working tree.

## Contract and owner closeout

`protocol/contract_tests/acceptance_matrix.json` records 60/60 cases as
`covered`. `bash scripts/network_v2_acceptance.sh strict` is the strict entry
point and preserves the frozen Relay V2 wire shape: target-less
`ConnectivityOffer`, request/attempt correlation, fail-closed Resolve status,
and separate Control/Data channels.

The final-fix owner tests add concrete coverage for the Stage B transaction:
one authoritative Resolve, one Offer enqueue, and the same Resolve snapshot
used by the connectivity coordinator. The additive transaction type is an
internal Rust `network-relay` adapter surface; no protobuf fixture or public
Dart/FFI SDK surface was changed.

## Checks run on the final-fix working tree

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` — passed.
- `bash scripts/network_v2_acceptance.sh strict` — passed: 17 contract checks,
  3 documented skips, selected Rust/Go/Dart owner suites, and the concrete
  RelayControlClient integration selector.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked` —
  passed: 24/24, including healthy-path Offer suppression, bounded active
  NOT_READY retry, and epoch-hint fencing.
- `cargo test -p network-relay --locked` — passed: 37/37.
- Concrete integration selector — passed: 1/1.
- `bash scripts/full_test.sh --no-bootstrap --no-coverage --serial` — passed all
  12 runnable Linux jobs in 731 seconds; terminal-smoke, Windows, macOS, and
  iOS were explicitly skipped by the WSL profile.
- `bash scripts/front_coverage.sh` — passed at 95.78% line coverage.
- `bash scripts/backend_coverage.sh` — passed at 82.1% filtered Go lines with
  Docker-backed MySQL/Redis.
- `bash scripts/sdk_coverage.sh` — passed at 84.46% Dart and 84.32% Rust lines.
- Focused App client coverage — attempted with a bounded 2-minute timeout; the
  Flutter VM Service did not become ready in WSL, so no client tests ran.
- `git diff --check` — passed.

## Not run on this host

- Windows desktop, macOS/Xcode, iOS/CocoaPods, and physical mobile lifecycle
  jobs require their native CI hosts.
- Real multi-host Relay deployment and full Stage C Direct-failure → Relay data
  integration require external services/devices; local Stage C evidence remains
  predicate-only.
