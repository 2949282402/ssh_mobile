//! V2 直连文件传输任务分发及类型化完成/失败事件。

use network_protocol::{
    CommunicationClass, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    RespondIncomingTransferCommand, RouteType, SendFileCommand,
};
use network_quic::{
    read_file_completion, read_file_decision, write_file_completion, write_file_decision,
    write_file_offer,
};
use network_transfer::{
    build_file_manifest, existing_completed_file, existing_partial_offset,
    stream_receive_file_cancellable, stream_send_file_cancellable, FileManifest, ResumableTransfer,
    TransferFailureReason, TransferManager, NETWORK_TRANSFER_PROTOCOL_VERSION,
};
use quinn::{Connection, RecvStream, SendStream};
use std::collections::hash_map::Entry;
use std::error::Error;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc::{channel, Receiver};

use crate::channel::select_business_path_lease;
use crate::connect::{PathLease, CAPABILITY_RELIABLE_STREAM};
use crate::connection::RouteTransport;
use crate::delivery::{is_valid_peer_id, BusinessRecoveryError};
use crate::errors::CoreNetworkError;
use crate::events::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error,
    emit_transfer_progress_for_peer, protocol_error, protocol_error_with_peer,
};
use crate::runtime::{
    EventSender, RuntimeState, INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS,
    TRANSFER_COMPLETION_TIMEOUT,
};

/// Frozen logical transfer identity. ConnectionSession and route handles are
/// intentionally absent; a path loss changes only the current attempt.
#[allow(dead_code)]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct TransferIdentity {
    pub peer_id: String,
    pub transfer_id: String,
}

impl TransferIdentity {
    #[allow(dead_code)]
    pub fn new(
        peer_id: impl Into<String>,
        transfer_id: impl Into<String>,
    ) -> Result<Self, &'static str> {
        let identity = Self {
            peer_id: peer_id.into(),
            transfer_id: transfer_id.into(),
        };
        if identity.peer_id.is_empty() || identity.transfer_id.is_empty() {
            return Err("peer_id and transfer_id are required");
        }
        Ok(identity)
    }
}

#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransferLifecycle {
    Queued,
    Active,
    Paused,
    Resuming,
    Completed,
    Cancelled,
    Failed,
}

#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConfirmedOffset {
    pub offset: u64,
    pub total: u64,
}

impl ConfirmedOffset {
    #[allow(dead_code)]
    pub fn new(offset: u64, total: u64) -> Result<Self, &'static str> {
        if offset > total {
            return Err("confirmed offset exceeds transfer size");
        }
        Ok(Self { offset, total })
    }
}

/// Progress is advisory data, but it is emitted once per transfer chunk. Keep
/// the queue bounded so a stalled event consumer cannot retain an entire file
/// transfer in memory; the producer naturally backpressures on this lane.
const TRANSFER_PROGRESS_QUEUE_CAPACITY: usize = 64;

/// 当前一次传输尝试使用的 Route handle。它只存在于 dispatcher/worker，
/// 不会进入 network-transfer 的 TransferSession。
#[derive(Clone)]
enum TransferRoute {
    QuicDirect(Connection),
    Relay,
}

/// 传输的 Route 适配边界。TransferManager 只管理业务会话和偏移，
/// 当前 QUIC/Relay handle 的选择集中在这里。
#[derive(Clone)]
struct TransferDispatcher {
    state: Arc<RuntimeState>,
}

impl TransferDispatcher {
    fn new(state: Arc<RuntimeState>) -> Self {
        Self { state }
    }

    async fn select_attempt(
        &self,
        identity: &TransferIdentity,
    ) -> Result<(TransferRoute, PathLease), ProtocolError> {
        ensure_business_path(
            &self.state,
            &identity.peer_id,
            &identity.transfer_id,
            CommunicationClass::BulkTransfer,
            CAPABILITY_RELIABLE_STREAM,
        )
        .await
        .map_err(|error| {
            protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                error.to_string(),
                "send",
                &identity.peer_id,
            )
        })?;
        let lease =
            select_business_path_lease(&self.state, &identity.peer_id, CAPABILITY_RELIABLE_STREAM)
                .await
                .map_err(|error| {
                    protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        error.to_string(),
                        "send",
                        &identity.peer_id,
                    )
                })?;
        if !lease
            .profile()
            .supports(crate::connection::ConnectionCapability::ReliableStream)
        {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "selected path does not support file transfer",
                "send",
                &identity.peer_id,
            ));
        }
        match lease.profile().transport() {
            RouteTransport::Quic => {
                let connection = self
                    .state
                    .path_connection_for_lease(&lease)
                    .await
                    .ok_or_else(|| {
                        protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "selected QUIC path has no active Connection",
                            "send",
                            &identity.peer_id,
                        )
                    })?;
                if !lease.is_active() {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "selected QUIC path was lost before transfer start",
                        "send",
                        &identity.peer_id,
                    ));
                }
                Ok((TransferRoute::QuicDirect(connection), lease))
            }
            RouteTransport::WebSocket
                if lease.profile().topology() == crate::connection::RouteTopology::Relay =>
            {
                let usable = match self.state.path_relay_data_for_lease(&lease).await {
                    Some(data) => data.is_usable().await,
                    None => false,
                };
                if usable && lease.is_active() {
                    Ok((TransferRoute::Relay, lease))
                } else {
                    Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "selected Relay path has no active data reservation",
                        "send",
                        &identity.peer_id,
                    ))
                }
            }
            _ => Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "selected path cannot carry file transfer",
                "send",
                &identity.peer_id,
            )),
        }
    }

    async fn dispatch_outgoing(
        &self,
        route: TransferRoute,
        lease: PathLease,
        transfer: ResumableTransfer,
    ) -> Result<(), ProtocolError> {
        match route {
            TransferRoute::QuicDirect(connection) => {
                let session_key = transfer.session_id.clone();
                if self
                    .state
                    .task_supervisor
                    .spawn_session(
                        session_key,
                        "file-send",
                        send_file(connection, transfer, Arc::clone(&self.state), lease),
                    )
                    .is_none()
                {
                    return Err(protocol_error(
                        NetworkErrorCode::Cancelled,
                        "network runtime is stopping",
                    ));
                }
                Ok(())
            }
            TransferRoute::Relay => {
                let peer = self
                    .state
                    .peers
                    .read()
                    .await
                    .get(&transfer.peer_id)
                    .cloned()
                    .ok_or_else(|| {
                        protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "peer is not registered",
                            "send",
                            &transfer.peer_id,
                        )
                    })?;
                let session_key = transfer.session_id.clone();
                let state = Arc::clone(&self.state);
                if self
                    .state
                    .task_supervisor
                    .spawn_session(session_key, "relay-file-send", async move {
                        let _lease = lease;
                        crate::relay::send_file_over_relay(peer, transfer, state).await;
                    })
                    .is_none()
                {
                    return Err(protocol_error(
                        NetworkErrorCode::Cancelled,
                        "network runtime is stopping",
                    ));
                }
                Ok(())
            }
        }
    }
}

#[derive(Debug)]
struct TransferAttemptError {
    reason: TransferFailureReason,
    recovery_error: BusinessRecoveryError,
    terminal: bool,
    message: &'static str,
}

impl fmt::Display for TransferAttemptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message)
    }
}

impl Error for TransferAttemptError {}

impl TransferAttemptError {
    fn stale_attempt(reason: TransferFailureReason) -> Self {
        Self {
            reason,
            recovery_error: BusinessRecoveryError::RecoverableTransportLoss,
            terminal: false,
            message: "transfer attempt no longer owns the business operation",
        }
    }

    fn recovery_error(&self) -> BusinessRecoveryError {
        self.recovery_error
    }
}

fn valid_transfer_identity(transfer_id: &str, peer_id: &str) -> bool {
    is_valid_peer_id(peer_id)
        && !transfer_id.is_empty()
        && transfer_id.len() <= 128
        && transfer_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// Ensure a business-capable path without enabling long-lived peer maintenance.
///
/// SessionId is deliberately absent from this decision: it is only attached
/// later when a concrete transport attempt needs a current wire/task key.
pub(crate) async fn ensure_business_path(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    command_id: &str,
    class: CommunicationClass,
    required_capabilities: u8,
) -> Result<(), CoreNetworkError> {
    if let Ok(lease) = state
        .acquire_path_lease(peer_id, required_capabilities)
        .await
    {
        drop(lease);
        return Ok(());
    }
    RuntimeState::ensure_business_path(
        Arc::clone(state),
        peer_id,
        command_id,
        class,
        required_capabilities,
    )
    .await
    .map(|_| ())
}

/// 校验源文件，并交给当前逻辑 Session 的 Route Dispatcher。
pub(crate) async fn start_file_send(
    state: Arc<RuntimeState>,
    command: SendFileCommand,
) -> Result<(), ProtocolError> {
    if !valid_transfer_identity(&command.transfer_id, &command.peer_id)
        || command.file_path.is_empty()
    {
        return Err(crate::events::protocol_error_with_context(
            NetworkErrorCode::InvalidArgument,
            "transfer_id, peer_id, and file_path are required",
            "send",
            Some(&command.peer_id),
        ));
    }
    let path = PathBuf::from(&command.file_path);
    let metadata = tokio::fs::metadata(&path).await.map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::IoError,
            "source file is unavailable",
            "send",
            &command.peer_id,
        )
    })?;
    if !metadata.is_file() {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "source is not a regular file",
            "send",
            &command.peer_id,
        ));
    }
    if !state.peers.read().await.contains_key(&command.peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer is not registered",
            "send",
            &command.peer_id,
        ));
    }
    let manifest = build_file_manifest(command.transfer_id.clone(), &path)
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::IoError,
                "source file cannot be hashed",
                "send",
                &command.peer_id,
            )
        })?;
    manifest.validate().map_err(|message| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            message,
            "send",
            &command.peer_id,
        )
    })?;
    let identity = TransferIdentity::new(command.peer_id.clone(), command.transfer_id.clone())
        .map_err(|message| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                message,
                "send",
                &command.peer_id,
            )
        })?;
    let dispatcher = TransferDispatcher::new(Arc::clone(&state));
    let (route, lease) = dispatcher.select_attempt(&identity).await?;
    // §19：TransferOperation 按 transfer_id + peer_id 注册，SessionId 不进入
    // 持久化的业务状态；仅为本次 transport attempt 附加当前 wire/task key。
    if !state
        .transfers
        .register_outgoing(manifest.clone(), path.clone(), command.peer_id.clone())
        .await
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "transfer_id is already active",
            "send",
            &command.peer_id,
        ));
    }
    let session_key = state
        .connection_sessions
        .current_session_id(&identity.peer_id)
        .await
        .map(|session_id| session_id.wire_key())
        .unwrap_or_else(|| format!("transfer:{}", identity.transfer_id));
    let transfer = ResumableTransfer {
        transfer_id: manifest.transfer_id.clone(),
        peer_id: identity.peer_id.clone(),
        session_id: session_key,
        source_path: path,
        manifest,
        offset: 0,
    };
    if let Err(error) = dispatcher.dispatch_outgoing(route, lease, transfer).await {
        state.transfers.remove_transfer(&command.transfer_id).await;
        return Err(error);
    }
    Ok(())
}

/// 流式传输直连 QUIC 文件；Route handle 由 dispatcher 注入，业务状态仍
/// 只通过 TransferManager 更新。
async fn send_file(
    connection: Connection,
    transfer: ResumableTransfer,
    state: Arc<RuntimeState>,
    lease: PathLease,
) {
    let transfer_id = transfer.transfer_id.clone();
    let peer_id = transfer.peer_id.clone();
    let result = async {
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        let current_manifest =
            build_file_manifest(transfer_id.clone(), &transfer.source_path).await?;
        if current_manifest != transfer.manifest {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::SourceChanged,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "source file changed during resumable transfer",
                }
                .into(),
            );
        }
        let (mut send, mut receive) = connection.open_bi().await?;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        write_file_offer(&mut send, &transfer.manifest).await?;
        let offset = read_file_decision(&mut receive)
            .await?
            .ok_or(TransferAttemptError {
                reason: TransferFailureReason::UserRejected,
                recovery_error: BusinessRecoveryError::ResumeRejected,
                terminal: true,
                message: "receiver rejected file",
            })?;
        if offset > transfer.manifest.file_size {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::Protocol,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "invalid resume offset",
                }
                .into(),
            );
        }
        if !state.transfers.mark_transferring(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError {
                    reason: TransferFailureReason::Protocol,
                    recovery_error: BusinessRecoveryError::ResumeRejected,
                    terminal: true,
                    message: "transfer is no longer resumable",
                }
                .into(),
            );
        }
        state.transfers.update_progress(&transfer_id, offset).await;
        let (progress_tx, progress_rx) = channel(TRANSFER_PROGRESS_QUEUE_CAPACITY);
        let _ = state.task_supervisor.spawn_session(
            transfer.session_id.clone(),
            "file-send-progress",
            forward_progress(
                transfer_id.clone(),
                peer_id.clone(),
                progress_rx,
                state.event_tx.clone(),
                state.transfers.clone(),
                false,
            ),
        );
        let cancellation = state.transfers.cancellation_token(&transfer_id).await;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        stream_send_file_cancellable(
            &transfer.source_path,
            offset,
            &mut send,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        if !lease.is_active() {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "business path was lost")
                    .into(),
            );
        }
        send.finish()?;
        if !state.transfers.mark_verifying(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        tokio::time::timeout(
            TRANSFER_COMPLETION_TIMEOUT,
            read_file_completion(&mut receive),
        )
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "file completion timed out")
        })??;
        if !state
            .transfers
            .update_progress(&transfer_id, transfer.manifest.file_size)
            .await
            || !state.transfers.mark_completed(&transfer_id).await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    match result {
        Ok(()) => state.transfers.remove_transfer(&transfer_id).await,
        Err(error)
            if !state.transfers.is_cancelled(&transfer_id).await
                && is_transient_transport_error(error.as_ref())
                && state.transfers.pause_for_network(&transfer_id).await =>
        {
            // 保留源文件、TransferId 和接收端的 `.part`，等待
            // 同一 Peer 的下一次兼容 PathLease。
            tracing::debug!(transfer_id = %transfer_id, error = %error, "native QUIC transfer paused for resume");
        }
        Err(error) => {
            if error
                .downcast_ref::<TransferAttemptError>()
                .is_some_and(|attempt| !attempt.terminal)
            {
                return;
            }
            if state.transfers.snapshot(&transfer_id).await.is_none() {
                return;
            }
            let reason = error
                .downcast_ref::<TransferAttemptError>()
                .map_or(TransferFailureReason::Io, |error| error.reason);
            let recovery_error = error
                .downcast_ref::<TransferAttemptError>()
                .map_or(BusinessRecoveryError::OperationExpired, |error| {
                    error.recovery_error()
                });
            let code = transfer_failure_code(reason);
            if state.transfers.fail_transfer(&transfer_id, reason).await {
                emit_transfer_error(
                    &state.event_tx,
                    &transfer_id,
                    code,
                    "file transfer failed".to_string(),
                    "send",
                    Some(&peer_id),
                );
                state.transfers.remove_transfer(&transfer_id).await;
            }
            tracing::debug!(
                transfer_id = %transfer_id,
                recovery_error = %recovery_error,
                error = %error,
                "native file transfer failed"
            );
        }
    }
}

/// 新 ConnectionSession 建立后领取同一 Peer 的暂停传输（§19 ResumeTransfer）。
///
/// 领取按 transfer_id + peer_id 进行；当前 ConnectionSession 的 wire key 作为
/// `session_id` 附加到每个 ResumableTransfer（Relay E2EE / 任务分组），并在新的
/// QUIC/Relay 连接上重新协商 confirmed_offset。
pub(crate) async fn resume_transfers_for_peer(state: Arc<RuntimeState>, peer_id: String) {
    if !is_valid_peer_id(&peer_id) {
        return;
    }
    let dispatcher = TransferDispatcher::new(Arc::clone(&state));
    let Some(session_id) = state.connection_sessions.current_session_id(&peer_id).await else {
        return;
    };
    let session_key = session_id.wire_key();
    let transfers = state
        .transfers
        .take_resumable_for_peer(&peer_id, &session_key)
        .await;
    for transfer in transfers {
        let identity = TransferIdentity {
            peer_id: peer_id.clone(),
            transfer_id: transfer.transfer_id.clone(),
        };
        let attempt = match dispatcher.select_attempt(&identity).await {
            Ok(attempt) => attempt,
            Err(error) => {
                let _ = state
                    .transfers
                    .pause_for_network(&transfer.transfer_id)
                    .await;
                tracing::debug!(
                    peer_id = %peer_id,
                    transfer_id = %transfer.transfer_id,
                    error = ?error,
                    "transfer resume waited for a fresh path lease"
                );
                continue;
            }
        };
        if dispatcher
            .dispatch_outgoing(attempt.0, attempt.1, transfer)
            .await
            .is_err()
        {
            tracing::debug!(peer_id = %peer_id, "transfer remained paused after resume dispatch failed");
        }
    }
}

/// Relay socket 重连后恢复所有仍处于 Relay Route 的暂停传输。
pub(crate) async fn resume_relay_transfers(state: Arc<RuntimeState>) {
    let peer_ids = state.peers.read().await.keys().cloned().collect::<Vec<_>>();
    for peer_id in peer_ids {
        resume_transfers_for_peer(Arc::clone(&state), peer_id).await;
    }
}

/// 校验传入申请，并等待接收方审批决定。
/// Mirrors `network_quic::read_file_offer` for the shared bidi dispatcher: the
/// first four magic bytes have already been consumed to route the stream, so
/// the remaining offer fields are parsed here without re-touching the magic.
/// Kept in network-core to avoid coupling the accept loop to a network-quic
/// signature change; the wire format is identical to `read_file_offer`.
pub(crate) async fn read_file_offer_after_magic(
    receive: &mut RecvStream,
) -> Result<FileManifest, Box<dyn Error + Send + Sync>> {
    let protocol_version = receive.read_u32().await?;
    if protocol_version != NETWORK_TRANSFER_PROTOCOL_VERSION {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "unsupported file protocol",
        )
        .into());
    }
    let transfer_id = read_bounded_utf8(receive, MAX_TRANSFER_ID_BYTES, "transfer ID").await?;
    let file_name = read_bounded_utf8(receive, MAX_FILE_NAME_BYTES, "file name").await?;
    let file_size = receive.read_u64().await?;
    let modified_at = receive.read_i64().await?;
    let mut hash = [0u8; 32];
    receive.read_exact(&mut hash).await?;
    let manifest = FileManifest {
        transfer_id,
        file_name,
        file_size,
        modified_at,
        content_hash: hex::encode(hash),
        protocol_version,
    };
    manifest
        .validate()
        .map_err(|message| std::io::Error::new(std::io::ErrorKind::InvalidData, message))?;
    Ok(manifest)
}

async fn read_bounded_utf8(
    receive: &mut RecvStream,
    maximum: usize,
    label: &str,
) -> Result<String, Box<dyn Error + Send + Sync>> {
    let length = receive.read_u16().await? as usize;
    if length == 0 || length > maximum {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid {label} length"),
        )
        .into());
    }
    let mut value = vec![0u8; length];
    receive.read_exact(&mut value).await?;
    String::from_utf8(value).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{label} is not UTF-8"),
        )
        .into()
    })
}

const MAX_TRANSFER_ID_BYTES: usize = 128;
const MAX_FILE_NAME_BYTES: usize = 255;

/// Processes an incoming transfer whose offer has already been parsed by the
/// shared bidi dispatcher (`read_file_offer_after_magic`), so the file data
/// path never duplicates the transfer lifecycle.
pub(crate) async fn handle_incoming_file_after_offer(
    peer_id: String,
    mut send: SendStream,
    mut receive: RecvStream,
    manifest: FileManifest,
    state: Arc<RuntimeState>,
) {
    if !valid_transfer_identity(&manifest.transfer_id, &peer_id) {
        let _ = write_file_decision(&mut send, false, 0).await;
        let _ = send.finish();
        return;
    }
    let mut active_transfer_id = None;
    let mut registered_transfer = false;
    let result = async {
        active_transfer_id = Some(manifest.transfer_id.clone());
        // SessionId is only a transport-local task grouping key. The incoming
        // business operation remains keyed by (peer_id, transfer_id).
        let session_key = state
            .connection_sessions
            .current_session_id(&peer_id)
            .await
            .map(|session_id| session_id.wire_key())
            .unwrap_or_else(|| format!("transfer:{}", manifest.transfer_id));
        if !state
            .transfers
            .register_incoming(manifest.clone(), peer_id.clone())
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer ID is already active",
                )
                .into(),
            );
        }
        registered_transfer = true;
        let (decision_tx, decision_rx) = tokio::sync::oneshot::channel();
        {
            let mut decisions = state.incoming_decisions.write().await;
            if decisions.len() >= MAX_PENDING_INCOMING_TRANSFERS {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::other("too many pending incoming transfers").into(),
                );
            }
            match decisions.entry(manifest.transfer_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(decision_tx);
                }
                Entry::Occupied(_) => {
                    return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                        std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            "duplicate transfer ID",
                        )
                        .into(),
                    );
                }
            }
        }
        emit_incoming_offer(&state.event_tx, &peer_id, &manifest, RouteType::QuicDirect);
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, decision_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state
            .incoming_decisions
            .write()
            .await
            .remove(&manifest.transfer_id);
        if !accepted {
            write_file_decision(&mut send, false, 0).await?;
            send.finish()?;
            state.transfers.cancel_transfer(&manifest.transfer_id).await;
            state.transfers.remove_transfer(&manifest.transfer_id).await;
            return Ok(());
        }

        let receive_directory = state
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
        let completed_path = existing_completed_file(&manifest, &receive_directory).await?;
        let resume_offset = match completed_path.as_ref() {
            Some(_) => manifest.file_size,
            None => existing_partial_offset(&manifest, &receive_directory).await?,
        };
        write_file_decision(&mut send, true, resume_offset).await?;
        if let Some(local_path) = completed_path {
            if !state
                .transfers
                .mark_transferring(&manifest.transfer_id)
                .await
                || !state
                    .transfers
                    .update_progress(&manifest.transfer_id, manifest.file_size)
                    .await
                || !state.transfers.mark_verifying(&manifest.transfer_id).await
            {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
                );
            }
            write_file_completion(&mut send).await?;
            send.finish()?;
            if !state.transfers.mark_completed(&manifest.transfer_id).await {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
                );
            }
            state.transfers.remove_transfer(&manifest.transfer_id).await;
            emit_transfer_completed(&state.event_tx, &manifest.transfer_id, &local_path);
            return Ok(());
        }
        if !state
            .transfers
            .mark_transferring(&manifest.transfer_id)
            .await
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer is no longer awaiting approval",
                )
                .into(),
            );
        }
        state
            .transfers
            .update_progress(&manifest.transfer_id, resume_offset)
            .await;
        let cancellation = state
            .transfers
            .cancellation_token(&manifest.transfer_id)
            .await;
        let (progress_tx, progress_rx) = channel(TRANSFER_PROGRESS_QUEUE_CAPACITY);
        let _ = state.task_supervisor.spawn_session(
            session_key.clone(),
            "file-receive-progress",
            forward_progress(
                manifest.transfer_id.clone(),
                peer_id.clone(),
                progress_rx,
                state.event_tx.clone(),
                state.transfers.clone(),
                true,
            ),
        );
        let local_path = stream_receive_file_cancellable(
            &manifest,
            &receive_directory,
            resume_offset,
            &mut receive,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        if !state.transfers.mark_verifying(&manifest.transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        write_file_completion(&mut send).await?;
        send.finish()?;
        if !state.transfers.mark_completed(&manifest.transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                TransferAttemptError::stale_attempt(TransferFailureReason::Protocol).into(),
            );
        }
        state.transfers.remove_transfer(&manifest.transfer_id).await;
        emit_transfer_completed(&state.event_tx, &manifest.transfer_id, &local_path);
        Ok(())
    }
    .await;
    let preserve_partial = result
        .as_ref()
        .err()
        .is_some_and(|error| is_transient_transport_error(error.as_ref()));
    if let Some(transfer_id) = active_transfer_id.as_deref() {
        state.incoming_decisions.write().await.remove(transfer_id);
        if registered_transfer && result.is_err() && preserve_partial {
            state.transfers.pause_for_network(transfer_id).await;
        } else if registered_transfer && result.is_err() {
            state.transfers.remove_transfer(transfer_id).await;
            let receive_directory = state.receive_directory.read().await.clone();
            if let Some(receive_directory) = receive_directory {
                tokio::fs::remove_file(receive_directory.join(format!("{transfer_id}.part")))
                    .await
                    .ok();
            }
        }
    }
    if let Err(error) = result {
        if let Some(transfer_id) = active_transfer_id.as_deref() {
            if state.transfers.snapshot(transfer_id).await.is_none() {
                return;
            }
        }
        if preserve_partial {
            tracing::debug!(peer_id = %peer_id, error = %error, "incoming native transfer paused for resume");
            return;
        }
        let reason = error
            .downcast_ref::<TransferAttemptError>()
            .map_or(TransferFailureReason::Io, |error| error.reason);
        emit_transfer_error(
            &state.event_tx,
            active_transfer_id.as_deref().unwrap_or("incoming"),
            transfer_failure_code(reason),
            "incoming file transfer failed".to_string(),
            "receive",
            Some(&peer_id),
        );
        tracing::debug!(peer_id = %peer_id, error = %error, "incoming native file transfer failed");
    }
}

/// 将 UI 审批决定应用到待处理直连传输。
pub(crate) async fn respond_to_incoming(
    state: &RuntimeState,
    response: RespondIncomingTransferCommand,
) -> Result<(), ProtocolError> {
    if let Some(sender) = state
        .incoming_decisions
        .write()
        .await
        .remove(&response.transfer_id)
    {
        return sender.send(response.accept).map_err(|_| {
            protocol_error(
                NetworkErrorCode::Cancelled,
                "incoming transfer approval expired",
            )
        });
    }
    crate::relay::respond_to_relay_incoming(state, &response.transfer_id, response.accept).await
}

/// 将流 worker 的有界传输进度转发为事件。
async fn forward_progress(
    transfer_id: String,
    peer_id: String,
    mut progress: Receiver<(u64, u64)>,
    event_tx: EventSender,
    manager: TransferManager,
    confirm_offset: bool,
) {
    while let Some((bytes_transferred, total_bytes)) = progress.recv().await {
        let accepted = if confirm_offset {
            manager
                .update_progress(&transfer_id, bytes_transferred)
                .await
        } else {
            manager.snapshot(&transfer_id).await.is_some()
        };
        if accepted {
            emit_transfer_progress_for_peer(
                &event_tx,
                &peer_id,
                &transfer_id,
                bytes_transferred,
                total_bytes,
                false,
            );
        } else {
            return;
        }
    }
}

/// 区分可通过新 Connection 恢复的 transport 失败与 manifest/审批/校验失败。
fn is_transient_transport_error(error: &(dyn Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
        if let Some(error) = error.downcast_ref::<std::io::Error>() {
            if matches!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::TimedOut
            ) {
                return true;
            }
        }
        if let Some(error) = error.downcast_ref::<quinn::ConnectionError>() {
            if matches!(
                error,
                quinn::ConnectionError::TransportError(_)
                    | quinn::ConnectionError::ConnectionClosed(_)
                    | quinn::ConnectionError::ApplicationClosed(_)
                    | quinn::ConnectionError::Reset
                    | quinn::ConnectionError::TimedOut
            ) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

fn transfer_failure_code(reason: TransferFailureReason) -> NetworkErrorCode {
    match reason {
        TransferFailureReason::UserRejected => NetworkErrorCode::Cancelled,
        TransferFailureReason::Permission => NetworkErrorCode::InvalidArgument,
        TransferFailureReason::Protocol => NetworkErrorCode::InvalidArgument,
        TransferFailureReason::HashMismatch
        | TransferFailureReason::SourceChanged
        | TransferFailureReason::Io => NetworkErrorCode::IoError,
        TransferFailureReason::RetryBudgetExhausted => NetworkErrorCode::Timeout,
        TransferFailureReason::SessionReplaced => NetworkErrorCode::PathLost,
    }
}

/// 将传输专属命令分发到所属传输子系统。
pub(crate) async fn dispatch_transfer_command(
    state: Arc<RuntimeState>,
    command: NetworkCommand,
) -> Result<(), ProtocolError> {
    match command.payload {
        Some(network_protocol::network_command::Payload::SendFile(send)) => {
            start_file_send(state, send).await
        }
        Some(network_protocol::network_command::Payload::CancelTransfer(cancel)) => {
            if state.transfers.cancel_transfer(&cancel.transfer_id).await {
                crate::relay::cancel_transfer(&state, &cancel.transfer_id).await;
                Ok(())
            } else {
                Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "transfer is not active",
                ))
            }
        }
        Some(network_protocol::network_command::Payload::RespondIncomingTransfer(response)) => {
            respond_to_incoming(&state, response).await
        }
        _ => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "unsupported transfer command",
        )),
    }
}

#[cfg(test)]
mod v2_contract_tests {
    use super::*;
    use network_protocol::NetworkEvent;
    use std::sync::Mutex;
    use tokio::sync::mpsc::unbounded_channel;

    async fn state_with_ready_stream_path() -> (Arc<RuntimeState>, Arc<crate::connect::PathRegistry>)
    {
        let (event_tx, _event_rx) = unbounded_channel::<NetworkEvent>();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let registry = Arc::new(crate::connect::PathRegistry::new());
        let mut manager = crate::connect::PeerPathManager::new(
            crate::connect::PeerId::new("peer-a").expect("peer"),
            Arc::clone(&registry),
        );
        manager
            .publish_ready(crate::connection::ConnectionProfile::new(
                crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
            ))
            .expect("ready path");
        state
            .peer_path_managers
            .write()
            .await
            .insert("peer-a".to_string(), Arc::new(Mutex::new(manager)));
        (state, registry)
    }

    #[tokio::test]
    async fn transfer_auto_ensures_path() {
        let (state, _registry) = state_with_ready_stream_path().await;
        ensure_business_path(
            &state,
            "peer-a",
            "transfer-auto",
            CommunicationClass::BulkTransfer,
            CAPABILITY_RELIABLE_STREAM,
        )
        .await
        .expect("bulk transfer should use the compatible ready path");
    }

    #[test]
    fn transfer_identity_and_confirmed_offset_are_session_independent() {
        let identity = TransferIdentity::new("peer-a", "transfer-a").expect("identity");
        assert_eq!(identity.peer_id, "peer-a");
        assert_eq!(identity.transfer_id, "transfer-a");
        assert_ne!(
            identity,
            TransferIdentity::new("peer-b", "transfer-a").expect("peer-scoped identity")
        );
        assert_eq!(ConfirmedOffset::new(4, 8).expect("offset").offset, 4);
        assert!(ConfirmedOffset::new(9, 8).is_err());
    }

    #[test]
    fn path_loss_is_a_recoverable_public_error() {
        assert_eq!(
            transfer_failure_code(TransferFailureReason::SessionReplaced),
            NetworkErrorCode::PathLost
        );
    }

    #[tokio::test]
    async fn transfer_resume_survives_new_connection_session_id() {
        let manager = network_transfer::TransferManager::new();
        let manifest = FileManifest {
            transfer_id: "transfer-session-independent".to_string(),
            file_name: "payload.bin".to_string(),
            file_size: 8,
            modified_at: 0,
            content_hash: "00".repeat(32),
            protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
        };
        assert!(
            manager
                .register_outgoing(manifest, PathBuf::from("payload.bin"), "peer-a".to_string(),)
                .await
        );
        assert!(
            manager
                .mark_transferring("transfer-session-independent")
                .await
        );
        assert!(
            manager
                .update_progress("transfer-session-independent", 4)
                .await
        );
        assert!(
            manager
                .pause_for_network("transfer-session-independent")
                .await
        );

        let old_session_id = "session-old";
        let new_session_id = "session-new";
        assert_ne!(old_session_id, new_session_id);
        let resumed = manager
            .take_resumable_for_peer("peer-a", new_session_id)
            .await;
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].peer_id, "peer-a");
        assert_eq!(resumed[0].transfer_id, "transfer-session-independent");
        assert_eq!(resumed[0].session_id, new_session_id);
        assert_eq!(resumed[0].offset, 4);
    }

    #[test]
    fn transfer_path_loss_acquires_fresh_lease() {
        let registry = Arc::new(crate::connect::PathRegistry::new());
        let mut manager = crate::connect::PeerPathManager::new(
            crate::connect::PeerId::new("peer-a").expect("peer"),
            Arc::clone(&registry),
        );
        let old_handle = manager
            .publish_ready(crate::connection::ConnectionProfile::new(
                crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
            ))
            .expect("old path");
        let old_lease = registry.acquire(&old_handle).expect("old lease");
        registry.drain(&old_handle);
        let new_handle = manager
            .publish_ready(crate::connection::ConnectionProfile::new(
                crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
            ))
            .expect("fresh path");
        let new_lease = registry.acquire(&new_handle).expect("fresh lease");
        assert_ne!(old_handle, new_handle);
        assert!(
            old_lease.is_active(),
            "normal retire drains the old attempt"
        );
        assert!(new_lease.is_active());
    }
}
