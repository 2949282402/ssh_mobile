//! Peer lifecycle, diagnostics, and environment event construction.

use super::{protocol_route_metadata, unix_timestamp_ms};
use crate::connect::PeerState;
use crate::connection::{ConnectionProfile, Route};
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkError as ProtocolError, NetworkEvent, PeerConnectionState,
    PeerStateChangedEvent, RouteTopology as ProtocolRouteTopology,
    RouteTransport as ProtocolRouteTransport, RouteType, NETWORK_PROTOCOL_VERSION,
};

pub(crate) fn emit_peer_diagnostics(
    event_tx: &EventSender,
    diagnostics: network_protocol::PeerDiagnostics,
) {
    let event_id = format!(
        "{}/diagnostics/{}",
        diagnostics.peer_id,
        unix_timestamp_ms()
    );
    let _ = event_tx.send(NetworkEvent {
        event_id,
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerDiagnostics(diagnostics)),
    });
}

pub(crate) fn emit_network_environment_changed(
    event_tx: &EventSender,
    environment: network_protocol::NetworkEnvironmentChangedCommand,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("environment/{}", environment.generation),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::NetworkEnvironmentChanged(
            network_protocol::NetworkEnvironmentChangedEvent {
                generation: environment.generation,
                has_connectivity: environment.has_connectivity,
                is_foreground: environment.is_foreground,
                is_metered: environment.is_metered,
            },
        )),
    });
}

/// 发布带可选安全错误的类型化对端生命周期事件。
pub(crate) fn emit_peer_state(
    event_tx: &EventSender,
    peer_id: &str,
    state: PeerConnectionState,
    route_type: RouteType,
    error: Option<ProtocolError>,
) {
    emit_peer_state_profile(
        event_tx,
        peer_id,
        state,
        Route::from_wire(route_type).map(ConnectionProfile::new),
        error,
    );
}

/// Project the native v2 lifecycle state onto the frozen wire enum. The
/// native owner keeps `Offline/Connecting/Online`; the wire contract retains
/// its historical `Disconnected/Connecting/Connected` values.
pub(crate) fn emit_peer_lifecycle(
    event_tx: &EventSender,
    peer_id: &str,
    state: PeerState,
    error: Option<ProtocolError>,
) {
    let wire_state = match state {
        PeerState::Offline => PeerConnectionState::Disconnected,
        PeerState::Connecting => PeerConnectionState::Connecting,
        PeerState::Online => PeerConnectionState::Connected,
    };
    emit_peer_state(event_tx, peer_id, wire_state, RouteType::Unspecified, error);
}

pub(crate) fn emit_peer_state_profile(
    event_tx: &EventSender,
    peer_id: &str,
    state: PeerConnectionState,
    profile: Option<ConnectionProfile>,
    error: Option<ProtocolError>,
) {
    let route_type = profile
        .and_then(|profile| profile.route().to_wire())
        .unwrap_or(RouteType::Unspecified);
    let (route_topology, route_transport) = profile.map(protocol_route_metadata).unwrap_or((
        ProtocolRouteTopology::Unspecified,
        ProtocolRouteTransport::Unspecified,
    ));
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerState(PeerStateChangedEvent {
            peer_id: peer_id.to_string(),
            state: state as i32,
            route_type: route_type as i32,
            error,
            route_topology: route_topology as i32,
            route_transport: route_transport as i32,
        })),
    });
}
