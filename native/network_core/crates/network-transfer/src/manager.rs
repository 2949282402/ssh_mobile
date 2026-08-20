use crate::cancellation::TransferCancellation;
use crate::manifest::FileManifest;
use std::collections::{hash_map::Entry, HashMap};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

/// 传输失败的稳定原因。网络断开不属于这里的终态错误，而是进入
/// [`TransferState::Paused`]，等待下一次 ConnectionSession 的 ResumeTransfer。
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

/// 文件传输的业务操作（transport-network v2 §19）。
///
/// 真正跨连接保存的是 `transfer_id + peer_id + manifest_hash + total_size +
/// confirmed_offset`；这里刻意**不**保存 SessionId / Connection / Relay socket——
/// 那些只属于当前一次 Route 尝试，由 network-core 的 TransferDispatcher 在派发时
/// 从当前 ConnectionSession 附加。连接断开时本会话进入 [`TransferState::Paused`]，
/// 而 ConnectionSession 被销毁；业务状态保留在本结构体中，等待新连接上的
/// `ResumeTransfer(transfer_id)` 恢复。
pub struct TransferSession {
    pub transfer_id: String,
    pub peer_id: String,
    /// 携带 `manifest_hash`（= `content_hash`）与 `total_size`（= `file_size`）。
    pub manifest: FileManifest,
    /// 已与对端协商确认的写入偏移（checkpoint）。Connection 更换后重新协商时作为
    /// 本端 `confirmed_offset`。
    pub confirmed_offset: u64,
    pub state: TransferState,
    pub cancellation: TransferCancellation,
    pub source_path: Option<PathBuf>,
}

/// 可交给 Route Dispatcher 重新协商的一次出站传输尝试。
///
/// `session_id` **不是**持久化的业务键：它由 network-core 在派发时从当前
/// ConnectionSession 附加（用于 Relay E2EE 与任务分组），Connection 更换后会用
/// 新 Session 的 wire key 重新编码（§18 新 Noise root）。
#[derive(Clone, Debug)]
pub struct ResumableTransfer {
    pub transfer_id: String,
    pub peer_id: String,
    pub session_id: String,
    pub source_path: PathBuf,
    pub manifest: FileManifest,
    /// 本端已确认的 checkpoint；与对端协商后可能被更新。
    pub offset: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransferSnapshot {
    pub transfer_id: String,
    pub peer_id: String,
    pub confirmed_offset: u64,
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
    /// 如果同一 Peer 仅因网络断开而暂停（§19），则重新收到相同 manifest 时复用
    /// 业务会话，而不是创建第二个 TransferId。
    pub async fn register_incoming(&self, manifest: FileManifest, peer_id: String) -> bool {
        let id = manifest.transfer_id.clone();
        let mut transfers = self.transfers.write().await;
        match transfers.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(Self::new_session(
                    manifest,
                    peer_id,
                    None,
                    TransferState::WaitingApproval,
                ));
                true
            }
            Entry::Occupied(mut entry) => {
                let item = entry.get_mut();
                if item.state == TransferState::Paused
                    && item.peer_id == peer_id
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

    /// 原子领取同一 Peer 的暂停接收传输（§19：按 transfer_id + peer_id）。
    ///
    /// Relay 重新 Offer 时会携带新的 socket/session token，但业务 TransferId、
    /// Manifest 和 Peer 必须保持一致；只有满足这三个条件才允许跳过再次审批。
    pub async fn claim_incoming_resume(
        &self,
        manifest: &FileManifest,
        peer_id: &str,
    ) -> Option<u64> {
        let mut transfers = self.transfers.write().await;
        let item = transfers.get_mut(&manifest.transfer_id)?;
        if item.state == TransferState::Paused
            && item.peer_id == peer_id
            && item.manifest == *manifest
        {
            item.state = TransferState::Resuming;
            Some(item.confirmed_offset)
        } else {
            None
        }
    }

    /// 注册出站传输；Route handle 与 SessionId 不进入 TransferSession。
    pub async fn register_outgoing(
        &self,
        manifest: FileManifest,
        source_path: PathBuf,
        peer_id: String,
    ) -> bool {
        let id = manifest.transfer_id.clone();
        let mut transfers = self.transfers.write().await;
        match transfers.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(Self::new_session(
                    manifest,
                    peer_id,
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

    /// 更新已确认的业务偏移，不绑定任何 transport stream。
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
            item.confirmed_offset = bytes;
            return true;
        }
        false
    }

    /// 网络错误只暂停业务会话；源文件、Manifest、Peer 和偏移都保留。
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

    /// 原子地领取同一 Peer 的暂停传输，避免新的 Route 重复发送（§19）。
    ///
    /// 匹配只按 `peer_id` 与 `Paused` 状态进行；`session_id` 仅作为派发时附加的
    /// crypto/task 键，由调用方从当前 ConnectionSession 传入，**不参与匹配**——
    /// Connection 更换后必须用新 Session 的 wire key 重新编码。
    pub async fn take_resumable_for_peer(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Vec<ResumableTransfer> {
        let mut transfers = self.transfers.write().await;
        transfers
            .values_mut()
            .filter_map(|item| {
                if item.state != TransferState::Paused || item.peer_id != peer_id {
                    return None;
                }
                let source_path = item.source_path.clone()?;
                item.state = TransferState::Resuming;
                Some(ResumableTransfer {
                    transfer_id: item.transfer_id.clone(),
                    peer_id: item.peer_id.clone(),
                    session_id: session_id.to_string(),
                    source_path,
                    manifest: item.manifest.clone(),
                    offset: item.confirmed_offset,
                })
            })
            .collect()
    }

    /// transport-network v2（§19）：ConnectionSession 销毁（transport 丢失 / 显式
    /// 断开 / 被新连接替换）时把该 Peer 所有非终态传输置为 `Paused`。业务状态保留
    /// 在 TransferManager，等待下一次连接上的 `ResumeTransfer(transfer_id)` 恢复。
    ///
    /// 返回被暂停的 transfer_id 列表，供调用方诊断/事件使用。
    pub async fn pause_peer_transfers(&self, peer_id: &str) -> Vec<String> {
        let mut transfers = self.transfers.write().await;
        let mut paused = Vec::new();
        for item in transfers.values_mut() {
            if item.peer_id != peer_id {
                continue;
            }
            if matches!(
                item.state,
                TransferState::Offering
                    | TransferState::WaitingApproval
                    | TransferState::Transferring
                    | TransferState::Resuming
                    | TransferState::Verifying
            ) {
                item.state = TransferState::Paused;
                paused.push(item.transfer_id.clone());
            }
        }
        paused
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

    pub async fn snapshot(&self, transfer_id: &str) -> Option<TransferSnapshot> {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .map(|item| TransferSnapshot {
                transfer_id: item.transfer_id.clone(),
                peer_id: item.peer_id.clone(),
                confirmed_offset: item.confirmed_offset,
                state: item.state.clone(),
            })
    }

    /// Count non-terminal transfer identities for one peer.  Diagnostics use
    /// this owner-backed view instead of inferring activity from transport
    /// sessions or Relay waiter maps.
    pub async fn active_count_for_peer(&self, peer_id: &str) -> u32 {
        self.transfers
            .read()
            .await
            .values()
            .filter(|item| {
                item.peer_id == peer_id
                    && !matches!(
                        item.state,
                        TransferState::Completed
                            | TransferState::Cancelled
                            | TransferState::Failed(_)
                    )
            })
            .count()
            .min(u32::MAX as usize) as u32
    }

    pub async fn active_ids_for_peer(&self, peer_id: &str) -> Vec<String> {
        self.transfers
            .read()
            .await
            .values()
            .filter(|item| {
                item.peer_id == peer_id
                    && !matches!(
                        item.state,
                        TransferState::Completed
                            | TransferState::Cancelled
                            | TransferState::Failed(_)
                    )
            })
            .map(|item| item.transfer_id.clone())
            .collect()
    }

    pub async fn remove_transfer(&self, transfer_id: &str) {
        self.transfers.write().await.remove(transfer_id);
    }

    fn new_session(
        manifest: FileManifest,
        peer_id: String,
        source_path: Option<PathBuf>,
        state: TransferState,
    ) -> TransferSession {
        TransferSession {
            transfer_id: manifest.transfer_id.clone(),
            peer_id,
            manifest,
            confirmed_offset: 0,
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
    async fn network_pause_preserves_peer_and_can_be_claimed_once() {
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-1"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
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
        // §19：恢复按 Peer 领取；session_id 只是派发时附加的 crypto/task 键，
        // 不参与匹配——新 ConnectionSession 用新 wire key 重新编码。
        let resumed = manager
            .take_resumable_for_peer("peer-b", "0000000000000002")
            .await;
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].offset, 2);
        assert_eq!(resumed[0].session_id, "0000000000000002");
        assert!(manager
            .take_resumable_for_peer("peer-b", "0000000000000002")
            .await
            .is_empty());
    }

    #[tokio::test]
    async fn paused_transfer_survives_session_replacement_and_resumes_by_peer() {
        // §19：ConnectionSession 被替换（新连接）不是终态；TransferOperation 保留
        // 并按 transfer_id + peer_id 恢复，而不是按 SessionId 终止。
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-2"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-2").await);
        assert!(manager.update_progress("transfer-2", 3).await);
        // 旧 ConnectionSession 销毁 → Paused。
        assert!(manager.pause_for_network("transfer-2").await);
        let paused_ids = manager.pause_peer_transfers("peer-b").await;
        assert!(
            paused_ids.is_empty(),
            "already-paused transfer is not re-paused"
        );
        // 新 ConnectionSession（不同 wire key）通过 Peer 领取并恢复。
        let resumed = manager
            .take_resumable_for_peer("peer-b", "0000000000000002")
            .await;
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].offset, 3);
        assert_eq!(resumed[0].session_id, "0000000000000002");
        // 恢复后旧状态不再是 Paused。
        assert_eq!(
            manager.snapshot("transfer-2").await.unwrap().state,
            TransferState::Resuming
        );
    }

    #[tokio::test]
    async fn session_destruction_pauses_active_transfers() {
        let manager = TransferManager::new();
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-pause-all"),
                    PathBuf::from("source.bin"),
                    "peer-b".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-pause-all").await);
        assert!(manager.update_progress("transfer-pause-all", 1).await);
        let paused_ids = manager.pause_peer_transfers("peer-b").await;
        assert_eq!(paused_ids, vec!["transfer-pause-all".to_string()]);
        assert_eq!(
            manager.snapshot("transfer-pause-all").await.unwrap().state,
            TransferState::Paused
        );
        // 其他 Peer 的传输不受影响。
        assert!(
            manager
                .register_outgoing(
                    manifest("transfer-other-peer"),
                    PathBuf::from("source.bin"),
                    "peer-c".into(),
                )
                .await
        );
        assert!(manager.mark_transferring("transfer-other-peer").await);
        assert!(manager.pause_peer_transfers("peer-b").await.is_empty());
        assert_eq!(
            manager.snapshot("transfer-other-peer").await.unwrap().state,
            TransferState::Transferring
        );
    }

    #[tokio::test]
    async fn incoming_paused_transfer_is_reused_only_for_same_peer_and_manifest() {
        let manager = TransferManager::new();
        let first = manifest("transfer-3");
        assert!(
            manager
                .register_incoming(first.clone(), "peer-b".into(),)
                .await
        );
        assert!(manager.mark_transferring("transfer-3").await);
        assert!(manager.pause_for_network("transfer-3").await);
        // 同一 Peer + 同一 Manifest → 复用并回到 WaitingApproval。
        assert!(manager.register_incoming(first, "peer-b".into(),).await);
        assert_eq!(
            manager.snapshot("transfer-3").await.unwrap().state,
            TransferState::WaitingApproval
        );
        // 同一 TransferId 但不同 Manifest → 拒绝复用（业务身份不匹配）。
        assert!(
            !manager
                .register_incoming(
                    FileManifest {
                        file_name: "different.bin".into(),
                        ..manifest("transfer-3")
                    },
                    "peer-b".into(),
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
                .register_incoming(file_manifest.clone(), "peer-b".into(),)
                .await
        );
        assert!(manager.mark_transferring("transfer-resume").await);
        assert!(manager.update_progress("transfer-resume", 2).await);
        assert!(manager.pause_for_network("transfer-resume").await);
        assert_eq!(
            manager
                .claim_incoming_resume(&file_manifest, "peer-b",)
                .await,
            Some(2)
        );
        // 不同 Peer → 拒绝；TransferOperation 保持 Paused，可再被正确 Peer 领取。
        assert!(manager
            .claim_incoming_resume(&file_manifest, "peer-c")
            .await
            .is_none());
        assert!(manager
            .claim_incoming_resume(&file_manifest, "peer-b")
            .await
            .is_none());
    }

    #[tokio::test]
    async fn checkpoint_mismatch_keeps_transfer_paused() {
        // §40 失败场景：ResumeTransfer 协商出的 checkpoint 与对端不一致时，恢复被
        // 拒绝，TransferOperation 必须留在 Paused（干净失败，不能继续发送）。
        let manager = TransferManager::new();
        let file_manifest = manifest("transfer-checkpoint");
        assert!(
            manager
                .register_incoming(file_manifest.clone(), "peer-b".into(),)
                .await
        );
        assert!(manager.mark_transferring("transfer-checkpoint").await);
        assert!(manager.update_progress("transfer-checkpoint", 5).await);
        assert!(manager.pause_for_network("transfer-checkpoint").await);
        // 对端以不同 Manifest 来恢复（checkpoint 所属业务身份不匹配）→ None。
        let mismatched = FileManifest {
            file_size: 99,
            ..file_manifest.clone()
        };
        assert!(manager
            .claim_incoming_resume(&mismatched, "peer-b")
            .await
            .is_none());
        assert_eq!(
            manager.snapshot("transfer-checkpoint").await.unwrap().state,
            TransferState::Paused
        );
        // 恢复仍可被正确 Manifest 领取，checkpoint（confirmed_offset）不变。
        assert_eq!(
            manager
                .claim_incoming_resume(&file_manifest, "peer-b")
                .await,
            Some(5)
        );
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
