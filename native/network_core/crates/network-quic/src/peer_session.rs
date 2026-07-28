use std::sync::atomic::{AtomicBool, Ordering};
use quinn::Connection;
use tracing::info;
use network_identity::DeviceIdentity;

pub struct QuicPeerSession {
    pub connection: Connection,
    pub peer_device_id: String,
    pub authenticated: AtomicBool,
}

impl QuicPeerSession {
    pub fn new(connection: Connection, peer_device_id: String) -> Self {
        Self {
            connection,
            peer_device_id,
            authenticated: AtomicBool::new(false),
        }
    }

    pub fn is_authenticated(&self) -> bool {
        self.authenticated.load(Ordering::SeqCst)
    }

    /// Performs application-layer handshake (Device ID, nonce, signature).
    pub async fn perform_handshake(
        &self,
        local_identity: &DeviceIdentity,
    ) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        let (mut send, mut recv) = self.connection.open_bi().await?;

        // Send local device_id and proof
        let nonce = rand::random::<[u8; 32]>();
        let signature = local_identity.sign_proof(&nonce);

        send.write_all(local_identity.device_id.as_bytes()).await?;
        send.write_all(&nonce).await?;
        send.write_all(&signature).await?;
        send.finish()?;

        // Receive peer verification result
        let mut resp_buf = [0u8; 1];
        recv.read_exact(&mut resp_buf).await?;

        let success = resp_buf[0] == 1;
        if success {
            self.authenticated.store(true, Ordering::SeqCst);
            info!("Peer {} authenticated successfully over QUIC", self.peer_device_id);
        }

        Ok(success)
    }
}
