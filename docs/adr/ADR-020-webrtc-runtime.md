> 最新更新时间：2026-08-11

# ADR-020：WebRTC Runtime Signaling Integration

## Status

Accepted for the native network v1 runtime. Flutter/Dart API expansion remains
the following Step.

## Context

`network-webrtc` already owns the bounded sans-I/O PeerConnection, SDP/ICE,
DataChannel, Audio/Video transceivers, and media QoS. It was not reachable from
`network-core`, so the runtime had no Session-owned realtime route or signaling
boundary.

## Decision

- `network-core` owns one `RealtimeManager` beside the ordinary Data Route.
  A logical Session may therefore keep QUIC/Relay for keyboard, terminal,
  clipboard, files, and Delivery while using a separate WebRTC Peer for audio,
  video, or DataChannel traffic.
- Native protobuf commands/events expose only `StartRealtimeSession`,
  `StopRealtimeSession`, `SendRealtimeSignal`, `RealtimeStateChanged`, and
  `RealtimeSignal`. They carry peer/session identifiers and bounded opaque
  payloads; no Quinn connection, UDP socket, or WebRTC raw handle crosses FFI.
- WebRTC signaling uses the authenticated Relay control plane with exactly
  `webrtc_offer`, `webrtc_answer`, `webrtc_ice_candidate`, `webrtc_ice_restart`,
  and `webrtc_close`. Relay validates identity, target, session shape, and
  payload size, but never parses or stores SDP, ICE, media, or file data.
- Signals carry a versioned URL-safe envelope and a monotonic revision. SDP
  revisions reject stale/replayed offers, answers, restarts, and close signals;
  trickled candidates are bound to the active ICE generation and deduplicated.
  Invalid SDP, malformed candidates, and oversized payloads fail before peer
  state is committed.
- The native FFI continues to use the existing protobuf command/event buffer
  ABI. No Flutter/client business code is changed in this Step; the typed Dart
  API and generated/client codec closure belong to Step 10.

## Consequences

WebRTC is now a real native runtime subsystem and remains deliberately outside
the generic TCP/UDP/WebSocket transport abstraction. Relay only carries
signaling; the PeerConnection's sans-I/O network packet/event pump remains
owned by the future native realtime route/socket adapter. Realtime media is not
fed into Delivery/Recovery or file resume.

## Verification

- Native `network-core` tests cover offer/answer, invalid SDP preservation,
  candidate generation and replay handling, ICE restart, stale close, and
  signaling size limits.
- `network-webrtc` tests cover DataChannel, Audio/Video transceivers, SDP/ICE
  validation, and media QoS.
- Native FFI tests round-trip realtime protobuf commands/events without
  exposing raw handles.
- Rust Relay codec, Go Relay integration, and the retained Docker functional
  harness cover all five opaque WebRTC control types.
