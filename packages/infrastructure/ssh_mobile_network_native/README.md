> Last updated: 2026-08-07

# SSH Mobile Network Native

This Dart FFI package builds and bundles the repository's Rust
`network-ffi` crate. It exposes a managed `NativeNetworkRuntime` that sends
versioned Protobuf commands and streams raw Protobuf events back to Dart.

Native event polling runs on a helper isolate because the Rust poll call may
block. Runtime disposal first asks that isolate to stop, waits for its exit,
and only then destroys the Rust handle.

The current v1 runtime handles peer registration with pinned Ed25519/X25519
keys, per-peer `PathManager` selection, authenticated Quinn sessions, approved
and verified file receive, cancellation, progress/completion events, and the
native WSS Relay data path. Dart performs enrollment and secure credential
lookup only; Relay data frames stay in Rust. Unsupported commands and routes
return explicit errors rather than synthetic success.

## v1 contract

- The package is intentionally development-stage v1 only. It does not migrate
  or fall back to another network protocol version.
- `NativeNetworkRuntime` exposes typed operation status values to Dart and
  keeps raw FFI integers private to the package.
- Runtime disposal is ordered as `Running -> Stopping -> Stopped -> Destroyed`;
  stopping is idempotent and no command is accepted after stopping begins.
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
