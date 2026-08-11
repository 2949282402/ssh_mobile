> 最新更新时间：2026-08-11

# ADR-021：Native Dart Realtime API Boundary

## Status

Accepted for the native network v1 SDK. The Flutter App and Feature business
layers remain unchanged in this Step.

## Context

Step 9 connected WebRTC signaling to the Rust `NetworkRuntime`, but the Dart
package still exposed only a raw command/event byte stream for the new Realtime
route. That left callers responsible for encoding command tags and decoding
Realtime state or signaling payloads, which could accidentally expose native
handles or couple application code to the wire layout.

## Decision

- `NativeNetworkRuntime` owns the FFI handle, helper isolate, Rust runtime,
  sockets, Session state, and WebRTC peers. Dart never stores or receives a
  Quinn connection, UDP socket, Tokio handle, or WebRTC object.
- `startRealtimeSession`, `stopRealtimeSession`, and `sendRealtimeSignal`
  accept only stable identifiers, enum values, revisions, and bounded
  `Uint8List` payloads. They return the queue-level
  `NativeOperationStatus`; execution acceptance and failures arrive through
  `NativeCommandResultEvent`.
- `NativeNetworkRuntime.events` decodes v1 command results and Realtime state
  or signaling events from the helper-isolate stream. Unknown future event
  payloads are ignored, while malformed or unsupported-version frames are
  rejected without terminating the runtime or exposing raw native state.
- The Dart codec mirrors the Rust `network-protocol` tags and bounds only; Rust
  remains the wire-contract and business-state owner. Empty ICE candidate
  payloads are accepted for end-of-candidates, while SDP/answer payloads must
  remain non-empty and all signaling data stays bounded.
- The existing generic App-level `NetworkService` and `network_sdk` model
  boundary are not replaced or duplicated by this low-level package. This
  Step only closes the native Realtime API boundary, so no Flutter UI or client
  business code is changed.

## Consequences

The native package can expose WebRTC Realtime control without increasing the C
ABI surface or leaking transport-specific objects. Callers can correlate
queue acceptance with typed events using the generated command ID, and future
wire events remain forward-compatible through bounded unknown-event handling.
The App Shell still decides how these native events map into its existing
`network_sdk` contracts when that client integration is authorized.

## Verification

- `dart format --output=none --set-exit-if-changed lib test hook` passed in
  `packages/infrastructure/ssh_mobile_network_native`.
- `flutter analyze --no-pub` passed in the native package.
- `flutter test --no-pub` passed with seven native package tests, including
  lifecycle ordering, helper-isolate polling, typed command results, bounded
  Realtime signaling, v1 rejection, and empty ICE candidate handling.
- Rust FFI tests continue to round-trip the same protobuf command/event tags
  without exposing raw WebRTC handles.
