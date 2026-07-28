use std::net::SocketAddr;
use std::sync::Arc;
use quinn::{Endpoint, ServerConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tracing::info;
use network_nat::PathManager;

pub const QUIC_ALPN_V1: &[&[u8]] = &[b"ssh-mobile/1"];

pub struct QuicEndpointManager {
    pub endpoint: Endpoint,
    pub path_manager: Arc<PathManager>,
}

impl QuicEndpointManager {
    pub fn new(bind_addr: SocketAddr, path_manager: Arc<PathManager>) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let cert = rcgen::generate_simple_self_signed(vec!["ssh-mobile".to_string()])?;
        let cert_der = cert.cert.der().to_vec();
        let key_der = cert.key_pair.serialize_der();

        let mut server_crypto = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert_der)],
                PrivateKeyDer::Pkcs8(key_der.into()),
            )?;
        server_crypto.alpn_protocols = QUIC_ALPN_V1.iter().map(|s| s.to_vec()).collect();

        let server_config = ServerConfig::with_crypto(Arc::new(quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto)?));
        let endpoint = Endpoint::server(server_config, bind_addr)?;

        info!("QuicEndpointManager bound on {}", bind_addr);

        Ok(Self {
            endpoint,
            path_manager,
        })
    }
}
