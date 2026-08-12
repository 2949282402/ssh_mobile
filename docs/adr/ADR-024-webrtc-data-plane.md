最新更新时间：2026-08-12

# ADR-024：WebRTC Realtime Data Plane I/O Driver

## 状态

Accepted for the native network v1 development line.

## 背景

`rtc 0.9.1` exposes a sans-I/O PeerConnection. The earlier Realtime runtime
could create SDP and forward signaling, but it did not bind a UDP socket or
drive the packet, event, and timer queues. That made a successful Offer/Answer
look like a connected realtime route without proving that DTLS/SCTP/DataChannel
traffic could traverse the network.

## 决策

- `network-webrtc::RealtimeIoDriver` owns one `WebRtcPeer` and one UDP socket.
  It drains `poll_network_packet`, forwards UDP datagrams to
  `handle_network_packet`, drains `poll_event` and `poll_message`, and runs
  `poll_timeout`/`handle_timeout` in one bounded Tokio loop.
- The driver registers a socket host candidate before SDP creation. Later
  STUN/TURN candidates become typed driver events and are sent through the
  existing authenticated Relay signaling envelope; Relay never carries the
  WebRTC media/data packets.
- `network-core::RealtimeManager` creates the driver for both locally started
  and remotely received Offers. Each loop is registered with
  `RuntimeTaskSupervisor` under `realtime:<realtime_id>` and is cancelled before
  a session owner closes the peer.
- `WebRtcConfig::relay_only` maps to rtc's relay ICE policy. Runtime TURN
  credentials are read only from the native runtime configuration environment
  (`SSH_MOBILE_TURN_SERVERS`/`SSH_MOBILE_TURN_URL`, username, credential) and
  remain outside protobuf events and logs.
- The public Dart Realtime API remains signaling/state-only in this Step. A
  later Flutter integration may expose application data/events, but it must not
  own or drive the socket, ICE, SDP, or PeerConnection.

## 验证

- Native localhost driver test: two real UDP sockets complete ICE, DTLS/SCTP,
  open a DataChannel, and exchange an application payload.
- `network-core` supervisor test: two driver tasks are registered in separate
  realtime Session groups, exchange a payload, and are cancelled through the
  supervisor.
- Coturn-backed relay-only test: host/direct candidates are disabled, both
  peers gather TURN candidates, and the DataChannel payload is delivered over
  the relay.
- Cargo format, workspace tests, and Clippy remain required; the CI native job
  starts a pinned coturn image and runs the ignored relay-only test explicitly.
