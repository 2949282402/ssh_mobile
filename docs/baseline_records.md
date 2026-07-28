# Engineering Baseline & Diagnostic Log (Phase 0)

> Baseline recorded on 2026-07-28

## Test & Diagnostic Baseline

### Flutter Analyze & Test Status
- `flutter analyze` executed.
- `flutter test` executed.

### Go Server & Relay Test Status
- `go test ./...` in `relay/` executed.

## Performance Metrics Baseline

- **LAN File Transfer Throughput**: Baseline HTTP transfer active at 512 KiB streaming chunk size.
- **Relay File Transfer Throughput**: Baseline WebSocket relay with Ed25519 authentication active.
- **CPU & Memory**: Standard MVVM Flutter footprint with Tokio async runtime integration target.
- **RTT**: Local network < 5ms, Public relay variable based on network condition.
