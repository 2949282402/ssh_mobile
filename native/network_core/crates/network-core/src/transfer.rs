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
use std::collections::{hash_map::Entry, HashMap};
use std::error::Error;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::sync::{
    mpsc::{channel, Receiver},
    oneshot, RwLock,
};

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
    EventSender, RelayTransferPort, RuntimeState, TransferRelayPort, INCOMING_APPROVAL_TIMEOUT,
    MAX_PENDING_INCOMING_TRANSFERS, TRANSFER_COMPLETION_TIMEOUT,
};

/// Runtime-owned Transfer domain state. The manager is kept behind this
/// boundary so RuntimeState does not expose a second flat business owner.
pub(crate) struct TransferDomainState {
    pub(crate) manager: TransferManager,
    pub(crate) incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
}

impl TransferDomainState {
    pub(crate) fn new() -> Self {
        Self {
            manager: TransferManager::new(),
            incoming_decisions: RwLock::new(HashMap::new()),
        }
    }
}

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
                        state.dispatch_relay_transfer(peer, transfer, lease).await;
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

#[path = "transfer_operations.rs"]
mod transfer_operations;

pub(super) use transfer_operations::*;

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
