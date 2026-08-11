> 最新更新时间：2026-08-11

# Validation Report

- Latest source validation: 2026-08-11
- Full build/coverage baseline: 2026-07-10
- Host: Windows 10 x64
- Flutter: 3.44.2 stable
- Dart: 3.12.2

## Automated Results

Native network, Relay, and package-scoped Flutter checks were refreshed at the
latest HEAD. Coverage and platform-build rows retain the most recent full
release-chain evidence from 2026-07-10 and were not re-run because this Step
is limited to native network/report validation.

| Check | Result |
| --- | --- |
| Dart formatting | Full App + Terminal slice: 288 files checked, 0 changes required |
| Flutter analyzer | Full App passed with `--no-fatal-infos` (26 existing info-level lints); Terminal slice passed with 0 issues |
| Unit and widget tests | Full App: 801 passed; Terminal slice: 3 passed |
| Network-layer source size | Maintained network Dart/Rust/Go files all below 1000 lines; generated and unrelated legacy files excluded |
| Native Dart package | `flutter analyze --no-pub` passed; `flutter test --no-pub` passed with 4 package tests |
| Rust network workspace | `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked --offline -- -D warnings`, and `cargo test --workspace --locked` passed; 67 tests passed, including Candidate Offer/Answer generation handling, multi-candidate ranking, cross-Connection Delivery recovery, Relay resume binding, and TransferSession state tests |
| Delivery runtime wiring | `network-core` now sends `DataMessage` through QUIC uni streams or Relay opaque controls, binds Delivery to real `SessionId`, replays RecoverySnapshot, scans retry backoff, validates ACK epoch, and emits typed channel/ACK events; `cargo test -p network-core --lib --locked --offline` passed with 24 tests |
| Transfer/Connection decoupling | `TransferSession` owns state, Manifest, offset, cancellation, and logical SessionId without a Connection handle; `TransferDispatcher` selects the current QUIC/Relay route, and same-Session direct/Relay resume is tested; `cargo test -p network-transfer -p network-core --locked --offline` passed with 36 tests |
| Relay file resume | Relay re-offer binds stable TransferId + Manifest Hash + File Hash, accept returns fixed-chunk offset, socket disconnect preserves native `.part`, auto reconnect reclaims paused transfers, and verified final files are idempotent after lost completion ACK |
| Docker Relay integration harness | `docker compose --env-file .env up -d --build`, `go run ./cmd/relay_smoke -scenario functional` (including Candidate Offer/Answer), and the Caddy restart `recover` scenario passed; the harness remains under `relay/cmd/relay_smoke/` |
| Relay channel control | `channel_message`/`channel_ack` opaque forwarding integration test passed in `go test ./...`; Rust Relay codec tests passed |
| Go Relay | `gofmt -l .`, `go vet ./...`, and `go test ./...` passed |
| Native WebRTC | `network-webrtc` uses locked stable `rtc 0.9.1`; SDP/ICE/DataChannel/Audio/Video transceiver and media QoS tests passed |
| Generic native transports | `network-transport` TCP/UDP/WebSocket loopback tests passed |
| v1 static compatibility audit | No old transport, Dart Relay data-plane, protocol fallback, or v2/v3/v4 network symbols found |
| Non-generated line coverage | 39.3% (`12690/32302`), last verified 2026-07-10 |
| Coverage regression floor | 35% |
| Android debug APK | Built successfully |
| Android release APK | Built successfully without signing credentials |
| Android release signature check | Expected unsigned result confirmed with `apksigner` |
| Windows release executable | Built successfully |
| App icon generation | Deterministic across 33 PNG targets and one ICO target |
| Drift generated database code | Deterministic on a second build |
| Shared Codex/Claude maintenance skill | Synchronized |
| Web manifest JSON and Git diff checks | Passed |

## Commands

Latest source validation:

```powershell
dart format --output=none --set-exit-if-changed apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool apps/ssh_mobile_terminal/lib apps/ssh_mobile_terminal/test
cd apps/ssh_mobile_full
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub
cd ../ssh_mobile_terminal
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub
cd ../..
git diff --check
```

Native package validation from `packages/infrastructure/ssh_mobile_network_native`:

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Rust validation from `native/network_core`:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
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
```

The unsigned Android release is a build-chain verification artifact, not a
publishable APK. Configure the release signing environment variables documented
in `docs/RELEASE_CHECKLIST.md` before distribution.

## Not Verified on This Host

- Android touch, lifecycle, background execution, network switching, and
  performance on a physical device
- iOS device behavior and signed archive creation
- macOS and unsigned iOS jobs in the updated GitHub Actions workflow
- TalkBack and VoiceOver behavior on physical devices
- Store metadata, privacy policy, permanent application identifiers, and legal
  license choice

These remaining items require owner decisions, external accounts, CI execution,
or physical devices and are tracked in `docs/RELEASE_CHECKLIST.md`.
