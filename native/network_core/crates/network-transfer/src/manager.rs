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
#[path = "tests/manager.rs"]
mod tests;
