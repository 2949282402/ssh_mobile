//! ReliableStream event construction.

use super::unix_timestamp_ms;
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkEvent, SshStreamClosedEvent, SshStreamDataReceivedEvent, StreamHandle,
    NETWORK_PROTOCOL_VERSION,
};

/// 发布 ReliableStream 收到的对端字节（设计 §17）。
pub(crate) fn emit_stream_data_received(
    event_tx: &EventSender,
    peer_id: &str,
    opener_device_id: &str,
    stream_id: u16,
    data: &[u8],
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!(
            "{peer_id}/stream/{opener_device_id}/{stream_id}/data/{}",
            unix_timestamp_ms()
        ),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamDataReceived(
            SshStreamDataReceivedEvent {
                peer_id: peer_id.to_string(),
                handle: Some(StreamHandle {
                    opener_device_id: opener_device_id.to_string(),
                    stream_id: stream_id as u32,
                }),
                data: data.to_vec(),
            },
        )),
    });
}

/// 发布 ReliableStream 关闭事件。
pub(crate) fn emit_stream_closed(
    event_tx: &EventSender,
    peer_id: &str,
    opener_device_id: &str,
    stream_id: u16,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!(
            "{peer_id}/stream/{opener_device_id}/{stream_id}/closed/{}",
            unix_timestamp_ms()
        ),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamClosed(
            SshStreamClosedEvent {
                peer_id: peer_id.to_string(),
                handle: Some(StreamHandle {
                    opener_device_id: opener_device_id.to_string(),
                    stream_id: stream_id as u32,
                }),
            },
        )),
    });
}
