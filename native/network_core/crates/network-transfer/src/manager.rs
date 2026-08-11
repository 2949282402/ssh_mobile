use crate::cancellation::TransferCancellation;
use crate::manifest::FileManifest;
use std::collections::{hash_map::Entry, HashMap};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

#[derive(Debug, PartialEq, Eq)]
pub enum TransferStatus {
    Offering,
    Active,
    Paused,
    Completed,
    Failed(String),
    Cancelled,
}

pub struct ActiveTransfer {
    pub manifest: FileManifest,
    pub bytes_transferred: u64,
    pub status: TransferStatus,
    pub cancellation: TransferCancellation,
    pub source_path: Option<PathBuf>,
    pub peer_id: Option<String>,
}

/// 描述一个可在新 Connection 上重新协商的出站文件传输。
#[derive(Clone, Debug)]
pub struct ResumableTransfer {
    pub transfer_id: String,
    pub peer_id: String,
    pub source_path: PathBuf,
    pub manifest: FileManifest,
}

#[derive(Clone)]
pub struct TransferManager {
    transfers: Arc<RwLock<HashMap<String, ActiveTransfer>>>,
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

    pub async fn register_transfer(&self, manifest: FileManifest) -> bool {
        let id = manifest.transfer_id.clone();
        let item = ActiveTransfer {
            manifest,
            bytes_transferred: 0,
            status: TransferStatus::Offering,
            cancellation: TransferCancellation::default(),
            source_path: None,
            peer_id: None,
        };
        match self.transfers.write().await.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(item);
                true
            }
            Entry::Occupied(_) => false,
        }
    }

    /// 注册带源文件和目标对端信息的出站传输，使断线后可以恢复。
    pub async fn register_outgoing(
        &self,
        manifest: FileManifest,
        source_path: PathBuf,
        peer_id: String,
    ) -> bool {
        let id = manifest.transfer_id.clone();
        let item = ActiveTransfer {
            manifest,
            bytes_transferred: 0,
            status: TransferStatus::Offering,
            cancellation: TransferCancellation::default(),
            source_path: Some(source_path),
            peer_id: Some(peer_id),
        };
        match self.transfers.write().await.entry(id) {
            Entry::Vacant(entry) => {
                entry.insert(item);
                true
            }
            Entry::Occupied(_) => false,
        }
    }

    pub async fn update_progress(&self, transfer_id: &str, bytes: u64) {
        if let Some(item) = self.transfers.write().await.get_mut(transfer_id) {
            item.bytes_transferred = bytes;
            if !matches!(
                item.status,
                TransferStatus::Cancelled | TransferStatus::Completed
            ) {
                item.status = TransferStatus::Active;
            }
        }
    }

    /// 暂停传输但保留 TransferId、源文件和已知进度，等待新 Connection。
    pub async fn pause_transfer(&self, transfer_id: &str) -> bool {
        if let Some(item) = self.transfers.write().await.get_mut(transfer_id) {
            if !matches!(
                item.status,
                TransferStatus::Cancelled | TransferStatus::Completed
            ) {
                item.status = TransferStatus::Paused;
                return true;
            }
        }
        false
    }

    /// 原子地领取一个 Peer 的暂停传输，避免多个 Route Ready 事件重复发送。
    pub async fn take_resumable_for_peer(&self, peer_id: &str) -> Vec<ResumableTransfer> {
        let mut transfers = self.transfers.write().await;
        transfers
            .values_mut()
            .filter_map(|item| {
                if item.status != TransferStatus::Paused || item.peer_id.as_deref() != Some(peer_id)
                {
                    return None;
                }
                let source_path = item.source_path.clone()?;
                item.status = TransferStatus::Offering;
                Some(ResumableTransfer {
                    transfer_id: item.manifest.transfer_id.clone(),
                    peer_id: peer_id.to_string(),
                    source_path,
                    manifest: item.manifest.clone(),
                })
            })
            .collect()
    }

    pub async fn is_cancelled(&self, transfer_id: &str) -> bool {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .is_some_and(|item| item.status == TransferStatus::Cancelled)
    }

    pub async fn cancel_transfer(&self, transfer_id: &str) -> bool {
        if let Some(item) = self.transfers.write().await.get_mut(transfer_id) {
            item.cancellation.cancel();
            item.status = TransferStatus::Cancelled;
            info!("Cancelled transfer {}", transfer_id);
            true
        } else {
            false
        }
    }

    pub async fn cancellation_token(&self, transfer_id: &str) -> Option<TransferCancellation> {
        self.transfers
            .read()
            .await
            .get(transfer_id)
            .map(|item| item.cancellation.clone())
    }

    pub async fn remove_transfer(&self, transfer_id: &str) {
        self.transfers.write().await.remove(transfer_id);
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
    async fn paused_outgoing_transfer_can_be_claimed_once_for_resume() {
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
        manager.update_progress("transfer-1", 2).await;
        assert!(manager.pause_transfer("transfer-1").await);
        let resumed = manager.take_resumable_for_peer("peer-b").await;
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].manifest.transfer_id, "transfer-1");
        assert_eq!(resumed[0].source_path, PathBuf::from("source.bin"));
        assert!(manager.take_resumable_for_peer("peer-b").await.is_empty());
    }
}
