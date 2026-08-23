> Last updated: 2026-08-23

# Network V2 Validation Report

This report is the current validation index for branch
`agent/network-v2-final-20260819`.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

`GitHub CI: NOT RE-RUN for LOCAL_VALIDATION_HEAD; prior CI evidence is scoped
only to FINAL_CLOSURE_BASE_SHA. No push or PR state change was performed.`

## Contract and owner closeout

`protocol/contract_tests/acceptance_matrix.json` records 69/69 cases as
`covered`. `bash scripts/network_v2_acceptance.sh strict` is the strict entry
point and preserves the frozen Relay V2 wire shape: target-less
`ConnectivityOffer`, request/attempt correlation, fail-closed Resolve status,
and separate Control/Data channels.

The final-fix owner tests add concrete coverage for the Stage B transaction and
the Stage C fallback: one authoritative Resolve, one Offer enqueue, a recorded
Direct failure, one Reserve, and the same Resolve snapshot used by the
connectivity coordinator. The lifecycle regressions also prove cancellation and
overall timeout cleanup do not poison the next admission. All instrumentation
is in independent test files; no production observer, hook, protobuf fixture,
public Dart/Rust contract, or FFI ABI was changed.

## Checks run for the final-fix working tree

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` — passed.
- `bash scripts/network_v2_acceptance.sh strict` — passed: the initial
  17-case contract inventory had 3 test-defined architecture-guard skips; the
  final strict pass ran all 17 cases, plus the selected Rust/Go/Dart owner
  suites and concrete RelayControlClient integration selector.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` — passed.
- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked` —
  passed: 61/61, including healthy-path Offer suppression, bounded active
  `NOT_READY` retry, lifecycle cancellation/timeout reconnect isolation, and
  Stage C order/count evidence.
- `cargo test -p network-relay --locked` — passed: 45/45.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1` — passed: 7/7.
- `cargo test --workspace --locked` — passed: all workspace crates.
- Go fmt/test/race/vet/govulncheck — passed; SDK, transport, native FFI, and
  app static/unit no-coverage selectors — passed.
- `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial` —
  attempted; front/native/SDK/Relay/protocol/workspace/app-static stages passed,
  but the App coverage shard stayed at `loading` without a Flutter VM Service in
  WSL. The run was stopped and is recorded as an environment gap, not a pass.
- `CLIENT_BACKEND_E2E_STORAGE=memory bash scripts/client_backend_e2e.sh strict`
  and the MySQL equivalent — both passed.
- Exact protocol commands (`protoc`, `bash scripts/relay_v2_contract.sh`,
  `buf lint`, scoped `buf breaking`) — passed.
- `git diff --check` — passed.

## Not run on this host

- Windows desktop, macOS/Xcode, iOS/CocoaPods, and physical mobile lifecycle
  jobs require their native CI hosts.
- Real multi-host Relay deployment, physical-device lifecycle, and broader
  transport fault injection require external services/devices; local Stage C
  order/count evidence and RelayData owner coverage are complete.
- If a WSL Flutter VM Service environment gap must be closed, use native Windows
  PowerShell 7 or CI as separately labeled evidence; a product/test failure is
  not eligible for this fallback and Windows evidence cannot become Linux PASS.
