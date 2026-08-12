> Last updated: 2026-08-12

# SSH Mobile Network Native

This Dart FFI package builds and bundles the repository's Rust
`network-ffi` crate. It exposes a managed `NativeNetworkRuntime` that sends
versioned Protobuf commands and streams raw Protobuf events back to Dart.

Native event polling runs on a helper isolate because the Rust poll call may
block. Runtime disposal first asks that isolate to stop, waits for its exit,
and only then destroys the Rust handle.

The current v1 runtime handles peer registration with pinned Ed25519/X25519
keys, per-peer `PathManager` selection, authenticated Quinn sessions, approved
and verified file receive, cancellation, progress/completion events, the
native WSS Relay data path, and a Session-owned WebRTC Realtime route. Dart can
submit bounded Realtime commands and consume typed state/signaling events;
Rust still owns all long-lived network state, sockets, WebRTC peers, and Relay
data frames. Unsupported commands and routes return explicit errors rather than
synthetic success.

## v1 contract

- The package is intentionally development-stage v1 only. It does not migrate
  or fall back to another network protocol version.
- `NativeNetworkRuntime` exposes typed operation status values to Dart and
  keeps raw FFI integers private to the package.
- `NativeNetworkRuntime.startRealtimeSession`,
  `stopRealtimeSession`, and `sendRealtimeSignal` expose only stable IDs,
  revisions, enum values, and bounded byte payloads. `events` decodes command
  results and Realtime state/signaling events without exposing Rust pointers,
  Quinn connections, UDP sockets, or WebRTC raw objects.
- Delivery application acknowledgements are identified by logical Session ID,
  Channel ID, and Message ID only. Recovery epochs remain native Delivery state;
  Dart must not cache or echo an epoch from an earlier event.
- `SessionBoundOrdered` delivery is also native-owned: only the expected
  sequence reaches the application, while later messages stay in bounded
  reorder state until the current application ACK releases the next one.
- Runtime disposal is ordered as `Running -> Stopping -> Stopped -> Destroyed`;
  stopping is idempotent and no command is accepted after stopping begins.
- `NativeNetworkRuntime.boundLocalPort` is a read-only diagnostic for controlled
  integration tests. It reports the port atomically bound by native QUIC after
  configuration and returns `null` before configuration or after stopping; it
  does not expose a socket, Quinn handle, or client business API.
- Relay enrollment, credentials, and configuration stay in Dart; the native
  Rust runtime owns the authenticated WSS data path and its end-to-end
  encrypted frames.
- LAN WebShare is HTTPS-only. A browser without a secure context or required
  WebCrypto support is rejected instead of silently downgraded.

## Supported build targets

- Windows: x64 and arm64
- Android: arm64, x64, and armv7
- iOS: arm64 device, arm64 simulator, and x64 simulator
- macOS: arm64 and x64
- Linux: arm64 and x64

The build hook invokes Cargo with `--locked`. Cargo and the requested Rust
target must be installed. Android builds also require an installed NDK
discoverable through the standard Android SDK or NDK environment variables.

## Validation

From this package directory:

```sh
dart analyze
dart test
```

From `native/network_core`:

```sh
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
```

## Package contract

- 职责：提供 Rust `network-ffi` 的 Dart FFI facade、native asset hook 和 v1 协议绑定。
- 不负责：Feature 业务、App Shell 生命周期、数据库或第二套 Dart 网络协议实现。
- Public API：`package:ssh_mobile_network_native/ssh_mobile_network_native.dart`。
- 依赖：Dart FFI、`code_assets`、`hooks` 和 Rust `native/network_core` 构建产物。
- 数据库：不拥有数据库，也不持久化配对凭据、Token 或业务历史。
- 生命周期与资源 Owner：调用方拥有 `NativeNetworkRuntime`；必须先停止 helper
  isolate，再销毁 Rust handle，并保持 stop/destroy 幂等。
- 测试命令：`dart analyze`、`dart test`、Cargo format/test/clippy 检查。
