//! v1 运行时的命令校验、确认与任务分发。

use std::sync::Arc;

use network_protocol::{
    network_command, CommunicationClass, NetworkCommand, NetworkError as ProtocolError,
    NetworkErrorCode, PeerConnectionState, RelayConnectionState, RouteType,
    NETWORK_PROTOCOL_VERSION,
};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::events::{
    emit_command_result, emit_peer_state, emit_relay_state, protocol_error,
    protocol_error_with_peer,
};
use crate::peer;
use crate::relay;
use crate::runtime::RuntimeState;
use crate::transfer;

/// 运行唯一命令 worker，并为每个命令发布一个内部结果。
pub(crate) async fn run_command_worker(
    mut commands: UnboundedReceiver<NetworkCommand>,
    state: Arc<RuntimeState>,
) {
    tracing::info!("Network runtime worker started");
    while let Some(command) = commands.recv().await {
        let command_id = command.command_id.clone();
        let result = dispatch_command(command, Arc::clone(&state)).await;
        emit_command_result(&state.event_tx, command_id, result);
    }
    tracing::info!("Network runtime worker shut down");
}

/// 校验 v1 信封，并将载荷路由到所属子系统。
pub(crate) async fn dispatch_command(
    command: NetworkCommand,
    state: Arc<RuntimeState>,
) -> Result<(), ProtocolError> {
    if command.protocol_version != NETWORK_PROTOCOL_VERSION {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            format!(
                "unsupported network protocol version {}",
                command.protocol_version
            ),
        ));
    }
    if command.command_id.is_empty() || command.command_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "command_id must contain 1-128 characters",
        ));
    }
    match command.payload {
        Some(network_command::Payload::ConfigureRuntime(config)) => {
            peer::configure_runtime(state, config).await
        }
        Some(network_command::Payload::UpsertPeer(peer_command)) => {
            peer::upsert_peer(&state, peer_command).await
        }
        Some(network_command::Payload::ConnectPeer(connect)) => {
            let class = decode_communication_class(connect.communication_class);
            start_connect_peer(state, connect.peer_id, class).await
        }
        Some(network_command::Payload::SendFile(_))
        | Some(network_command::Payload::CancelTransfer(_))
        | Some(network_command::Payload::RespondIncomingTransfer(_)) => {
            transfer::dispatch_transfer_command(state, command).await
        }
        Some(network_command::Payload::SendMessage(message)) => {
            crate::channel::start_send_message(state, message).await
        }
        Some(network_command::Payload::AcknowledgeMessage(ack)) => {
            crate::channel::acknowledge_message(&state, ack).await
        }
        Some(network_command::Payload::StartRealtimeSession(start)) => {
            crate::realtime::start_session(state, start).await
        }
        Some(network_command::Payload::StopRealtimeSession(stop)) => {
            crate::realtime::stop_session(&state, stop).await
        }
        Some(network_command::Payload::SendRealtimeSignal(signal)) => {
            crate::realtime::send_signal_command(&state, signal).await
        }
        Some(network_command::Payload::ConfigureRelay(config)) => {
            start_configure_relay(state, config).await
        }
        Some(network_command::Payload::UploadDiscovery(upload)) => {
            start_upload_discovery(state, upload).await
        }
        Some(network_command::Payload::DisconnectPeer(disconnect)) => {
            peer::disconnect_peer(&state, disconnect.peer_id).await
        }
        Some(network_command::Payload::DisconnectRelay(_)) => relay::disconnect_relay(&state).await,
        Some(network_command::Payload::SshStreamOpen(open)) => {
            crate::stream::handle_ssh_stream_open(state, open).await
        }
        Some(network_command::Payload::SshStreamData(data)) => {
            crate::stream::handle_ssh_stream_data(state, data).await
        }
        Some(network_command::Payload::SshStreamClose(close)) => {
            crate::stream::handle_ssh_stream_close(state, close).await
        }
        None => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "network command payload is required",
        )),
    }
}

/// 接受对端连接请求，并分离握手任务。
async fn start_connect_peer(
    state: Arc<RuntimeState>,
    peer_id: String,
    class: CommunicationClass,
) -> Result<(), ProtocolError> {
    if peer_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id is required",
        ));
    }
    if state.endpoint.read().await.is_none() || state.identity.read().await.is_none() {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
            "connect",
            &peer_id,
        ));
    }
    if !state.peers.read().await.contains_key(&peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no configured route",
            "connect",
            &peer_id,
        ));
    }
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Connecting,
        RouteType::Unspecified,
        None,
    );
    let supervisor = Arc::clone(&state.task_supervisor);
    let task_started = supervisor.spawn_runtime("peer-connect", async move {
        // transport-network v2（§11/§37）：唯一建连入口 ConnectionOrchestrator。
        let orchestrator = crate::connect::ConnectionOrchestrator::new(Arc::clone(&state));
        if let Err(error) = orchestrator.connect_with_class(&peer_id, class).await {
            let code =
                NetworkErrorCode::try_from(error.code).unwrap_or(NetworkErrorCode::Unspecified);
            emit_peer_state(
                &state.event_tx,
                &peer_id,
                PeerConnectionState::Failed,
                RouteType::Unspecified,
                Some(protocol_error_with_peer(
                    code,
                    error.message,
                    "connect",
                    &peer_id,
                )),
            );
        }
    });
    if task_started.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::Cancelled,
            "network runtime is stopping",
        ));
    }
    Ok(())
}

/// 接受 Relay 配置，并通过 Relay 事件报告 socket 认证结果。
async fn start_configure_relay(
    state: Arc<RuntimeState>,
    command: network_protocol::ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    if state.identity.read().await.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "runtime must be configured before Relay",
        ));
    }
    if command.relay_signing_seed.len() != 32 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay signing seed must contain 32 bytes",
        ));
    }
    if command.relay_url.trim().is_empty() || command.relay_credential.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay URL and credential are required",
        ));
    }
    emit_relay_state(&state.event_tx, RelayConnectionState::Connecting, None);
    let supervisor = Arc::clone(&state.task_supervisor);
    let task_started = supervisor.spawn_runtime("relay-configure", async move {
        match relay::configure_relay_for_state(Arc::clone(&state), command).await {
            Ok(()) => emit_relay_state(&state.event_tx, RelayConnectionState::Connected, None),
            Err(error) => {
                emit_relay_state(&state.event_tx, RelayConnectionState::Failed, Some(error))
            }
        }
    });
    if task_started.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::Cancelled,
            "network runtime is stopping",
        ));
    }
    Ok(())
}

/// 把 wire 上的 CommunicationClass 解码为内部值；未知值（非法）按默认
/// ReliableMessage 处理，保证旧调用方（发送 0）行为不变。
fn decode_communication_class(value: i32) -> CommunicationClass {
    CommunicationClass::try_from(value).unwrap_or(CommunicationClass::ReliableMessage)
}

/// 显式重传设备 Discovery 元数据；native 侧在 Relay 认证连接后也会自动上传首份。
async fn start_upload_discovery(
    state: Arc<RuntimeState>,
    command: network_protocol::UploadDiscoveryCommand,
) -> Result<(), ProtocolError> {
    if state.identity.read().await.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "runtime must be configured before Relay discovery upload",
        ));
    }
    relay::upload_discovery(&state, command).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_identity::DeviceIdentity;
    use network_protocol::{network_command, UploadDiscoveryCommand};
    use std::sync::atomic::AtomicU16;

    fn discovery_command(
        generation: u64,
        candidates: Vec<String>,
        capabilities: Vec<String>,
    ) -> NetworkCommand {
        NetworkCommand {
            command_id: "upload-discovery".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UploadDiscovery(
                UploadDiscoveryCommand {
                    generation,
                    candidates,
                    capabilities,
                },
            )),
        }
    }

    async fn configured_state() -> Arc<RuntimeState> {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
        *state.identity.write().await = Some(Arc::new(DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        )));
        state
    }

    #[tokio::test]
    async fn upload_discovery_requires_a_runtime_identity() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
        let result = dispatch_command(discovery_command(1, vec![], vec![]), state).await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::InvalidArgument as i32
        ));
    }

    #[tokio::test]
    async fn upload_discovery_rejects_zero_generation() {
        let result = dispatch_command(
            discovery_command(0, vec![], vec![]),
            configured_state().await,
        )
        .await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::InvalidArgument as i32
        ));
    }

    #[tokio::test]
    async fn upload_discovery_requires_a_connected_relay() {
        let result = dispatch_command(
            discovery_command(1, vec!["candidate".into()], vec!["file-transfer".into()]),
            configured_state().await,
        )
        .await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::RelayError as i32
        ));
    }
}
