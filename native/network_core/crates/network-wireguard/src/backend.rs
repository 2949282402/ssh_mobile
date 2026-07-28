use std::net::SocketAddr;

#[derive(Debug, Clone)]
pub struct PeerConfig {
    pub public_key: String,
    pub endpoint: Option<SocketAddr>,
    pub allowed_ips: Vec<String>,
    pub persistent_keepalive: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct TunnelConfig {
    pub interface_name: String,
    pub private_key: String,
    pub address_v4: String,
    pub address_v6: Option<String>,
    pub listen_port: u16,
    pub peers: Vec<PeerConfig>,
}

pub type TunnelHandle = u64;

#[derive(Debug, thiserror::Error)]
pub enum WireGuardError {
    #[error("Failed to start WireGuard tunnel: {0}")]
    StartFailed(String),
    #[error("Failed to update peer: {0}")]
    PeerUpdateFailed(String),
    #[error("Failed to stop tunnel: {0}")]
    StopFailed(String),
}

pub trait WireGuardBackend: Send + Sync {
    fn start(&self, config: TunnelConfig) -> Result<TunnelHandle, WireGuardError>;
    fn update_peer(&self, handle: TunnelHandle, peer: PeerConfig) -> Result<(), WireGuardError>;
    fn stop(&self, handle: TunnelHandle) -> Result<(), WireGuardError>;
}
