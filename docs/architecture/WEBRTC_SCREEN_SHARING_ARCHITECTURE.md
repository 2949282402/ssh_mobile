Last updated: 2026-09-04

# WebRTC Screen Sharing Architecture

## Status and authority

Status: Accepted architecture for Phase 0 through Phase 7. It freezes the
target boundaries and implementation order; it does not claim that any later
phase is already implemented.

This document accompanies [ADR-034](../adr/ADR-034-screen-share-realtime-media.md).
It extends, rather than changes, the accepted ownership and lifecycle decisions
in ADR-016, ADR-020, ADR-021, ADR-024, ADR-026, and
ADR-BUSINESS-RECOVERY-V2.

When an earlier proposal conflicts with this architecture, this Phase 0
decision controls:

- Screen video is H.264 only through Phase 7. There is no VP8 or AV1 fallback.
- The screen-video transport queue is exactly three frames.
- The implementation order is Rust encoded media, native media bridge, Windows,
  Android, consent/UI, TURN credentials, then QoS hardening.
- No future capability may be described as current until its phase passes the
  stated contract and acceptance checks.

## Purpose

SSH Mobile will support one-to-one, authenticated, real-time screen sharing
between native clients. Screen sharing is a business operation that coordinates
a Realtime session; it is not a new generic transport, a file-transfer mode, or
a Relay media service.

The target chain is:

~~~text
Feature business state and explicit user consent
        |
        v
App Shell capability and RealtimeSession coordination
        |
        +-------------------------------+
        |                               |
        v                               v
Realtime media infrastructure       Network SDK contract
        |                               |
        +---------------+---------------+
                        |
                        v
App-owned NetworkRuntime
        |
        v
Rust RealtimeManager and network-webrtc
        |
        v
WebRTC RTP / DTLS-SRTP
        |
        +-------------------------------+
        |                               |
        v                               v
Direct ICE                         coturn ICE relay
~~~

The control path remains authenticated Relay signaling. RTP and screen pixels
do not traverse the Relay backend.

## Scope and non-goals

The Phase 0 through Phase 7 product scope is:

- one sender and one receiver, both authenticated SSH Mobile peers;
- one H.264 screen-video track in a Realtime session;
- Direct ICE first, TURN fallback, and a relay-only validation path;
- explicit sender action and explicit incoming receiver consent;
- native capture, encode, decode, and GPU rendering on Windows and Android;
- bounded media queues, keyframe recovery, QoS, privacy regression checks, and
  generation-safe recovery.

The following are outside this architecture:

- group calls, SFU, MCU, broadcasting, recording, cloud storage, or media
  transcoding;
- keyboard or mouse control, system audio, camera video, and persistent screen
  content;
- Flutter Web as a transparent substitute for the native Rust runtime;
- macOS and iOS implementation gates before Phase 8 or a separately approved
  platform lifecycle design;
- a Relay backend that receives, stores, decrypts, transcodes, or forwards
  video payloads.

Remote control, browser media, or multi-party media require independent ADRs
and must not be added as a side effect of screen sharing.

## Current baseline versus planned capability

The baseline already has a single App-owned NetworkRuntime and NetworkFacade,
Rust RealtimeManager, native network-webrtc, RealtimeIoDriver, authenticated
Relay signaling, and typed Dart Realtime session coordination. Those are
important prerequisites, not a completed video product.

| Area | Current verified baseline | Planned screen-share capability |
| --- | --- | --- |
| WebRTC owner | network-webrtc owns a sans-I/O peer; RealtimeIoDriver owns that peer and its UDP socket | Keeps the same sole owner; no second peer or runtime |
| Runtime media | The runtime creates a DataChannel and can declare a Video SDP transceiver | Native encoded H.264 RTP ingress and egress |
| QoS | Generic MediaFrame queue; default video policy is four frames and is not wired to RTP | Screen-video queue fixed to three frames with keyframe-aware dropping |
| Dart video shape | A legacy RealtimeVideoFrame Uint8List placeholder exists, but native has no producer | Opaque endpoint and surface contracts; no per-frame Dart media path |
| Capture/rendering | No production platform screen capture, H.264 codec bridge, decoder, or texture chain | Windows and Android native capture, hardware codecs, and native surfaces |
| Consent | Existing signaling has no business intent or user-accept gate | Typed screen-share intent and explicit accept/reject before answer |
| TURN | Runtime configuration may hold development credentials in memory | Authenticated, short-lived, per-session production credentials |
| Recovery | Transport loss terminates Realtime and a new peer is required | Same rule, including invalidation of all media endpoint generations |

In particular, a Video SDP m-line, a generic MediaFrame queue, or a
DataChannel test payload named like a frame is not evidence of H.264 video
transport. No architecture, README, test name, or release note may imply that
the video chain exists until the relevant phase succeeds.

## Layer boundaries

### Feature

The planned feature package owns only business concerns:

- peer and capture-source selection;
- outgoing request, incoming request, accept, reject, cancel, retry, and stop;
- ScreenShareState, user-visible errors, and route-scoped presentation;
- persistent visible sharing status while local capture is active.

Feature code must not create a PeerConnection, parse SDP or ICE, hold a UDP
socket, hold a native pointer, choose RTP payload types, access a TURN
credential, or import another feature implementation. It borrows public
capabilities from the App Shell and releases only its own subscriptions and
operation leases.

ScreenShareState is deliberately separate from RealtimeSessionState. The former
models business states such as preparing, waitingForPeer, incomingRequest,
sharing, viewing, stopping, and failed. The latter remains the native
transport/session lifecycle.

### App Shell and SDK

The App Shell composes Feature, realtime media, network_sdk, network_transport,
and the native binding. It owns correlation between typed command completion,
native Realtime state, consent, and media readiness. It hides signaling,
command IDs, sockets, FFI handles, and native objects from Feature code.

The public SDK remains a low-frequency control boundary. A legacy remote-video
bytes stream cannot become the screen-share hot path. Its producer-less
placeholder contract must be migrated or retired under the compatibility
inventory when the opaque endpoint and rendering contract is introduced.

### Native media infrastructure

A future realtime_media infrastructure package owns platform capture, hardware
H.264 encoder and decoder instances, native bridge lifecycles, GPU surfaces, and
Flutter Texture or equivalent platform rendering. It is not a Feature-owned
platform implementation and it does not own the NetworkRuntime.

### Rust runtime

Rust network-webrtc remains the only PeerConnection owner. RealtimeManager
owns session registration and signaling coordination. RealtimeIoDriver owns
each session's peer, UDP socket, timer loop, and I/O task. The task is
supervised under the Realtime session and closes before the session's native
resources are released.

## Resource ownership and release

| Resource | Owner | Scope | Release rule |
| --- | --- | --- | --- |
| NetworkRuntime and NetworkFacade | AppRuntime | App | App shutdown only |
| RealtimeManager | Rust NetworkRuntime | App/native | Closes sessions before Runtime destruction |
| WebRtcPeer and UDP socket | RealtimeIoDriver | Realtime session | Driver task is cancelled and joined before socket release |
| Realtime media endpoint | Native runtime/media bridge | Realtime session generation | Revoked on detach, close, replacement, or Runtime stop |
| ScreenShareOperation | feature_screen_share | Business operation | Stop, reject, cancel, terminal failure, or route disposal |
| Capture source and encoder | realtime_media platform adapter | Screen-share session | Stop production before encoder/capture release |
| Decoder, GPU surface, and Texture | realtime_media renderer | Viewer session | Detach decoder, then release surface and texture |
| Feature subscriptions and ViewModel | Feature Route scope | Route | Cancel and dispose without closing App resources |

A Feature may stop its own operation, but it may never dispose, stop,
reconfigure, or destroy the App-owned NetworkRuntime, NetworkFacade, native
handle, RealtimeManager, socket, peer, or another operation's endpoint.

Normal stop has this order:

~~~text
Feature stop request
  -> stop producing new screen frames
  -> detach local media ingress
  -> release capture and encoder
  -> request Realtime session stop
  -> wait for correlated native completion and closed state
  -> cancel Realtime subscriptions
  -> detach decoder and release render surface/Texture
  -> dispose route-scoped feature resources
~~~

App shutdown releases borrowers and media adapters before NetworkRuntime and its
native handle. Each release path must be idempotent and must continue its
remaining cleanup after an earlier release failure.

## Control plane and native media data plane

The existing protobuf command/event ABI remains the low-frequency control plane:

- start, stop, state, signaling, consent, command completion, errors, and
  bounded statistics;
- surface-ready, resolution-change, paused, resumed, and endpoint lifecycle
  notifications;
- no encoded or decoded video payload on the event stream.

Screen video requires a separate, narrow native encoded-media data plane:

~~~text
Platform native capture
  -> hardware H.264 encoder
  -> native media bridge
  -> Rust network-webrtc RTP sender

Rust network-webrtc RTP receiver
  -> native media bridge
  -> hardware H.264 decoder
  -> GPU surface
  -> Flutter Texture or equivalent platform surface
~~~

The control plane may create, bind, detach, and release a media endpoint. The
high-frequency data plane may submit or deliver only native-resident encoded
H.264 frames. Its concrete ABI symbols and platform buffer types are deliberately
left to the owning Phase 1 and Phase 2 contracts, but it must obey these
invariants:

- Dart receives only a bounded opaque RealtimeMediaEndpointId, never a pointer,
  socket, peer, codec instance, or native buffer address.
- Every endpoint is bound to runtime generation, realtime ID, peer ID, and
  direction. A prior generation is invalid after stop, transport loss, or
  Runtime replacement.
- Native ingress validates codec, frame length, dimensions, timestamp, and
  monotonic sequence before a queue commit.
- Releasing an endpoint is safe and idempotent. Input after release or against
  a stale generation fails without use-after-free.
- Dart observes state, errors, statistics, and an opaque renderer capability;
  it does not observe one Uint8List per video frame.
- Raw RGBA and YUV frames never cross the Dart main isolate. Encoded H.264
  frames also never use the protobuf event stream as their high-frequency
  transport.

The following routes are forbidden:

~~~text
Screen frame -> Dart bytes -> FFI -> Rust
RTP or video payload -> RelayDataFrame
RTP or video payload -> Delivery, Transfer, or file resume
RTP or video payload -> generic protobuf event stream
Feature -> native pointer, PeerConnection, SDP, ICE, socket, or TURN credential
~~~

## Codec and frame contract

H.264 is the only Screen Video Track codec from Phase 0 through Phase 7. Native
media and network-webrtc negotiate it; Feature code does not parse SDP or select
RTP payload types.

If H.264 cannot be negotiated, the session fails with UnsupportedCodec. If an
encoder or decoder cannot be obtained, the caller receives the appropriate
encoder or decoder availability/failure error. No code may silently fall back to
VP8, AV1, a DataChannel, Dart bytes, or another WebRTC implementation.

The Phase 1 encoded-frame model must carry at least:

| Field | Contract |
| --- | --- |
| codec | H.264 only |
| sequence | Strictly monotonic per endpoint generation |
| timestamp | Validated, bounded, and ordered for the media clock |
| width and height | Bounded dimensions; reconfiguration is explicit |
| keyframe | Used for recovery and congestion policy |
| payload | Native-resident, non-empty, at most 4 MiB |

Frame payloads, SDP, TURN credentials, and complete ICE candidates must never be
logged.

## Consent and signaling

Existing authenticated signaling carries offer, answer, ICE candidate, ICE
restart, and close. Phase 5 adds a typed, bounded business intent through the
protocol source of truth. At minimum it associates:

~~~text
purpose = SCREEN_SHARE
intent_id
peer_id
realtime_id
media = SCREEN_VIDEO
requires_acceptance = true
~~~

The accepted receiving flow is:

~~~text
Incoming screen-share request
  -> feature presents accept and reject
  -> user reject: close/reject without an accepted media session
  -> user accept: validate intent, peer, realtime ID, and generation
  -> only then permit WebRTC answer and negotiation
  -> native ready: attach remote decode/render path
~~~

An incoming Offer may be retained only as bounded provisional signaling state
needed to ask the user. It must not automatically create a final accepted media
session, auto-answer, auto-display a screen, or start local capture. Stale,
duplicate, oversized, unknown, or mismatched intent actions fail closed.

The accepted sending flow is:

~~~text
User explicitly starts sharing
  -> select peer and source, obtain OS permission
  -> create ScreenShareOperation and outgoing intent
  -> receiver explicitly accepts
  -> WebRTC answer, ICE, DTLS-SRTP, and native media endpoint are ready
  -> begin actual capture and H.264 encoding
~~~

The sender must not continuously capture, encode, or queue real screen content
until all three conditions are true: explicit sender action, remote acceptance,
and WebRTC readiness. Sharing UI must visibly state that sharing is active; use
a platform capture indicator or foreground notification where available.

## Media lifecycle, backpressure, and recovery

The screen-video transport queue capacity is exactly three frames. Capture,
encode, decode, and render staging queues also have explicit, small, fixed
bounds in their respective owner contracts. Unlimited VecDeque instances,
unbounded asynchronous channels, and unbounded StreamController instances are
not allowed.

Queue rules are:

1. Reject payloads larger than 4 MiB before queue commit.
2. Drop an already stale frame before it can be sent.
3. Under pressure, drop the oldest non-keyframe first.
4. Preserve the recovery keyframe. If preserving it leaves no safe space, drop
   a new delta frame rather than the only recovery point.
5. On stop, terminal loss, endpoint replacement, or generation mismatch,
   discard all pending video. Never replay historical video after recovery.

A native keyframe request is required after first-track activation, decoder
reset, source or resolution change, ICE restart, unrecoverable packet loss, or
viewer reconnect.

A transport loss is terminal for the affected realtime generation:

~~~text
old RealtimeSession, PeerConnection, ICE, DTLS-SRTP, endpoint, and queues
  -> close and discard

retry
  -> Resolve
  -> new RealtimeSession
  -> new PeerConnection
  -> new signaling
  -> new ICE and DTLS-SRTP
~~~

No caller may reuse a closed PeerConnection, old session ID, old endpoint ID,
old media queue, or late command result. Command correlation and generation
guards discard late events.

## QoS, statistics, and telemetry

The first fixed profile is a maximum of 1920 by 1080, 15 FPS, and about 3 Mbps.
Phase 7 may adapt it using loss, RTT, encoder backlog, and queue pressure:

| Condition | Action |
| --- | --- |
| About three seconds of loss at least 5 percent, RTT at least 250 ms, or queue/encoder pressure | One degradation step: 1080p15 to 1080p10 |
| Continued degradation | Reduce bitrate by 25 percent per bounded step |
| Loss at least 10 percent or RTT at least 400 ms | Move to 720p10 |
| Ten seconds healthy with loss below 2 percent, RTT below 150 ms, and healthy queues | Recover one level only |

Statistics update outside the blocking media hot path. The planned aggregate
fields include capture, encode, sent, decode, and render FPS; resolution;
target and actual bitrate; RTT, jitter, loss; frame and keyframe counters;
codec; and selected ICE path.

Telemetry work follows ADR-033 and its contract source. It may emit outcome,
duration, metric buckets, codec, ICE path, and error category. It may not emit
screen pixels, screenshots, encoded video, SDP, TURN credentials, complete ICE
candidates, remote IPs, window titles, source titles, or any user screen
content.

## Transport, Relay, and TURN

Relay and TURN have separate responsibilities:

~~~text
Relay backend: device authentication, identity/presence, and bounded signaling
coturn: standard ICE relay for encrypted WebRTC packets
~~~

Relay never carries RTP or media payload. It does not store SDP, ICE, intent
history beyond the bounded live operation needed by the owner, or any screen
content. Delivery, Transfer, file resume, and RelayDataFrame remain unrelated
to the video data plane.

Development may retain the existing in-memory runtime TURN configuration.
Phase 6 replaces a production static client credential with a device-authenticated
short-lived TURN REST credential for each Realtime session. The server keeps the
shared secret only in its secret environment; the client retains the issued
credential only in session memory, never exposes it to Feature, and never
persists or logs it.

## Platform rendering and capture

The first platform matrix is:

| Platform | Capture | Codec and rendering | Gate |
| --- | --- | --- | --- |
| Windows | Windows Graphics Capture | Media Foundation H.264 and D3D/GPU surface to Flutter Texture | Phase 3 |
| Android | MediaProjection | MediaCodec H.264 and Surface or SurfaceTexture to Flutter Texture | Phase 4 |
| macOS | Not in Phase 0-7 implementation scope | Requires ScreenCaptureKit and VideoToolbox review | Future |
| iOS | Not in Phase 0-7 implementation scope | Requires ReplayKit lifecycle review | Future |
| Flutter Web | Not a native-runtime substitute | Requires separate browser adapter ADR | Future |

Windows source closure, encoder unavailability, resize, double start, and
release ordering need deterministic fake-platform tests before device testing.
Android must use the system MediaProjection prompt, correctly typed foreground
service, and revocation callback. Projection revoke, surface destruction,
rotation, background behavior, and permission denial fail closed and stop
production immediately.

The renderer uses a native decoder and GPU surface. A Flutter widget observes an
opaque surface and low-frequency state; it must not rebuild from raw frame bytes
on every frame.

## Delivery plan and phase gates

| Phase | Deliverable | May not do |
| --- | --- | --- |
| 0 | This architecture, ADR-034, and Memory Map routing | Product code, protocol, UI, or platform changes |
| 1 | Rust encoded H.264 ingress/egress, RTP loopback, 3-frame queue, keyframe and TURN video tests | Dart API, UI, capture, or second peer |
| 2 | Native media bridge and realtime_media public lifecycle contract with opaque endpoint | Real Windows/Android capture |
| 3 | Windows capture, hardware codec, native decode/render, and Windows-to-Windows E2E | Android capture or feature UI |
| 4 | Android MediaProjection, MediaCodec, rendering, and cross-platform E2E | Screen-share business entry before consent layer |
| 5 | Typed consent protocol and feature_screen_share UI/operation | Feature-to-Feature dependency or auto-accept |
| 6 | Authenticated short-lived TURN credential and relay-only screen-share E2E | Static production credential in a Feature |
| 7 | Adaptive QoS, telemetry, privacy regression, CI gates, and stability evidence | Unbounded queues or content telemetry |

Each phase starts from the approved prior phase, uses its own branch and review
scope, and follows Red, Green, Refactor for observable behavior. Phase 0 is the
documentation exception. New protocol fields are authored in the source schema,
then generated through the repository process; generated output alone is never
the source of a contract change.

## Acceptance and hard stops

Phase 0 accepts only when:

- this Architecture and ADR-034 agree on ownership, H.264-only policy, media
  boundary, consent, recovery, queue capacity, privacy, and phase ordering;
- current state and future commitments are visibly distinguished;
- no existing Accepted ADR is altered;
- the Memory Map routes future screen-share work to the necessary Client, SDK,
  transport, ownership, and ADR context;
- documentation checks and git diff validation pass.

Before Phase 1 proceeds, the team must prove that the selected rtc integration
can send and receive application-provided encoded H.264 access units through
the existing sole PeerConnection and RealtimeIoDriver. It must not assume that a
Video SDP transceiver is a frame API.

Stop and return to architecture review if any of these conditions holds:

- rtc cannot expose a safe H.264 RTP ingress/egress path under the existing
  native PeerConnection owner;
- high-frequency media can proceed only by passing Dart bytes;
- implementation needs another PeerConnection, another runtime, or Relay media;
- platform bridging cannot bind safely to runtime generation;
- a Feature would need a raw native pointer;
- recovery would reuse a closed PeerConnection.

A stop report must identify the concrete code evidence, the ADR-034 conflict,
at least two architecture-safe alternatives, a recommendation, and the ADR
change required before implementation resumes.

## References

- [ADR-034](../adr/ADR-034-screen-share-realtime-media.md)
- [ADR-016](../adr/ADR-016-webrtc-media-qos.md)
- [ADR-020](../adr/ADR-020-webrtc-runtime.md)
- [ADR-021](../adr/ADR-021-native-dart-realtime-api.md)
- [ADR-024](../adr/ADR-024-webrtc-data-plane.md)
- [ADR-026](../adr/ADR-026-realtime-command-completion-correlation.md)
- [ADR-BUSINESS-RECOVERY-V2](../adr/ADR-BUSINESS-RECOVERY-V2.md)
- [Module Dependency](MODULE_DEPENDENCY.md)
- [Resource Ownership](RESOURCE_OWNERSHIP.md)
