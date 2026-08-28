//! Relay lifecycle and peer-presence event construction.

use super::unix_timestamp_ms;
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkError as ProtocolError, NetworkEvent, PeerPresenceChangedEvent,
    PeerPresenceSnapshotEvent, PeerPresenceState, RelayConnectionState, NETWORK_PROTOCOL_VERSION,
};

/// 发布带可选安全错误的类型化 Relay 生命周期事件。
pub(crate) fn emit_relay_state(
    event_tx: &EventSender,
    state: RelayConnectionState,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("relay/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RelayStateChanged(
            network_protocol::RelayStateChangedEvent {
                state: state as i32,
                error,
            },
        )),
    });
}

/// 发布单个对端的 Relay Presence 变化。
pub(crate) fn emit_peer_presence_changed(
    event_tx: &EventSender,
    peer_id: &str,
    generation: u64,
    state: PeerPresenceState,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("presence/{peer_id}/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerPresenceChanged(
            PeerPresenceChangedEvent {
                peer_id: peer_id.to_string(),
                generation,
                state: state as i32,
            },
        )),
    });
}

/// 发布 Relay 认证连接后的完整在线设备快照。
pub(crate) fn emit_peer_presence_snapshot(
    event_tx: &EventSender,
    peers: Vec<PeerPresenceChangedEvent>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("presence/snapshot/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerPresenceSnapshot(
            PeerPresenceSnapshotEvent { peers },
        )),
    });
}
