> Last updated: 2026-07-28

# SSH Mobile Network Native

This Dart FFI package builds and bundles the repository's Rust
`network-ffi` crate. It exposes a managed `NativeNetworkRuntime` that sends
versioned Protobuf commands and streams raw Protobuf events back to Dart.

Native event polling runs on a helper isolate because the Rust poll call may
block. Runtime disposal first asks that isolate to stop, waits for its exit,
and only then destroys the Rust handle.

The current runtime handles peer registration with pinned Ed25519/X25519 keys,
per-peer `PathManager` selection, authenticated Quinn sessions, approved and
verified file receive, cancellation, progress/completion events, and the
current-protocol WSS Relay data path. Relay is configured after enrollment with
memory-only credential/signing material; unsupported commands and routes return
explicit errors rather than synthetic success.

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
