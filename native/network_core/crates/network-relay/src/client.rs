use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

pub struct RelayClient {
    pub relay_url: String,
    pub session_id: Option<String>,
    pub is_connected: Arc<RwLock<bool>>,
}

impl RelayClient {
    pub fn new(relay_url: String) -> Self {
        Self {
            relay_url,
            session_id: None,
            is_connected: Arc::new(RwLock::new(false)),
        }
    }

    pub async fn connect_session(&mut self, session_id: String) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.session_id = Some(session_id.clone());
        let mut connected = self.is_connected.write().await;
        *connected = true;
        info!("RelayClient connected session: {} via {}", session_id, self.relay_url);
        Ok(())
    }

    pub async fn forward_opaque_payload(&self, ciphertext: &[u8]) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
        if !*self.is_connected.read().await {
            return Err("Relay not connected".into());
        }
        info!("Forwarding {} opaque ciphertext bytes over Relay", ciphertext.len());
        Ok(ciphertext.len())
    }

    pub async fn disconnect(&mut self) {
        let mut connected = self.is_connected.write().await;
        *connected = false;
        self.session_id = None;
        info!("RelayClient session closed");
    }
}
