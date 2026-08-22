> Last updated: 2026-08-21

# FFI ABI Audit

Status: BLOCKED

Scope: `network-ffi`, `network-native`, and the Dart bridge. This was a
read-only audit; no implementation files were changed.

## Findings

- PASS: `SshNetBuffer` uses `#[repr(C)]` and Rust/Dart fields and extern-C
  signatures match (`network-ffi/src/lib.rs:30-37,331-345,435-572`;
  `ssh_net_buffer.dart:5-11`). Exported symbols were checked with `nm -D`.
- PASS: Dart allocates command buffers and Rust copies synchronously; Rust
  allocates events and Dart copies then frees them
  (`network_native_isolate.dart:110-124,168-190`).
- BUG: `NativeNetworkRuntime.stop()` sets `_stopped` before waiting for the
  isolate; concurrent dispose can bypass the wait and destroy the handle
  (`ssh_mobile_network_native.dart:260-288`).
- BUG: Isolate timeout paths call `Isolate.kill()` without waiting for `onExit`
  before stop/destroy (`network_native_isolate.dart:128-153`; startup path
  `:96-106`). The poller may still be executing FFI.
- BUG: On stop failure, `dispose()` clears `_handle` before throwing and can
  lose the ability to destroy the native handle (`ssh_mobile_network_native.dart:271-285`).
- ARCHITECTURE RISK: `terminal_commands` has no bound and completed commands
  remain indefinitely (`network-ffi/src/lib.rs:181-186,262-280`); current cap
  coverage only checks pending commands (`:892-901`).
- TEST GAP: No coverage for double destroy, concurrent stop/dispose, kill plus
  exit confirmation, C layout offsets, or free-error paths. Normal-order Rust,
  native Dart, and transport suites pass but do not prove these cases.

## Required Changes

- Serialize stop/dispose with a shared in-flight Future/lock; wait for isolate
  exit before Rust stop/destroy and keep failure cleanup retryable.
- After kill, await `onExit`; do not destroy while exit remains unconfirmed.
- Guarantee exactly-once event-buffer free with `try/finally`.
- Add ABI layout/calling-convention, concurrent lifecycle, double-destroy, and
  buffer-lifecycle tests.
- Bound terminal command deduplication with an eviction policy and memory test.

## Risk

Normal-order tests pass, but release paths can still encounter FFI use-after-free,
native handle leaks, and long-running memory growth. ABI acceptance is blocked.
