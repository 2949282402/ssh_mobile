use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;
use crate::manifest::FileManifest;

pub enum TransferStatus {
    Offering,
    Active,
    Completed,
    Failed(String),
    Cancelled,
}

pub struct ActiveTransfer {
    pub manifest: FileManifest,
    pub bytes_transferred: u64,
    pub status: TransferStatus,
}

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

    pub async fn register_transfer(&self, manifest: FileManifest) {
        let id = manifest.transfer_id.clone();
        let item = ActiveTransfer {
            manifest,
            bytes_transferred: 0,
            status: TransferStatus::Offering,
        };
        self.transfers.write().await.insert(id, item);
    }

    pub async fn update_progress(&self, transfer_id: &str, bytes: u64) {
        if let Some(item) = self.transfers.write().await.get_mut(transfer_id) {
            item.bytes_transferred = bytes;
            item.status = TransferStatus::Active;
        }
    }

    pub async fn cancel_transfer(&self, transfer_id: &str) -> bool {
        if let Some(item) = self.transfers.write().await.get_mut(transfer_id) {
            item.status = TransferStatus::Cancelled;
            info!("Cancelled transfer {}", transfer_id);
            true
        } else {
            false
        }
    }
}
