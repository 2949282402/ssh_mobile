//! Application authentication for non-QUIC Session routes.
//!
//! TCP and WebSocket establish a socket, not a trusted peer. The route is
//! admitted only after the Noise XX application handshake proves the pinned
//! Ed25519 identity and binds the logical Session. The same handshake returns
//! the forward-secret Session root used by application E2EE.

use network_identity::DeviceIdentity;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::connection::GenericConnection;
use crate::crypto_handshake::{
    initiate_generic, respond_generic, CryptoHandshakeError, SessionCryptoMaterial,
};

pub(crate) struct AuthenticatedPeer {
    pub(crate) peer_id: String,
    pub(crate) session_binding: String,
    pub(crate) crypto: SessionCryptoMaterial,
}

pub(crate) async fn authenticate_initiator(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_public_key: [u8; 32],
    session_binding: &str,
) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
    initiate_generic(
        connection,
        local_identity,
        expected_peer_id,
        expected_peer_public_key,
        session_binding,
    )
    .await
}

pub(crate) async fn authenticate_responder(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
) -> Result<AuthenticatedPeer, CryptoHandshakeError> {
    let (peer_id, crypto) = respond_generic(connection, local_identity, trusted_peer_keys).await?;
    Ok(AuthenticatedPeer {
        peer_id,
        session_binding: crypto.session_binding.clone(),
        crypto,
    })
}
