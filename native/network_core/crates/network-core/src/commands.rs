//! Network Protocol V2 运行时的命令校验、确认与任务分发。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::events::{
    emit_command_result, emit_peer_lifecycle, emit_relay_state, protocol_error,
    protocol_error_with_peer,
};
use crate::peer;
use crate::relay;
use crate::runtime::RuntimeState;
use crate::transfer;
use crate::{connect::PeerState, errors::CoreNetworkError};
use network_protocol::{
    network_command, CommunicationClass, NetworkCommand, NetworkError as ProtocolError,
    NetworkErrorCode, RelayConnectionState, NETWORK_PROTOCOL_VERSION,
};

const MAX_COMPLETED_COMMANDS: usize = 4096;

/// Tracks command ids at the runtime boundary. A command id is claimed before
/// dispatch and its result is emitted at most once for the lifetime of this
/// runtime. The set is deliberately bounded; a runtime restart starts a fresh
/// correlation domain instead of allowing unbounded bookkeeping growth.
struct CommandResultLedger {
    seen: Mutex<HashSet<String>>,
}

impl CommandResultLedger {
    fn new() -> Self {
        Self {
            seen: Mutex::new(HashSet::new()),
        }
    }

    fn claim(&self, command_id: &str) -> Result<bool, CoreNetworkError> {
        let mut seen = self.seen.lock().expect("command result ledger lock");
        if seen.contains(command_id) {
            return Ok(false);
        }
        if seen.len() >= MAX_COMPLETED_COMMANDS {
            return Err(CoreNetworkError::ResourceLimit("command result ledger"));
        }
        seen.insert(command_id.to_string());
        Ok(true)
    }
}

/// 运行唯一命令 worker，并为每个命令发布一个内部结果。
pub(crate) async fn run_command_worker(
    mut commands: tokio::sync::mpsc::Receiver<NetworkCommand>,
    state: Arc<RuntimeState>,
) {
    tracing::info!("Network runtime worker started");
    let result_ledger = CommandResultLedger::new();
    while let Some(command) = commands.recv().await {
        let command_id = command.command_id.clone();
        match result_ledger.claim(&command_id) {
            Ok(true) => {}
            // A duplicate command is intentionally silent: emitting another
            // event with the same id would break exactly-once correlation.
            Ok(false) => continue,
            Err(error) => {
                emit_command_result(
                    &state.event_tx,
                    command_id,
                    Err(protocol_error(NetworkErrorCode::IoError, error.to_string())),
                );
                continue;
            }
        }
        let result = dispatch_command(command, Arc::clone(&state)).await;
        emit_command_result(&state.event_tx, command_id, result);
    }
    tracing::info!("Network runtime worker shut down");
}

/// 校验 V2 信封，并将载荷路由到所属子系统。
pub(crate) async fn dispatch_command(
    command: NetworkCommand,
    state: Arc<RuntimeState>,
) -> Result<(), ProtocolError> {
    let command_id = command.command_id.clone();
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
        Some(network_command::Payload::UpsertPeerV2(command)) => {
            let config = command.config.ok_or_else(|| {
                protocol_error(NetworkErrorCode::InvalidArgument, "peer config is required")
            })?;
            validate_e2ee_policy(config.e2ee_policy)?;
            peer::upsert_peer(
                &state,
                network_protocol::UpsertPeerCommand {
                    peer_id: config.peer_id,
                    endpoint_address: config.endpoint_address,
                    identity_public_key: config.identity_public_key,
                    e2e_public_key: config.e2e_public_key,
                },
            )
            .await
        }
        Some(network_command::Payload::ConnectPeer(connect)) => {
            let class = decode_communication_class(connect.communication_class);
            start_connect_peer(state, command_id, connect.peer_id, class).await
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
        Some(network_command::Payload::RemovePeer(remove)) => {
            remove_peer_v2(&state, remove.peer_id).await
        }
        Some(network_command::Payload::SendMessageV2(message)) => {
            validate_e2ee_policy(message.e2ee_policy)?;
            crate::channel::start_send_message(
                state,
                network_protocol::SendMessageCommand {
                    peer_id: message.peer_id,
                    channel_id: message.channel_id,
                    payload: message.payload,
                    policy: message.policy,
                },
            )
            .await
        }
        Some(network_command::Payload::Transfer(transfer)) => {
            if transfer.peer_id.is_empty() || transfer.transfer_id.is_empty() {
                return Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "peer_id and transfer_id are required",
                ));
            }
            transfer::dispatch_transfer_command(
                state,
                NetworkCommand {
                    command_id,
                    protocol_version: NETWORK_PROTOCOL_VERSION,
                    payload: Some(network_command::Payload::SendFile(
                        network_protocol::SendFileCommand {
                            transfer_id: transfer.transfer_id,
                            peer_id: transfer.peer_id,
                            file_path: transfer.file_path,
                        },
                    )),
                },
            )
            .await
        }
        Some(network_command::Payload::PeerDiagnostics(diagnostics)) => {
            emit_peer_diagnostics(&state, diagnostics.peer_id).await
        }
        Some(network_command::Payload::NetworkEnvironmentChanged(environment)) => {
            crate::events::emit_network_environment_changed(&state.event_tx, environment);
            Ok(())
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

fn validate_e2ee_policy(value: i32) -> Result<(), ProtocolError> {
    network_protocol::E2eePolicy::try_from(value)
        .map(|_| ())
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "unknown E2EE policy"))
}

async fn remove_peer_v2(state: &RuntimeState, peer_id: String) -> Result<(), ProtocolError> {
    if peer_id.is_empty() || peer_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }
    state
        .peer_supervisors
        .disconnect(&peer_id)
        .map_err(|error| protocol_error(NetworkErrorCode::Lifecycle, error.to_string()))?;
    if let Ok(peer) = crate::connect::PeerId::new(&peer_id) {
        state.ready_paths.revoke_peer(&peer);
    }
    state.connection_sessions.close(&peer_id).await;
    state.delivery.close_peer(&peer_id).await;
    state.peers.write().await.remove(&peer_id);
    state.trusted_peer_keys.write().await.remove(&peer_id);
    state.remote_candidate_cache.write().await.remove(&peer_id);
    state.relay_data.write().await.remove(&peer_id);
    state.reliable_streams.write().await.remove(&peer_id);
    state.ready_session_index.unregister(&peer_id);
    let _ = state.peer_supervisors.remove_if_evictable(&peer_id);
    crate::events::emit_peer_lifecycle(
        &state.event_tx,
        &peer_id,
        PeerState::Offline,
        Some(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "peer removed",
            "remove_peer",
            &peer_id,
        )),
    );
    Ok(())
}

async fn emit_peer_diagnostics(state: &RuntimeState, peer_id: String) -> Result<(), ProtocolError> {
    if peer_id.is_empty() || peer_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }
    crate::events::emit_peer_diagnostics(
        &state.event_tx,
        network_protocol::PeerDiagnostics {
            peer_id,
            state: network_protocol::PeerState::Offline as i32,
            e2ee_policy: network_protocol::E2eePolicy::Required as i32,
            ready_path_count: 0,
            queued_command_count: 0,
            active_stream_count: 0,
            active_transfer_count: 0,
            last_error: None,
        },
    );
    Ok(())
}

/// 接受对端连接请求，并分离握手任务。
async fn start_connect_peer(
    state: Arc<RuntimeState>,
    command_id: String,
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
    let intent = state
        .peer_supervisors
        .start_connect(Arc::clone(&state), &peer_id, command_id, class)
        .map_err(|error| core_error(&peer_id, "connect", error))?;
    if !intent.is_new {
        intent.detach_completion();
        return Ok(());
    }
    intent.detach_completion();
    emit_peer_lifecycle(&state.event_tx, &peer_id, PeerState::Connecting, None);
    Ok(())
}

fn core_error(peer_id: &str, operation: &str, error: CoreNetworkError) -> ProtocolError {
    let code = match &error {
        CoreNetworkError::MailboxFull | CoreNetworkError::ResourceLimit(_) => {
            NetworkErrorCode::IoError
        }
        CoreNetworkError::SupervisorStopping | CoreNetworkError::Cancelled => {
            NetworkErrorCode::Cancelled
        }
        CoreNetworkError::NoRoute => NetworkErrorCode::NoRoute,
        CoreNetworkError::InvalidPeerId | CoreNetworkError::InvalidCommandId => {
            NetworkErrorCode::InvalidArgument
        }
        CoreNetworkError::DuplicateCommand => NetworkErrorCode::InvalidArgument,
        CoreNetworkError::StaleAttempt | CoreNetworkError::StaleIntent => {
            NetworkErrorCode::Cancelled
        }
        CoreNetworkError::CapabilityUnavailable => NetworkErrorCode::NoRoute,
    };
    protocol_error_with_peer(code, error.to_string(), operation, peer_id)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_result_ledger_claims_each_id_once() {
        let ledger = CommandResultLedger::new();
        assert_eq!(ledger.claim("command-1"), Ok(true));
        assert_eq!(ledger.claim("command-1"), Ok(false));
        assert_eq!(ledger.claim("command-2"), Ok(true));
    }
}
