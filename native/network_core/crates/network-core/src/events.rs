//! v1 类型化事件构建与命令结果错误映射。

use network_protocol::{
    network_event, CommandResultEvent, NetworkError as ProtocolError, NetworkErrorCode,
    NetworkEvent, PeerConnectionState, PeerStateChangedEvent, RealtimeSignalEvent,
    RealtimeStateChangedEvent, RelayConnectionState, RouteType, TransferCompletedEvent,
    TransferFailedEvent, TransferProgressEvent, NETWORK_PROTOCOL_VERSION,
};
use tokio::sync::mpsc::UnboundedSender;

/// 为活跃传输发布类型化进度事件。
pub(crate) fn emit_transfer_progress(
    event_tx: &UnboundedSender<NetworkEvent>,
    transfer_id: &str,
    bytes_transferred: u64,
    total_bytes: u64,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/progress/{bytes_transferred}"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferProgress(
            TransferProgressEvent {
                transfer_id: transfer_id.to_string(),
                bytes_transferred,
                total_bytes,
            },
        )),
    });
}

/// 发布由 Dart 服务消费的私有命令确认。
pub(crate) fn emit_command_result(
    event_tx: &UnboundedSender<NetworkEvent>,
    command_id: String,
    result: Result<(), ProtocolError>,
) {
    let (accepted, error) = match result {
        Ok(()) => (true, None),
        Err(error) => (false, Some(error)),
    };
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{command_id}/result"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::CommandResult(CommandResultEvent {
            command_id,
            accepted,
            error,
        })),
    });
}

/// 发布带可选安全错误的类型化对端生命周期事件。
pub(crate) fn emit_peer_state(
    event_tx: &UnboundedSender<NetworkEvent>,
    peer_id: &str,
    state: PeerConnectionState,
    active_route: RouteType,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerState(PeerStateChangedEvent {
            peer_id: peer_id.to_string(),
            state: state as i32,
            active_route: active_route as i32,
            error,
        })),
    });
}

/// 发布 native RouteSelector 完成质量采样或路径迁移后的指标。
pub(crate) fn emit_route_changed(
    event_tx: &UnboundedSender<NetworkEvent>,
    peer_id: &str,
    route_type: RouteType,
    endpoint: std::net::SocketAddr,
    rtt_ms: u32,
    loss_rate: f32,
) {
    let loss_per_mille = (loss_rate.clamp(0.0, 1.0) * 1000.0).round() as u32;
    let timestamp = unix_timestamp_ms();
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
            },
        )),
    });
}

/// 发布 WebRTC realtime Session 的状态变化，不改变普通 Data Route 的状态。
pub(crate) fn emit_realtime_state(
    event_tx: &UnboundedSender<NetworkEvent>,
    realtime_id: &str,
    peer_id: &str,
    state: i32,
    revision: u64,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeState(
            RealtimeStateChangedEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                state,
                revision,
                error,
            },
        )),
    });
}

/// 发布 WebRTC Offer/Answer/ICE 控制面消息，SDP 不进入文件数据面。
pub(crate) fn emit_realtime_signal(
    event_tx: &UnboundedSender<NetworkEvent>,
    realtime_id: &str,
    peer_id: &str,
    kind: i32,
    revision: u64,
    payload: Vec<u8>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/signal/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeSignal(
            RealtimeSignalEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                kind,
                revision,
                payload,
            },
        )),
    });
}

/// 发布带可选安全错误的类型化 Relay 生命周期事件。
pub(crate) fn emit_relay_state(
    event_tx: &UnboundedSender<NetworkEvent>,
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

/// 发布受审批门控的传入传输申请。
pub(crate) fn emit_incoming_offer(
    event_tx: &UnboundedSender<NetworkEvent>,
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

/// 发布传输最终成功事件。
pub(crate) fn emit_transfer_completed(
    event_tx: &UnboundedSender<NetworkEvent>,
    transfer_id: &str,
    local_path: &str,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/completed"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferCompleted(
            TransferCompletedEvent {
                transfer_id: transfer_id.to_string(),
                local_path: local_path.to_string(),
            },
        )),
    });
}

/// 使用稳定上下文字段发布传输最终失败事件。
pub(crate) fn emit_transfer_error(
    event_tx: &UnboundedSender<NetworkEvent>,
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
            },
        )),
    });
}

/// 构建不带操作上下文的协议错误。
pub(crate) fn protocol_error(code: NetworkErrorCode, message: impl Into<String>) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: String::new(),
        peer_id: String::new(),
    }
}

/// 构建带操作和可选对端上下文的协议错误。
pub(crate) fn protocol_error_with_context(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: Option<&str>,
) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: operation.to_string(),
        peer_id: peer_id.unwrap_or_default().to_string(),
    }
}

/// 构建与一个对端操作关联的协议错误。
pub(crate) fn protocol_error_with_peer(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: &str,
) -> ProtocolError {
    protocol_error_with_context(code, message, operation, Some(peer_id))
}

/// 返回 v1 事件信封使用的当前 Unix 时间戳。
pub(crate) fn unix_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
