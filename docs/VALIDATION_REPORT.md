> 最新更新时间：2026-08-20

# Validation Report

- Latest contract validation: 2026-08-20
- Host: WSL2/Linux only
- Frozen Relay V2 baseline: `6ec194bb3a66a748215d3abc11d6da84bd329619`
- Worktree: uncommitted multi-agent implementation changes; no commit created

## Network Protocol V2 contract closeout

This report separates static contract evidence from owner behavior coverage.
`protocol/contract_tests/acceptance_matrix.json` records the current inventory
as `characterized`: source markers and smoke checks prove that an evidence path
exists, but do not prove runtime behavior. A case may become `covered` only
after the owner behavior test selector has actually run and its result is
recorded. The strict entry point is
`scripts/network_v2_acceptance.sh strict`.

The frozen Relay V2 documentation and checks now assert:

- `ConnectivityOffer` has no `target_device_id`; a successful Resolve on the
  shared control connection must precede Offer, without holding a lock across
  the answer/direct-probe work.
- `RealtimeSignal` retains `target_device_id` but has no
  `sender_device_id`; the receiver obtains the remote identity from the
  established realtime binding and fails closed for an unknown binding.
- `RelayDataFrame` has no `ready` oneof field and there is no
  `RelayDataReady` protobuf message.
- PairReady is only the WebSocket Ping
  `ssh-mobile-relay-paired-v1:<reservation_id>`; it is not a protobuf frame.
- Reservation TTL governs pending admission only. Active data lifetime is
  independent of reservation TTL and natural credential expiry; explicit
  revocation still closes pending, active, and counterpart endpoints.

## Checks run

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` —
  passed.
- `python3 -m unittest protocol.contract_tests.test_frozen_network_contract` —
  10 tests passed, including frozen-field, fixture-count, and evidence-policy
  checks.
- `bash scripts/relay_v2_contract.sh` — fixture/semantic shape checks passed;
  22 fixtures were verified. The script explicitly reported
  `NOT RUN: protoc unavailable` for descriptor equality and therefore did not
  claim a complete descriptor gate.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` — passed.
- `cargo test --workspace --locked` — passed: network-core 215, network-ffi 8,
  network-nat 42, network-protocol 12, network-quic 6, network-relay 33,
  network-relay-proto 4 unit + 5 golden, network-transfer 14,
  network-transport 7, and network-webrtc 9 passed with 1 external-coturn test
  ignored.
- `git diff --check` — passed.

## Not run on this host

- `protoc` descriptor equality and the pinned CI `buf lint`/`buf breaking` gates:
  `protoc` and `buf` are unavailable locally.
- Go behavior suites: `go` is unavailable locally.
- Dart/Flutter behavior suites: `dart` and `flutter` are unavailable locally.
- `scripts/network_v2_acceptance.sh strict`: intentionally not run here because
  its Rust/Go owner selectors require the unavailable toolchains and the matrix
  remains characterized rather than covered.
- Redis/MySQL integration, external Relay clusters, and physical mobile devices.

The worktree contains the requested multi-agent implementation changes across
Rust, Go, protocol fixtures, Dart/FFI, CI, and documentation. No commit was
made.
