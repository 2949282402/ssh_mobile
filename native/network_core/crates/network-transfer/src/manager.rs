use crate::cancellation::TransferCancellation;
use crate::manifest::FileManifest;
use std::collections::{hash_map::Entry, HashMap};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

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
    pub cancellation: TransferCancellation,
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

    pub async fn register_transfer(&self, manifest: FileManifest) -> bool {
        let id = manifest.transfer_id.clone();
        let item = ActiveTransfer {
            manifest,
            bytes_transferred: 0,
            status: TransferStatus::Offering,
            cancellation: TransferCancellation::default(),
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
            item.status = TransferStatus::Active;
        }
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
