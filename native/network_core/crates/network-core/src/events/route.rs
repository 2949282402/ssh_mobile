//! Direct/Relay route observation event construction.

use super::unix_timestamp_ms;
use crate::connection::{ConnectionProfile, Route, RouteTopology, RouteTransport};
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkError as ProtocolError, NetworkEvent, RouteAttemptPhase,
    RouteTopology as ProtocolRouteTopology, RouteTransport as ProtocolRouteTransport, RouteType,
    NETWORK_PROTOCOL_VERSION,
};

/// 发布 native RouteSelector 完成质量采样或路径迁移后的指标。
pub(crate) fn emit_route_changed(
    event_tx: &EventSender,
    peer_id: &str,
    route_type: RouteType,
    endpoint: std::net::SocketAddr,
    rtt_ms: u32,
    loss_rate: f32,
) {
    emit_route_changed_profile(
        event_tx,
        peer_id,
        Route::from_wire(route_type).map(ConnectionProfile::new),
        endpoint,
        rtt_ms,
        loss_rate,
    );
}

pub(crate) fn emit_route_changed_profile(
    event_tx: &EventSender,
    peer_id: &str,
    profile: Option<ConnectionProfile>,
    endpoint: std::net::SocketAddr,
    rtt_ms: u32,
    loss_rate: f32,
) {
    let loss_per_mille = (loss_rate.clamp(0.0, 1.0) * 1000.0).round() as u32;
    let timestamp = unix_timestamp_ms();
    let route_type = profile
        .and_then(|profile| profile.route().to_wire())
        .unwrap_or(RouteType::Unspecified);
    let (topology, transport) = profile.map(protocol_route_metadata).unwrap_or((
        ProtocolRouteTopology::Unspecified,
        ProtocolRouteTransport::Unspecified,
    ));
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/route/{timestamp}"),
        timestamp_ms: timestamp,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RouteChanged(
            network_protocol::RouteChangedEvent {
                peer_id: peer_id.to_string(),
                route_type: route_type as i32,
                endpoint: endpoint.to_string(),
                rtt_ms: rtt_ms as u64,
                loss_per_mille,
                topology: topology as i32,
                transport: transport as i32,
            },
        )),
    });
}

/// Publish the causal phases of one native direct/Relay attempt. Unlike the
/// terminal PeerState event, these observations let consumers distinguish an
/// actual fallback from a direct failure that had no Relay retry.
pub(crate) fn emit_route_attempt_changed(
    event_tx: &EventSender,
    peer_id: &str,
    attempt_id: &str,
    command_id: &str,
    phase: RouteAttemptPhase,
    route_type: RouteType,
    error: Option<ProtocolError>,
) {
    let timestamp = unix_timestamp_ms();
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/route-attempt/{attempt_id}/{phase:?}/{timestamp}"),
        timestamp_ms: timestamp,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RouteAttemptChanged(
            network_protocol::RouteAttemptChangedEvent {
                peer_id: peer_id.to_string(),
                attempt_id: attempt_id.to_string(),
                phase: phase as i32,
                route_type: route_type as i32,
                error,
                command_id: command_id.to_string(),
            },
        )),
    });
}

pub(crate) fn protocol_route_metadata(
    profile: ConnectionProfile,
) -> (ProtocolRouteTopology, ProtocolRouteTransport) {
    let topology = match profile.topology() {
        RouteTopology::Direct => ProtocolRouteTopology::Direct,
        RouteTopology::Relay => ProtocolRouteTopology::Relay,
    };
    let transport = match profile.transport() {
        RouteTransport::Quic => ProtocolRouteTransport::Quic,
        RouteTransport::Tcp => ProtocolRouteTransport::Tcp,
        RouteTransport::Udp => ProtocolRouteTransport::Udp,
        RouteTransport::WebSocket => ProtocolRouteTransport::WebSocket,
    };
    (topology, transport)
}
