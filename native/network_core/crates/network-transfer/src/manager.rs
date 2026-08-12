use crate::cancellation::TransferCancellation;
use crate::manifest::FileManifest;
use std::collections::{hash_map::Entry, HashMap};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

/// 传输失败的稳定原因。网络断开不属于这里的终态错误，而是进入
/// [`TransferState::Paused`]，等待同一逻辑 Session 的新 Route。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferFailureReason {
    HashMismatch,
    SourceChanged,
    UserRejected,
    Protocol,
    Permission,
    RetryBudgetExhausted,
    Io,
    /// The peer restarted its runtime and replaced the logical Session.
    SessionReplaced,
}

/// 与具体 Connection 无关的文件传输状态机。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransferState {
    Offering,
    WaitingApproval,
    Transferring,
    Paused,
    Resuming,
    Verifying,
    Completed,
    Cancelled,
    Failed(TransferFailureReason),
}

/// 文件传输的业务会话。这里刻意不保存 quinn::Connection、Relay socket
/// 或其他 Route handle；这些资源只属于当前一次 TransferDispatcher 尝试。
pub struct TransferSession {
    pub transfer_id: String,
    pub peer_id: String,
    /// 由 network-core 的逻辑 SessionId 编码而来；Connection 更换时保持不变。
    pub session_id: String,
    pub manifest: FileManifest,
    pub bytes_transferred: u64,
    pub state: TransferState,
    pub cancellation: TransferCancellation,
    pub source_path: Option<PathBuf>,
}

/// 可交给 Route Dispatcher 重新协商的一次出站传输尝试。
#[derive(Clone, Debug)]
pub struct ResumableTransfer {
    pub transfer_id: String,
    pub peer_id: String,
    pub session_id: String,
    pub source_path: PathBuf,
    pub manifest: FileManifest,
    pub offset: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransferSnapshot {
    pub transfer_id: String,
    pub peer_id: String,
    pub session_id: String,
    pub bytes_transferred: u64,
    pub state: TransferState,
}

#[derive(Clone)]
pub struct TransferManager {
    transfers: Arc<RwLock<HashMap<String, TransferSession>>>,
}

impl Default for TransferManager {
    fn default() -> Self {
        Self::new()
    }
}

impl TransferManager {
    pub fn new() -> Self {
        Self {
            transfers: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// 注册一个等待用户审批的接收会话。
    ///
    /// 如果之前的同一 Session 仅因网络断开而暂停，则重新收到相同 manifest
    /// 时复用业务会话，而不是创建第二个 TransferId。
    pub async fn register_incoming(
        &self,
        manifest: FileManifest,
        peer_id: String,
        session_id: String,
    ) -> bool {
        let id = manifest.transfer_id.clone();
        let mut transfers = self.transfers.write().await;
        match transfers.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(Self::new_session(
                    manifest,
                    peer_id,
                    session_id,
                    None,
                    TransferState::WaitingApproval,
                ));
                true
            }
            Entry::Occupied(mut entry) => {
                let item = entry.get_mut();
                if item.state == TransferState::Paused
                    && item.peer_id == peer_id
                    && item.session_id == session_id
                    && item.manifest == manifest
                {
                    item.state = TransferState::WaitingApproval;
                    true
                } else {
                    false
                }
            }
        }
    }

    /// 原子领取同一逻辑 Session 的暂停接收传输。
    ///
    /// Relay 重新 Offer 时会携带新的 socket token，但业务 TransferId、Manifest
    /// 和逻辑 SessionId 必须保持一致；只有满足这三个条件才允许跳过再次审批。
    pub async fn claim_incoming_resume(
        &self,
        manifest: &FileManifest,
        peer_id: &str,
        session_id: &str,
    ) -> Option<u64> {
        let mut transfers = self.transfers.write().await;
        let item = transfers.get_mut(&manifest.transfer_id)?;
        if item.state == TransferState::Paused
            && item.peer_id == peer_id
            && item.session_id == session_id
            && item.manifest == *manifest
        {
            item.state = TransferState::Resuming;
            Some(item.bytes_transferred)
        } else {
            None
        }
    }

    /// 注册出站传输；Route handle 不进入 TransferSession。
    pub async fn register_outgoing(
        &self,
        manifest: FileManifest,
        source_path: PathBuf,
        peer_id: String,
        session_id: String,
    ) -> bool {
        let id = manifest.transfer_id.clone();
        let mut transfers = self.transfers.write().await;
        match transfers.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(Self::new_session(
                    manifest,
                    peer_id,
                    session_id,
                    Some(source_path),
                    TransferState::Offering,
                ));
                true
            }
            Entry::Occupied(_) => false,
        }
    }

    /// 进入传输态；只允许从业务层定义的非终态进入，防止旧 Route 的收尾
    /// 任务把已经完成或取消的 Transfer 改回 Active。
    pub async fn mark_transferring(&self, transfer_id: &str) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Offering | TransferState::WaitingApproval | TransferState::Resuming
        ) {
            item.state = TransferState::Transferring;
            return true;
        }
        false
    }

    pub async fn mark_verifying(&self, transfer_id: &str) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if item.state == TransferState::Transferring {
            item.state = TransferState::Verifying;
            return true;
        }
        false
    }

    pub async fn mark_completed(&self, transfer_id: &str) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Transferring | TransferState::Verifying
        ) {
            item.state = TransferState::Completed;
            return true;
        }
        false
    }

    /// 更新业务偏移，不绑定任何 transport stream。
    pub async fn update_progress(&self, transfer_id: &str, bytes: u64) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Offering
                | TransferState::WaitingApproval
                | TransferState::Transferring
                | TransferState::Resuming
                | TransferState::Verifying
        ) {
            item.bytes_transferred = bytes;
            return true;
        }
        false
    }

    /// 网络错误只暂停业务会话；源文件、Manifest、SessionId 和偏移都保留。
    pub async fn pause_for_network(&self, transfer_id: &str) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Offering
                | TransferState::WaitingApproval
                | TransferState::Transferring
                | TransferState::Resuming
                | TransferState::Verifying
        ) {
            item.state = TransferState::Paused;
            return true;
        }
        false
    }

    /// 只有明确的业务/协议错误才进入 Failed。
    pub async fn fail_transfer(&self, transfer_id: &str, reason: TransferFailureReason) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Completed | TransferState::Cancelled | TransferState::Failed(_)
        ) {
            return false;
        }
        item.state = TransferState::Failed(reason);
        true
    }

    /// 用户取消是独立终态，不能被后续 Route Ready 任务重新领取。
    pub async fn cancel_transfer(&self, transfer_id: &str) -> bool {
        let mut transfers = self.transfers.write().await;
        let Some(item) = transfers.get_mut(transfer_id) else {
            return false;
        };
        if matches!(
            item.state,
            TransferState::Completed | TransferState::Cancelled | TransferState::Failed(_)
        ) {
            return false;
        }
        item.cancellation.cancel();
        item.state = TransferState::Cancelled;
        info!("Cancelled transfer {}", transfer_id);
        true
    }

    /// 原子地领取同一逻辑 Session 的暂停传输，避免新的 Route 重复发送。
    pub async fn take_resumable_for_session(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Vec<ResumableTransfer> {
        let mut transfers = self.transfers.write().await;
        transfers
            .values_mut()
            .filter_map(|item| {
                if item.state != TransferState::Paused
                    || item.peer_id != peer_id
                    || item.session_id != session_id
                {
                    return None;
                }
                let source_path = item.source_path.clone()?;
                item.state = TransferState::Resuming;
                Some(ResumableTransfer {
                    transfer_id: item.transfer_id.clone(),
                    peer_id: item.peer_id.clone(),
                    session_id: item.session_id.clone(),
                    source_path,
                    manifest: item.manifest.clone(),
                    offset: item.bytes_transferred,
                })
            })
            .collect()
    }

    pub async fn is_cancelled(&self, transfer_id: &str) -> bool {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .is_some_and(|item| item.state == TransferState::Cancelled)
    }

    pub async fn cancellation_token(&self, transfer_id: &str) -> Option<TransferCancellation> {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .map(|item| item.cancellation.clone())
    }

    /// Terminate every non-terminal transfer bound to a replaced logical
    /// Session. Session replacement is not a route migration: these business
    /// sessions must not be claimed by the new Session.
    pub async fn terminate_session_transfers(
        &self,
        peer_id: &str,
        session_id: &str,
        reason: TransferFailureReason,
    ) -> Vec<TransferSnapshot> {
        let mut transfers = self.transfers.write().await;
        let mut terminated = Vec::new();
        transfers.retain(|_, item| {
            if item.peer_id != peer_id || item.session_id != session_id {
                return true;
            }
            if !matches!(
                item.state,
                TransferState::Completed | TransferState::Cancelled | TransferState::Failed(_)
            ) {
                item.cancellation.cancel();
                terminated.push(TransferSnapshot {
                    transfer_id: item.transfer_id.clone(),
                    peer_id: item.peer_id.clone(),
                    session_id: item.session_id.clone(),
                    bytes_transferred: item.bytes_transferred,
                    state: TransferState::Failed(reason),
                });
            }
            false
        });
        terminated
    }

    pub async fn snapshot(&self, transfer_id: &str) -> Option<TransferSnapshot> {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .map(|item| TransferSnapshot {
                transfer_id: item.transfer_id.clone(),
                peer_id: item.peer_id.clone(),
                session_id: item.session_id.clone(),
                bytes_transferred: item.bytes_transferred,
                state: item.state.clone(),
            })
    }

    pub async fn remove_transfer(&self, transfer_id: &str) {
        self.transfers.write().await.remove(transfer_id);
    }

    fn new_session(
        manifest: FileManifest,
        peer_id: String,
        session_id: String,
        source_path: Option<PathBuf>,
        state: TransferState,
    ) -> TransferSession {
        TransferSession {
            transfer_id: manifest.transfer_id.clone(),
            peer_id,
            session_id,
            manifest,
            bytes_transferred: 0,
            state,
            cancellation: TransferCancellation::default(),
            source_path,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::NETWORK_TRANSFER_PROTOCOL_VERSION;

    fn manifest(id: &str) -> FileManifest {
        FileManifest {
            transfer_id: id.into(),
            file_name: "payload.bin".into(),
            file_size: 4,
            modified_at: 0,
            content_hash: "00".repeat(32),
            protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
        }
    }

    #[tokio::test]
    async fn network_pause_preserves_session_and_can_be_claimed_once() {
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-1"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
                    "0000000000000001".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-1").await);
        assert!(manager.update_progress("transfer-1", 2).await);
        assert!(manager.pause_for_network("transfer-1").await);
        assert_eq!(
            manager.snapshot("transfer-1").await.unwrap().state,
            TransferState::Paused
        );
        let resumed = manager
            .take_resumable_for_session("peer-b", "0000000000000001")
            .await;
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].offset, 2);
        assert_eq!(resumed[0].session_id, "0000000000000001");
        assert!(manager
            .take_resumable_for_session("peer-b", "0000000000000001")
            .await
            .is_empty());
    }

    #[tokio::test]
    async fn replacement_session_terminates_old_transfer() {
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-2"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
                    "0000000000000001".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-2").await);
        assert!(manager.pause_for_network("transfer-2").await);
        assert!(manager
            .take_resumable_for_session("peer-b", "0000000000000002")
            .await
            .is_empty());
        let cancellation = manager
            .cancellation_token("transfer-2")
            .await
            .expect("transfer cancellation token");
        let terminated = manager
            .terminate_session_transfers(
                "peer-b",
                "0000000000000001",
                TransferFailureReason::SessionReplaced,
            )
            .await;
        assert_eq!(terminated.len(), 1);
        assert_eq!(
            terminated[0].state,
            TransferState::Failed(TransferFailureReason::SessionReplaced)
        );
        assert!(cancellation.is_cancelled());
        assert!(manager.snapshot("transfer-2").await.is_none());
    }

    #[tokio::test]
    async fn incoming_paused_session_is_reused_only_for_same_manifest() {
        let manager = TransferManager::new();
        let first = manifest("transfer-3");
        assert!(
            manager
                .register_incoming(first.clone(), "peer-b".into(), "0000000000000001".into(),)
                .await
        );
        assert!(manager.mark_transferring("transfer-3").await);
        assert!(manager.pause_for_network("transfer-3").await);
        assert!(
            manager
                .register_incoming(first, "peer-b".into(), "0000000000000001".into(),)
                .await
        );
        assert_eq!(
            manager.snapshot("transfer-3").await.unwrap().state,
            TransferState::WaitingApproval
        );
        assert!(
            !manager
                .register_incoming(
                    FileManifest {
                        file_name: "different.bin".into(),
                        ..manifest("transfer-3")
                    },
                    "peer-b".into(),
                    "0000000000000001".into(),
                )
                .await
        );
    }

    #[tokio::test]
    async fn incoming_resume_claim_keeps_offset_and_rejects_wrong_binding() {
        let manager = TransferManager::new();
        let file_manifest = manifest("transfer-resume");
        assert!(
            manager
                .register_incoming(
                    file_manifest.clone(),
                    "peer-b".into(),
                    "0000000000000001".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-resume").await);
        assert!(manager.update_progress("transfer-resume", 2).await);
        assert!(manager.pause_for_network("transfer-resume").await);
        assert_eq!(
            manager
                .claim_incoming_resume(&file_manifest, "peer-b", "0000000000000001",)
                .await,
            Some(2)
        );
        assert!(manager
            .claim_incoming_resume(&file_manifest, "peer-b", "0000000000000002")
            .await
            .is_none());
    }

    #[tokio::test]
    async fn terminal_state_cannot_be_rewritten_by_old_route() {
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-4"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
                    "0000000000000001".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-4").await);
        assert!(manager.mark_verifying("transfer-4").await);
        assert!(manager.mark_completed("transfer-4").await);
        assert!(!manager.pause_for_network("transfer-4").await);
        assert!(
            !manager
                .fail_transfer("transfer-4", TransferFailureReason::Io)
                .await
        );
        assert_eq!(
            manager.snapshot("transfer-4").await.unwrap().state,
            TransferState::Completed
        );
    }
}
