//! Runtime-owned WebRTC network I/O.
//!
//! `rtc` is deliberately sans-I/O.  This module is the sole adapter that
//! binds a UDP socket, forwards datagrams into the peer, drives timers, and
//! exposes data-channel events to the owning runtime.  It keeps socket and
//! peer ownership together so a cancelled runtime task drops both resources.

use crate::{IceCandidate, WebRtcError, WebRtcPeer};
use bytes::BytesMut;
use rtc::data_channel::RTCDataChannelId;
use rtc::peer_connection::event::{RTCDataChannelEvent, RTCPeerConnectionEvent};
use rtc::peer_connection::message::RTCMessage;
use rtc::peer_connection::state::{RTCIceConnectionState, RTCPeerConnectionState};
use rtc::shared::{TaggedBytesMut, TransportContext, TransportProtocol};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::mpsc::Sender;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_UDP_DATAGRAM_BYTES: usize = 64 * 1024;
const HOST_CANDIDATE_PRIORITY: u32 = 2_130_706_431;
pub const REALTIME_IO_EVENT_CAPACITY: usize = 256;

/// Events emitted by the real-time I/O loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RealtimeIoEvent {
    /// The ICE connectivity check reached a usable state.
    IceConnected,
    /// ICE failed and no candidate pair is usable.
    IceFailed,
    /// The DTLS/SCTP peer connection is ready.
    PeerConnected,
    /// The DTLS/SCTP peer connection was disconnected.
    PeerDisconnected,
    /// The DTLS/SCTP peer connection failed permanently.
    PeerFailed,
    /// A data channel became writable.
    DataChannelOpened(RTCDataChannelId),
    /// A data channel closed.
    DataChannelClosed(RTCDataChannelId),
    /// A candidate discovered by STUN/TURN that must be sent through the
    /// existing signaling channel.
    LocalIceCandidate(IceCandidate),
    /// An application data-channel message.
    DataChannelMessage {
        channel_id: RTCDataChannelId,
        is_string: bool,
        payload: Vec<u8>,
    },
}

/// A WebRTC peer plus the UDP socket that carries its ICE/DTLS/SRTP/SCTP
/// packets.  The peer is never driven without this owner.
pub struct RealtimeIoDriver {
    peer: WebRtcPeer,
    socket: Arc<UdpSocket>,
    local_addr: SocketAddr,
}

/// Shared owner handle used by Runtime signal handling and the I/O task.  The
/// lock is held only while calling synchronous sans-I/O methods; no await is
/// performed while it is held.
pub type RealtimeIoDriverHandle = Arc<Mutex<RealtimeIoDriver>>;

impl RealtimeIoDriver {
    /// Bind a UDP socket and register its host candidate before SDP creation.
    /// A concrete bind address is recommended for deterministic candidate
    /// advertisement; unspecified binds advertise loopback as a safe local
    /// fallback and can be overridden with [`Self::bind_with_advertised_ip`].
    pub async fn bind(peer: WebRtcPeer, bind_addr: SocketAddr) -> Result<Self, WebRtcError> {
        Self::bind_with_advertised_ip(peer, bind_addr, None).await
    }

    /// Bind a UDP socket and advertise an explicit host IP in its ICE
    /// candidate.  This is used by the Runtime when the socket binds to
    /// `0.0.0.0` or `::` for LAN reachability.
    pub async fn bind_with_advertised_ip(
        mut peer: WebRtcPeer,
        bind_addr: SocketAddr,
        advertised_ip: Option<IpAddr>,
    ) -> Result<Self, WebRtcError> {
        let socket = UdpSocket::bind(bind_addr)
            .await
            .map_err(|error| WebRtcError::Io(error.to_string()))?;
        let local_addr = socket
            .local_addr()
            .map_err(|error| WebRtcError::Io(error.to_string()))?;
        let candidate_ip = advertised_ip
            .or_else(|| (!local_addr.ip().is_unspecified()).then_some(local_addr.ip()))
            .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
        let candidate = host_candidate(candidate_ip, local_addr.port());
        peer.add_local_ice_candidate(IceCandidate::new(
            candidate,
            Some("0".to_owned()),
            Some(0),
            None,
        )?)?;
        Ok(Self {
            peer,
            socket: Arc::new(socket),
            local_addr,
        })
    }

    /// Convert this driver into the shared owner used by the runtime task.
    pub fn into_handle(self) -> RealtimeIoDriverHandle {
        Arc::new(Mutex::new(self))
    }

    /// Address of the bound UDP socket.
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Access the peer for SDP negotiation or an application send operation.
    /// Callers must not hold the returned borrow across an await.
    pub fn peer_mut(&mut self) -> &mut WebRtcPeer {
        &mut self.peer
    }

    /// Close the peer while retaining the driver owner for deterministic
    /// shutdown tests.
    pub fn close(&mut self) -> Result<(), WebRtcError> {
        self.peer.close()
    }

    fn socket(&self) -> Arc<UdpSocket> {
        Arc::clone(&self.socket)
    }

    fn local_addr_value(&self) -> SocketAddr {
        self.local_addr
    }
}

/// Drive one WebRTC peer until the task is cancelled, its event receiver is
/// closed, or the peer reports a fatal I/O error.
pub async fn run_realtime_io(
    handle: RealtimeIoDriverHandle,
    events: Sender<RealtimeIoEvent>,
) -> Result<(), WebRtcError> {
    let mut receive_buffer = vec![0u8; MAX_UDP_DATAGRAM_BYTES];
    loop {
        let (socket, local_addr, outbound, timeout, pending_events) = {
            let mut driver = lock_driver(&handle)?;
            let socket = driver.socket();
            let local_addr = driver.local_addr_value();
            let mut outbound = Vec::new();
            while let Some(packet) = driver.peer.poll_network_packet() {
                if packet.transport.transport_protocol != TransportProtocol::UDP {
                    return Err(WebRtcError::Io(
                        "WebRTC driver received a non-UDP packet from rtc".to_owned(),
                    ));
                }
                outbound.push((packet.transport.peer_addr, packet.message.to_vec()));
            }
            let mut pending_events = Vec::new();
            while let Some(event) = driver.peer.poll_event() {
                pending_events.extend(map_peer_event(event)?);
            }
            while let Some(message) = driver.peer.poll_message() {
                if let RTCMessage::DataChannelMessage(channel_id, message) = message {
                    pending_events.push(RealtimeIoEvent::DataChannelMessage {
                        channel_id,
                        is_string: message.is_string,
                        payload: message.data.to_vec(),
                    });
                }
            }
            let timeout = driver.peer.poll_timeout();
            (socket, local_addr, outbound, timeout, pending_events)
        };

        for (peer_addr, payload) in outbound {
            socket
                .send_to(&payload, peer_addr)
                .await
                .map_err(|error| WebRtcError::Io(error.to_string()))?;
        }
        for event in pending_events {
            if events.send(event).await.is_err() {
                return Ok(());
            }
        }

        let deadline = timeout.unwrap_or_else(|| Instant::now() + DEFAULT_TIMEOUT);
        let delay = deadline.saturating_duration_since(Instant::now());
        if delay.is_zero() {
            handle_timeout(&handle, Instant::now())?;
            continue;
        }

        let timer = tokio::time::sleep(delay);
        tokio::pin!(timer);
        tokio::select! {
            _ = &mut timer => {
                handle_timeout(&handle, Instant::now())?;
            }
            result = socket.recv_from(&mut receive_buffer) => {
                let (bytes_read, peer_addr) = result
                    .map_err(|error| WebRtcError::Io(error.to_string()))?;
                let packet = TaggedBytesMut {
                    now: Instant::now(),
                    transport: TransportContext {
                        local_addr,
                        peer_addr,
                        ecn: None,
                        transport_protocol: TransportProtocol::UDP,
                    },
                    message: BytesMut::from(&receive_buffer[..bytes_read]),
                };
                let mut driver = lock_driver(&handle)?;
                driver.peer.handle_network_packet(packet)?;
            }
        }
    }
}

fn lock_driver(
    handle: &RealtimeIoDriverHandle,
) -> Result<MutexGuard<'_, RealtimeIoDriver>, WebRtcError> {
    handle
        .lock()
        .map_err(|_| WebRtcError::Io("WebRTC I/O driver mutex was poisoned".to_owned()))
}

fn handle_timeout(handle: &RealtimeIoDriverHandle, now: Instant) -> Result<(), WebRtcError> {
    let mut driver = lock_driver(handle)?;
    driver.peer.handle_timeout(now)
}

fn map_peer_event(event: RTCPeerConnectionEvent) -> Result<Vec<RealtimeIoEvent>, WebRtcError> {
    let mut mapped = Vec::new();
    match event {
        RTCPeerConnectionEvent::OnIceCandidateEvent(event) => {
            let candidate = event.candidate.to_json().map_err(|error| {
                WebRtcError::Rtc(format!("failed to serialize local ICE candidate: {error}"))
            })?;
            mapped.push(RealtimeIoEvent::LocalIceCandidate(IceCandidate::new(
                candidate.candidate,
                candidate.sdp_mid,
                candidate.sdp_mline_index,
                candidate.username_fragment,
            )?));
        }
        RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(state) => match state {
            RTCIceConnectionState::Connected | RTCIceConnectionState::Completed => {
                mapped.push(RealtimeIoEvent::IceConnected)
            }
            RTCIceConnectionState::Failed => mapped.push(RealtimeIoEvent::IceFailed),
            _ => {}
        },
        RTCPeerConnectionEvent::OnConnectionStateChangeEvent(state) => match state {
            RTCPeerConnectionState::Connected => mapped.push(RealtimeIoEvent::PeerConnected),
            RTCPeerConnectionState::Disconnected | RTCPeerConnectionState::Closed => {
                mapped.push(RealtimeIoEvent::PeerDisconnected)
            }
            RTCPeerConnectionState::Failed => mapped.push(RealtimeIoEvent::PeerFailed),
            _ => {}
        },
        RTCPeerConnectionEvent::OnDataChannel(event) => match event {
            RTCDataChannelEvent::OnOpen(channel_id) => {
                mapped.push(RealtimeIoEvent::DataChannelOpened(channel_id))
            }
            RTCDataChannelEvent::OnClose(channel_id) => {
                mapped.push(RealtimeIoEvent::DataChannelClosed(channel_id))
            }
            _ => {}
        },
        _ => {}
    }
    Ok(mapped)
}

fn host_candidate(ip: IpAddr, port: u16) -> String {
    format!("candidate:1 1 udp {HOST_CANDIDATE_PRIORITY} {ip} {port} typ host")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DataChannelReliability, IceServerConfig, WebRtcConfig};
    use std::time::Duration;
    use tokio::sync::mpsc::channel;

    #[tokio::test]
    async fn two_local_drivers_exchange_data_channel_payloads() {
        let caller = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("caller driver");
        let responder = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("responder driver");

        let caller = Arc::new(Mutex::new(caller));
        let responder = Arc::new(Mutex::new(responder));
        let channel_id = caller
            .lock()
            .unwrap()
            .peer_mut()
            .create_data_channel("local-e2e", DataChannelReliability::default())
            .expect("data channel");
        let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
        let answer = {
            let mut responder_driver = responder.lock().unwrap();
            responder_driver
                .peer_mut()
                .accept_remote_offer(offer)
                .unwrap();
            responder_driver.peer_mut().create_answer().unwrap()
        };
        caller
            .lock()
            .unwrap()
            .peer_mut()
            .accept_remote_answer(answer)
            .unwrap();

        let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
        let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
        let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
        let responder_task =
            tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

        let mut caller_open = false;
        let mut responder_open = false;
        let open_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !(caller_open && responder_open) {
            tokio::select! {
                Some(event) = caller_events_rx.recv() => {
                    caller_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                    assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
                }
                Some(event) = responder_events_rx.recv() => {
                    responder_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                    assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
                }
                _ = tokio::time::sleep_until(open_deadline) => panic!("data channel did not open"),
            }
        }

        caller
            .lock()
            .unwrap()
            .peer_mut()
            .send_data(channel_id, b"encoded-frame")
            .unwrap();
        let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let payload = loop {
            tokio::select! {
                Some(event) = responder_events_rx.recv() => {
                    if let RealtimeIoEvent::DataChannelMessage { payload, .. } = event {
                        break payload;
                    }
                }
                _ = tokio::time::sleep_until(payload_deadline) => panic!("data channel payload not received"),
            }
        };
        assert_eq!(payload, b"encoded-frame");

        caller_task.abort();
        responder_task.abort();
        let _ = caller_task.await;
        let _ = responder_task.await;
    }

    #[tokio::test]
    #[ignore = "requires a local coturn server at 127.0.0.1:3478"]
    async fn relay_only_drivers_exchange_data_channel_payloads() {
        let config = WebRtcConfig {
            ice_servers: vec![IceServerConfig::turn(
                "turn:127.0.0.1:3478?transport=udp",
                "test",
                "test",
            )],
            relay_only: true,
            ..Default::default()
        };
        let caller = RealtimeIoDriver::bind(
            WebRtcPeer::new(config.clone()).expect("caller peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("caller driver");
        let responder = RealtimeIoDriver::bind(
            WebRtcPeer::new(config).expect("responder peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("responder driver");

        let caller = Arc::new(Mutex::new(caller));
        let responder = Arc::new(Mutex::new(responder));
        let channel_id = caller
            .lock()
            .unwrap()
            .peer_mut()
            .create_data_channel("relay-e2e", DataChannelReliability::default())
            .expect("data channel");
        let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
        let answer = {
            let mut responder_driver = responder.lock().unwrap();
            responder_driver
                .peer_mut()
                .accept_remote_offer(offer)
                .unwrap();
            responder_driver.peer_mut().create_answer().unwrap()
        };
        caller
            .lock()
            .unwrap()
            .peer_mut()
            .accept_remote_answer(answer)
            .unwrap();

        let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
        let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
        let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
        let responder_task =
            tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

        let mut caller_open = false;
        let mut responder_open = false;
        let open_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while !(caller_open && responder_open) {
            tokio::select! {
                Some(event) = caller_events_rx.recv() => {
                    match event {
                        RealtimeIoEvent::LocalIceCandidate(candidate) => {
                            responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                        }
                        RealtimeIoEvent::DataChannelOpened(_) => caller_open = true,
                        RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("caller relay ICE failed"),
                        _ => {}
                    }
                }
                Some(event) = responder_events_rx.recv() => {
                    match event {
                        RealtimeIoEvent::LocalIceCandidate(candidate) => {
                            caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                        }
                        RealtimeIoEvent::DataChannelOpened(_) => responder_open = true,
                        RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("responder relay ICE failed"),
                        _ => {}
                    }
                }
                _ = tokio::time::sleep_until(open_deadline) => panic!("TURN data channel did not open"),
            }
        }

        caller
            .lock()
            .unwrap()
            .peer_mut()
            .send_data(channel_id, b"turn-relay-frame")
            .unwrap();
        let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let payload = loop {
            tokio::select! {
                Some(event) = caller_events_rx.recv() => {
                    if let RealtimeIoEvent::LocalIceCandidate(candidate) = event {
                        responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                }
                Some(event) = responder_events_rx.recv() => {
                    match event {
                        RealtimeIoEvent::LocalIceCandidate(candidate) => {
                            caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                        }
                        RealtimeIoEvent::DataChannelMessage { payload, .. } => break payload,
                        _ => {}
                    }
                }
                _ = tokio::time::sleep_until(payload_deadline) => panic!("TURN data channel payload not received"),
            }
        };
        assert_eq!(payload, b"turn-relay-frame");

        caller_task.abort();
        responder_task.abort();
        let _ = caller_task.await;
        let _ = responder_task.await;
    }
}
