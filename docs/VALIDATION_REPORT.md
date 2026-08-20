> 最新更新时间：2026-08-20

# Validation Report

- Latest contract validation: 2026-08-20
- Host: WSL2/Linux only
- Frozen Relay V2 baseline: `6ec194bb3a66a748215d3abc11d6da84bd329619`
- Worktree: uncommitted multi-agent implementation changes; no commit created

## Network Protocol V2 contract closeout

This report separates static contract evidence from owner behavior coverage.
`protocol/contract_tests/acceptance_matrix.json` records 60/60 cases as
`covered`. Each case has an owning behavior test or contract test in its
evidence path; source markers alone are not accepted as coverage. The strict
entry point is `scripts/network_v2_acceptance.sh strict`.

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

The ownership closeout is also covered by executable tests: `PeerSupervisor` is
the mutable peer connectivity owner, `PeerPathManager` owns Direct/Relay
physical carriers, `ConnectionSessionStore` retains only connection/security
admission, and Delivery/Transfer/Stream operations acquire a `PathLease` for
each attempt. A transport loss destroys the ConnectionSession; business
recovery uses business identifiers on a fresh connection.

## Checks run

- `python3 -m json.tool protocol/contract_tests/acceptance_matrix.json` —
  passed.
- `SSH_MOBILE_ACCEPTANCE_STRICT=1 python3 -m unittest discover -s
  protocol/contract_tests -p 'test_*.py'` — 13 tests passed, including
  frozen-field, fixture-count, and evidence-policy checks.
- `bash scripts/relay_v2_contract.sh` — fixture/semantic shape checks passed;
  22 fixtures were verified and the Relay V2 descriptor was byte-equal to the
  frozen revision.
- `cargo fmt --all -- --check` — passed.
- `cargo check --workspace --locked` — passed.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` — passed.
- `cargo test --workspace --locked -- --test-threads=1` — passed: network-core 273, network-ffi 12,
  network-nat 44, network-protocol 12, network-quic 6, network-relay 34,
  network-relay-proto 4 unit + 5 golden, network-transfer 14,
  network-transport 7, and network-webrtc 9 passed with 1 external-coturn test
  ignored.
- `bash scripts/network_v2_acceptance.sh strict` — passed end to end: Python,
  NAT, Rust owner selectors, Relay/Go selectors, golden vectors, FFI, and the
  three targeted Flutter owner suites.
- `bash scripts/full_test.sh --only architecture-check --no-bootstrap
  --no-docker --serial` — passed.
- `bash scripts/full_test.sh --only protocol-v2-contract --no-bootstrap
  --no-docker --serial` — passed, including protoc, buf lint, and frozen Relay
  breaking checks (local toolchain: protoc 35.1 and buf 1.72.0; CI remains
  pinned to protoc 27.1 and buf 1.47.2).
- `bash scripts/full_test.sh --only sdk-dart-quality --no-bootstrap
  --no-docker --serial` — passed format, analysis, and tests for the three
  network SDK packages.
- `flutter analyze --no-pub` from `packages/features/feature_mcp` — passed.
- `flutter test --no-pub --no-test-assets --concurrency 1
  --exclude-tags native-loopback test` from `packages/features/feature_mcp` —
  passed: 87 tests. MCP HTTP policy, port-probe, and controller tests now use
  injected in-process boundaries; the production server still owns the real
  loopback socket.
- `bash scripts/full_test.sh --only workspace-features-quality
  --no-bootstrap --serial` — passed in 121s. The WSL profile excludes only the
  `native-loopback` integration test; all other Feature tests ran successfully.
- `bash scripts/full_test.sh --no-bootstrap --serial` — the full local CI mirror
  passed front, Relay, protocol, architecture, SDK, core, App, and Android
  jobs. The native job exposed a scheduler-sensitive late-candidate test, which
  was made deterministic and then passed in the affected native job.
- `git diff --check` — passed.

## Not run on this host

- `flutter test --tags native-loopback
  test/services/mcp/mcp_http_server_native_test.dart` is not runnable under the
  current WSL Flutter tester because real `dart:io` loopback binding hangs;
  this test is executed by the native Linux CI Feature job. Feature analyzer
  also reports existing diagnostics in `feature_playbook` and `feature_sftp`,
  outside this change's touched paths.
- Full physical mobile-device deployment, external Relay clusters, and
  platform-only macOS/iOS/Windows smoke jobs.

The worktree contains the requested multi-agent implementation changes across
Rust, Go, protocol fixtures, Dart/FFI, CI, and documentation. No commit was
made.
