> 最新更新时间：2026-08-12

# Validation Report

- Latest source validation: 2026-08-12
- Full build/coverage baseline: 2026-07-10
- Host: Windows 10 x64
- Flutter: 3.44.2 stable
- Dart: 3.12.2

## Automated Results

Native network, Relay, workspace Dart, Flutter App/Terminal, and Android/Windows
debug checks were refreshed by the successful main GitHub Actions run recorded below.
Coverage and release signing retain the most recent full release-chain evidence from
2026-07-10; no frontend or client business source was modified.

GitHub Actions main evidence:

- HEAD: `d40c532189c1d41bdb714310ea2ae75e11ec506e`
- Workflow: `Flutter`, Run `#31565893203`
- Result: `success`
- Jobs: `sdk-dart-quality`, `workspace-quality`, `architecture-check`,
  `relay-quality`, `native-network-quality`, `analyze-and-test`, `android-build`,
  `windows-build`, `macos-build`, `ios-build`, `terminal-smoke-build`, and
  `front-quality` all succeeded.

| Check | Result |
| --- | --- |
| Dart formatting | Full App + Terminal slice: 288 files checked, 0 changes required |
| Flutter analyzer | Full App passed with `--no-fatal-infos` (26 existing info-level lints); Terminal slice passed with 0 issues |
| Unit and widget tests | Full App: 801 passed; Terminal slice: 3 passed |
| Workspace Dart gate | `dart run melos run format`, `dart run melos run analyze`, and `dart run melos run test` passed across all 21 workspace packages; existing info-level analyzer output remained non-fatal |
| Repository architecture gates | `architecture_check`, `compatibility_check`, `duplicate_implementation_check`, `check_module_dependencies`, and `check_resource_owners` all passed |
| Network-layer source size | Maintained network Dart/Rust/Go files all below 1000 lines; generated and unrelated legacy files excluded |
| Native Dart package | `dart format --output=none --set-exit-if-changed lib test hook`, `flutter analyze --no-pub`, and `flutter test --no-pub` passed with 7 package tests; typed Realtime command/event facade is covered |
| Rust network workspace | `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --offline -- -D warnings`, and privileged `cargo test --workspace --offline` passed after Step 7; the latest run includes 52 `network-core`, 10 `network-webrtc` (9 active + 1 TURN integration test), 3 FFI, and 13 `network-nat` tests |
| Delivery runtime wiring | `network-core` distinguishes `DuplicateInFlight` from `DuplicateProcessed`, keeps `SessionBoundOrdered` behind expected sequence + in-flight ACK gating, bounds reorder count/bytes/gap, preserves the native Recovery Epoch boundary, and keeps logical plaintext plus crypto mode in pending state; privileged loopback `cargo test -p network-core --lib --locked --offline` passed with 50 tests |
| Session application E2EE | Session-owned `CryptoContext` derives directional HKDF-SHA256/AES-256-GCM keys from paired DeviceIdentity E2E keys, keeps state across Route changes, re-encrypts Delivery retries with fresh nonces, rejects tamper/wrong-key/replay/nonce reuse, and protects channel payloads on QUIC and Relay plus Relay file chunks; disabled mode is explicit and secure-by-default E2EE is integration-tested |
| Runtime task supervision | `RuntimeTaskSupervisor` owns the command worker, QUIC accept/handshake, Relay reconnect/events, Session reconnect/direct-upgrade/path metrics, Delivery retry, channel/file receivers, and transfer workers; root/session cancellation joins all registered tasks before stop returns; the native test suite includes cancellation/join coverage and a 100-cycle loopback bind/stop/recreate stress test |
| Transfer/Connection decoupling | `TransferSession` owns state, Manifest, offset, cancellation, and logical SessionId without a Connection handle; `TransferDispatcher` selects the current QUIC/Relay route, and same-Session direct/Relay resume is tested; `cargo test -p network-transfer -p network-core --locked --offline` passed with 47 tests |
| Relay-to-Direct upgrade | Relay-backed Sessions keep their route during a deduplicated background candidate probe; an authenticated direct Connection must remain stable before `replace_route_if_current` atomically promotes it, then Delivery recovery and transfer resume run before direct receivers start |
| Coordinated QUIC NAT traversal | Candidate Offer/Answer now carries generation, attempt ID, and a 500–8000 ms connect window; both peers can run identity-authenticated QUIC Initial attempts on the shared UDP socket, stale answers are rejected, multi-server STUN validates transaction IDs and IPv4/IPv6 XOR-MAPPED-ADDRESS, and the unused raw UDP probe module was removed |
| Relay file resume | Relay re-offer binds stable TransferId + Manifest Hash + File Hash, accept returns fixed-chunk offset, socket disconnect preserves native `.part`, auto reconnect reclaims paused transfers, and verified final files are idempotent after lost completion ACK |
| Docker Relay integration harness | `docker compose --env-file .env up -d --build`, functional Candidate/WebRTC signaling plus file control/binary loopback, Caddy restart `recover`, and Relay process restart `restart` all passed; the harness remains under `relay/cmd/relay_smoke/` |
| Network Fault Matrix (Step 9) | Fixed A–J matrix added in `docs/NETWORK_FAULT_MATRIX.md`; full Rust workspace passed offline (network-core 52, FFI 3, NAT 13, QUIC 5, Relay 6, transfer 12, transport 4, WebRTC 9 active plus 1 TURN test), LAN DataChannel and coturn relay-only tests passed, Go `gofmt`/`go vet`/`go test` passed, and functional/Caddy-recovery/Relay-restart smoke runs returned `FUNCTIONAL_PASS`, `NETWORK_RECOVERY_PASS`, and `RESTART_RECOVERY_PASS`; physical G/I and 1 GiB+ device transfer remain unverified |
| Relay channel control | `channel_message`/`channel_ack` opaque forwarding integration test passed in `go test ./...`; Rust Relay codec tests passed |
| Go Relay | `gofmt -l .`, `go vet ./...`, and `go test ./...` passed |
| Native WebRTC runtime | `network-webrtc` uses locked stable `rtc 0.9.1`; `network-core::RealtimeManager` owns the WebRTC Peer beside QUIC/Relay, authenticated Relay forwards bounded versioned Offer/Answer/ICE/Restart/Close controls, and `RealtimeIoDriver` now owns the UDP/ICE/DTLS/SRTP/SCTP/DataChannel/timer pump under `RuntimeTaskSupervisor` |
| WebRTC DataChannel E2E | Privileged localhost test passed between two native driver owners and a `network-core` supervisor test passed with two `realtime:<id>` task groups; payload delivery was verified after real ICE and DTLS/SCTP negotiation |
| WebRTC TURN fallback | A pinned local coturn 4.6.3 server passed the relay-only DataChannel test with direct ICE disabled; the native GitHub job starts the same image and runs the ignored TURN test explicitly |
| Native WebRTC FFI boundary | Existing protobuf command/event buffers carry Start/Stop/Signal commands and Realtime state/signal events; `ssh_mobile_network_native` now exposes bounded typed commands/results/state/signaling through the helper-isolate stream; `network-ffi` round-trip coverage passed without exposing a raw WebRTC handle or changing Flutter/client code |
| Flutter Realtime SDK boundary | `network_sdk.RealtimeClient` exposes only `RealtimeSession` lifecycle/state/media contracts; App Shell maps native events and keeps SDP/ICE/command-result details internal. `network_sdk` and `network_transport` analyzers and package tests passed in GitHub Actions Run `#31565893203`; local WSL `flutter_tester` still cannot complete its loopback handshake, but CI verification is green |
| Generic native transports | `network-transport` TCP/UDP/WebSocket loopbacks and `network-core::connection::GenericConnection` lifecycle/size/backpressure/shutdown tests passed; generic transports now enter the composed native Route boundary |
| Composed Route fallback | `RouteTopology × RouteTransport` removes flat transport/topology combinations; blocked QUIC selects TCP for `ReliableStream`, blocked UDP selects WebSocket/WSS only for a reliable-message intent, and UDP cannot silently carry reliable delivery |
| v1 static compatibility audit | No old transport, Dart Relay data-plane, protocol fallback, or v2/v3/v4 network symbols found |
| Non-generated line coverage | 39.3% (`12690/32302`), last verified 2026-07-10 |
| Coverage regression floor | 35% |
| Android debug APK | Built successfully |
| Full App Windows debug | `flutter build windows --debug --no-pub` built `apps/ssh_mobile_full/build/windows/x64/runner/Debug/ssh_mobile.exe` successfully |
| Terminal Windows debug | Terminal `flutter pub get` followed by `flutter build windows --debug --no-pub` built `apps/ssh_mobile_terminal/build/windows/x64/runner/Debug/ssh_mobile_terminal.exe` successfully |
| Android release APK | Built successfully without signing credentials |
| Android release signature check | Expected unsigned result confirmed with `apksigner` |
| Windows release executable | Built successfully |
| App icon generation | Deterministic across 33 PNG targets and one ICO target |
| Drift generated database code | Deterministic on a second build |
| Shared Codex/Claude maintenance skill | Synchronized |
| Web manifest JSON and Git diff checks | Passed |
| GitHub Actions main | Run `#31565893203` at HEAD `d40c532189c1d41bdb714310ea2ae75e11ec506e` completed with `success`; all 12 independent quality, test, and platform-build jobs passed |

## Commands

Latest source validation:

```powershell
dart pub get
dart run melos run format
dart run melos run analyze
dart run melos run test

dart format --output=none --set-exit-if-changed apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool apps/ssh_mobile_terminal/lib apps/ssh_mobile_terminal/test
cd apps/ssh_mobile_full
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub
cd ../ssh_mobile_terminal
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub
cd ../..
dart run tool/architecture_check.dart
dart run tool/compatibility_check.dart
dart run tool/duplicate_implementation_check.dart
dart run tool/check_module_dependencies.dart
dart run tool/check_resource_owners.dart
git diff --check
```

Native package validation from `packages/infrastructure/ssh_mobile_network_native`:

```powershell
dart format --output=none --set-exit-if-changed lib test hook
flutter analyze --no-pub
flutter test --no-pub
```

Rust validation from `native/network_core`:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
# Native WebRTC E2E (native/network_core; coturn at 127.0.0.1:3478)
cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
```

Relay validation from `relay`:

```powershell
gofmt -l .
go vet ./...
go test ./...
```

Docker Relay integration harness:

```powershell
docker compose --env-file .env up -d --build
go run ./cmd/relay_smoke -scenario functional -base http://localhost:18080
go run ./cmd/relay_smoke -scenario recover -base http://localhost:18080 -trigger <fault-trigger>
go run ./cmd/relay_smoke -scenario restart -base http://localhost:18080 -trigger <fault-trigger>
```

The repository-root `flutter analyze` command is not used as a quality gate:
it intentionally sees the vendored `third_party/xterm` example/test sources,
which are excluded by the Full App analyzer and lack that package's optional
example-only dependencies. The package-scoped checks above are the authoritative
Flutter results for this validation.

Full build and coverage baseline from 2026-07-10:

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
dart run build_runner build
flutter analyze --no-pub
flutter test --no-pub --coverage
dart run tool/check_coverage.dart --minimum=35
flutter build apk --debug --no-pub
flutter build apk --release --no-pub
flutter build windows --no-pub
cd ../ssh_mobile_terminal
flutter pub get
flutter build windows --debug --no-pub
cd ../..
```

The unsigned Android release is a build-chain verification artifact, not a
publishable APK. Configure the release signing environment variables documented
in `docs/RELEASE_CHECKLIST.md` before distribution.

## Not Verified on This Host

- Android touch, lifecycle, background execution, network switching, and
  performance on a physical device
- Step 9 physical Fault Matrix scenarios G/I/J: Wi-Fi-to-4G/5G switching,
  background/foreground recovery, and 1 GiB+ file resume on real devices
- iOS device behavior and signed archive creation
- TalkBack and VoiceOver behavior on physical devices
- Store metadata, privacy policy, permanent application identifiers, and legal
  license choice

These remaining items require owner decisions, external accounts, CI execution,
or physical devices and are tracked in `docs/RELEASE_CHECKLIST.md`.
