//! Transfer progress, offer, completion, and failure event construction.

use super::{protocol_error_with_context, unix_timestamp_ms};
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkErrorCode, NetworkEvent, RouteType, TransferCompletedEvent,
    TransferFailedEvent, TransferProgressEvent, NETWORK_PROTOCOL_VERSION,
};

/// 为活跃传输发布类型化进度事件（NetworkEvent tag 11）。
pub(crate) fn emit_transfer_progress(
    event_tx: &EventSender,
    peer_id: &str,
    transfer_id: &str,
    bytes_transferred: u64,
    total_bytes: u64,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/{transfer_id}/progress/{bytes_transferred}"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferProgress(
            TransferProgressEvent {
                transfer_id: transfer_id.to_string(),
                bytes_transferred,
                total_bytes,
                peer_id: peer_id.to_string(),
            },
        )),
    });
}

pub(crate) fn emit_transfer_progress_for_peer(
    event_tx: &EventSender,
    peer_id: &str,
    transfer_id: &str,
    confirmed_offset: u64,
    total_bytes: u64,
    paused: bool,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/{transfer_id}/progress/{confirmed_offset}"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerTransferProgress(
            network_protocol::PeerTransferProgressEvent {
                peer_id: peer_id.to_string(),
                transfer_id: transfer_id.to_string(),
                confirmed_offset,
                total_bytes,
                paused,
            },
        )),
    });
}

/// 发布受审批门控的传入传输申请。
pub(crate) fn emit_incoming_offer(
    event_tx: &EventSender,
    peer_id: &str,
    manifest: &network_transfer::FileManifest,
    route_type: RouteType,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{}/offer", manifest.transfer_id),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::IncomingTransferOffer(
            network_protocol::IncomingTransferOfferEvent {
                transfer_id: manifest.transfer_id.clone(),
                peer_id: peer_id.to_string(),
                file_name: manifest.file_name.clone(),
                file_size: manifest.file_size,
                route_type: Some(route_type as i32),
            },
        )),
    });
}

/// 发布传输最终成功事件（NetworkEvent tag 15）。
pub(crate) fn emit_transfer_completed(
    event_tx: &EventSender,
    peer_id: &str,
    transfer_id: &str,
    local_path: &str,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/{transfer_id}/completed"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferCompleted(
            TransferCompletedEvent {
                transfer_id: transfer_id.to_string(),
                local_path: local_path.to_string(),
                peer_id: peer_id.to_string(),
            },
        )),
    });
}

/// 使用稳定上下文字段发布传输最终失败事件。
pub(crate) fn emit_transfer_error(
    event_tx: &EventSender,
    transfer_id: &str,
    code: NetworkErrorCode,
    message: String,
    operation: &str,
    peer_id: Option<&str>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/failed"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferFailed(
            TransferFailedEvent {
                transfer_id: transfer_id.to_string(),
                error: Some(protocol_error_with_context(
                    code, message, operation, peer_id,
                )),
                peer_id: peer_id.unwrap_or_default().to_string(),
            },
        )),
    });
}
