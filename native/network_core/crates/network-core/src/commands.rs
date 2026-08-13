//! v1 运行时的命令校验、确认与任务分发。

use std::sync::Arc;

use network_protocol::{
    network_command, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    PeerConnectionState, RelayConnectionState, RouteType, NETWORK_PROTOCOL_VERSION,
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
            start_connect_peer(state, connect.peer_id).await
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
        Some(network_command::Payload::DisconnectPeer(disconnect)) => {
            peer::disconnect_peer(&state, disconnect.peer_id).await
        }
        Some(network_command::Payload::DisconnectRelay(_)) => relay::disconnect_relay(&state).await,
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
        if let Err(error) = peer::connect_peer(Arc::clone(&state), peer_id.clone()).await {
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
