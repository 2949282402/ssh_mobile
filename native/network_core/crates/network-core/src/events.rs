//! Network Protocol V2 类型化事件构建与命令结果错误映射。

use crate::runtime::EventSender;
use network_protocol::{
    network_event, CommandResult, CommandResultState, NetworkError as ProtocolError,
    NetworkErrorCode, NetworkEvent, PeerConnectionState, PeerPresenceChangedEvent,
    PeerPresenceSnapshotEvent, PeerPresenceState, PeerStateChangedEvent, RealtimeSignalEvent,
    RealtimeSnapshotEvent, RealtimeStateChangedEvent, RelayConnectionState, RetryDisposition,
    RouteTopology as ProtocolRouteTopology, RouteTransport as ProtocolRouteTransport, RouteType,
    SshStreamClosedEvent, SshStreamDataReceivedEvent, StreamHandle, TransferCompletedEvent,
    TransferFailedEvent, TransferProgressEvent, NETWORK_PROTOCOL_VERSION,
};

use crate::connect::PeerState;
use crate::connection::{ConnectionProfile, Route, RouteTopology, RouteTransport};

/// 为活跃传输发布类型化进度事件。
pub(crate) fn emit_transfer_progress(
    event_tx: &EventSender,
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
                peer_id: String::new(),
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

/// 发布一个由 public command tracker 消费的终态结果。
///
/// `NetworkRuntime::send_command` is the synchronous Accepted boundary.  The
/// worker must publish exactly one `CommandResult` V2 event after the async
/// operation settles; the legacy `accepted` boolean event is intentionally not
/// emitted here because the native FFI treats either result variant as the
/// terminal correlation point.
pub(crate) fn emit_command_result(
    event_tx: &EventSender,
    command_id: String,
    command_peer_id: Option<String>,
    result: Result<(), ProtocolError>,
) {
    let (state, error, error_peer_id) = match result {
        Ok(()) => (CommandResultState::Succeeded, None, None),
        Err(error) => {
            let state = match NetworkErrorCode::try_from(error.code).ok() {
                Some(NetworkErrorCode::Cancelled | NetworkErrorCode::StaleOperation) => {
                    CommandResultState::Cancelled
                }
                _ => CommandResultState::Failed,
            };
            let peer_id = (!error.peer_id.is_empty()).then(|| error.peer_id.clone());
            (state, Some(error), peer_id)
        }
    };
    let peer_id = error_peer_id.or(command_peer_id).unwrap_or_default();
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{command_id}/result"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::CommandResultV2(CommandResult {
            command_id,
            peer_id,
            state: state as i32,
            error,
        })),
    });
}

/// Frozen V2 resource defaults. These values are shared by producers and
/// adapters; a lower layer may reject earlier, but may not raise a limit.
#[allow(dead_code)]
pub const NETWORK_V2_MAX_ACTIVE_PEERS: usize = 64;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_CONFIGURED_PEERS: usize = 256;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_ESTABLISHMENTS: usize = 8;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_UNAUTHENTICATED_INBOUND: usize = 32;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_RELAY_DATA_PATHS: usize = 64;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_COMMANDS_PER_PEER: usize = 64;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_STREAMS_PER_PEER: usize = 32;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_ACTIVE_TRANSFERS: usize = 16;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_CONTROL_QUEUE_BYTES: usize = 4 * 1024 * 1024;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_DATA_QUEUE_BYTES: usize = 8 * 1024 * 1024;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_COMMAND_BYTES: usize = 1024 * 1024;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_EVENT_BYTES: usize = 1024 * 1024;
#[allow(dead_code)]
pub const NETWORK_V2_MAX_STREAM_CHUNK_BYTES: usize = 64 * 1024;

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

fn protocol_route_metadata(
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

/// 发布 WebRTC realtime Session 的状态变化，不改变普通 Data Route 的状态。
pub(crate) fn emit_realtime_state(
    event_tx: &EventSender,
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
    event_tx: &EventSender,
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

/// 发布 Realtime Session 稳定后的完整状态快照。该事件在对应的状态 delta 之后
/// 发布，携带 RealtimeManager 中权威的 `session_id`/`peer_id`/`revision`。
pub(crate) fn emit_realtime_snapshot(
    event_tx: &EventSender,
    realtime_id: &str,
    peer_id: &str,
    state: i32,
    revision: u64,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/snapshot/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeSnapshot(
            RealtimeSnapshotEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                state,
                revision,
                error,
            },
        )),
    });
}

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

/// 发布传输最终成功事件。
pub(crate) fn emit_transfer_completed(event_tx: &EventSender, transfer_id: &str, local_path: &str) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/completed"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferCompleted(
            TransferCompletedEvent {
                transfer_id: transfer_id.to_string(),
                local_path: local_path.to_string(),
                peer_id: String::new(),
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

/// 构建不带操作上下文的协议错误。
pub(crate) fn protocol_error(code: NetworkErrorCode, message: impl Into<String>) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: String::new(),
        peer_id: String::new(),
        retry_disposition: RetryDisposition::Unspecified as i32,
        retry_after_seconds: 0,
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
        retry_disposition: RetryDisposition::Unspecified as i32,
        retry_after_seconds: 0,
    }
}

/// 构建带重试策略的协议错误；服务端设备面错误用其覆盖默认的重试行为。
pub(crate) fn protocol_error_with_retry(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: Option<&str>,
    retry_disposition: RetryDisposition,
    retry_after_seconds: u32,
) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: operation.to_string(),
        peer_id: peer_id.unwrap_or_default().to_string(),
        retry_disposition: retry_disposition as i32,
        retry_after_seconds,
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

/// 返回 Network Protocol V2 事件信封使用的当前 Unix 时间戳。
pub(crate) fn unix_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_protocol::network_event;

    #[test]
    fn command_result_emits_one_correlated_success_terminal() {
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let event_sender = EventSender::from(sender);

        emit_command_result(
            &event_sender,
            "connect-a".into(),
            Some("peer-a".into()),
            Ok(()),
        );

        let event = receiver.try_recv().expect("terminal event");
        let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
            panic!("expected CommandResultV2");
        };
        assert_eq!(result.command_id, "connect-a");
        assert_eq!(result.peer_id, "peer-a");
        assert_eq!(result.state, CommandResultState::Succeeded as i32);
        assert!(result.error.is_none());
        assert!(
            receiver.try_recv().is_err(),
            "terminal must be emitted once"
        );
    }

    #[test]
    fn command_result_maps_stale_and_cancelled_errors_to_cancelled() {
        for code in [
            NetworkErrorCode::Cancelled,
            NetworkErrorCode::StaleOperation,
        ] {
            let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
            let event_sender = EventSender::from(sender);
            emit_command_result(
                &event_sender,
                "connect-a".into(),
                Some("peer-a".into()),
                Err(protocol_error_with_peer(
                    code,
                    "cancelled",
                    "connect",
                    "peer-a",
                )),
            );

            let event = receiver.try_recv().expect("terminal event");
            let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
                panic!("expected CommandResultV2");
            };
            assert_eq!(result.state, CommandResultState::Cancelled as i32);
            assert_eq!(result.peer_id, "peer-a");
            assert_eq!(result.error.expect("error").code, code as i32);
            assert!(
                receiver.try_recv().is_err(),
                "terminal must be emitted once"
            );
        }
    }

    #[test]
    fn command_result_maps_other_errors_to_failed_and_uses_command_scope() {
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let event_sender = EventSender::from(sender);
        emit_command_result(
            &event_sender,
            "message-a".into(),
            Some("peer-a".into()),
            Err(protocol_error(NetworkErrorCode::NoRoute, "no route")),
        );

        let event = receiver.try_recv().expect("terminal event");
        let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
            panic!("expected CommandResultV2");
        };
        assert_eq!(result.state, CommandResultState::Failed as i32);
        assert_eq!(result.peer_id, "peer-a");
        assert_eq!(
            result.error.expect("error").code,
            NetworkErrorCode::NoRoute as i32
        );
        assert!(
            receiver.try_recv().is_err(),
            "terminal must be emitted once"
        );
    }
}
