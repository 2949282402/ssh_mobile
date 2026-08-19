//! Application authentication for non-QUIC Session routes.
//!
//! TCP and WebSocket establish a socket, not a trusted peer. The route is
//! admitted only after the Noise XX application handshake proves the pinned
//! Ed25519 identity and binds the logical Session. The same handshake returns
//! the forward-secret Session root used by application E2EE.

use network_identity::DeviceIdentity;
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::connection::GenericConnection;
use crate::crypto_handshake::{
    initiate_generic_with_policy, path_handshake::E2eePolicy, respond_generic_with_policy,
    CryptoHandshakeError, SessionCryptoMaterial,
};

pub(crate) struct AuthenticatedPeer<T> {
    pub(crate) peer_id: String,
    pub(crate) session_binding: String,
    pub(crate) crypto: SessionCryptoMaterial,
    pub(crate) admission: T,
}

#[allow(dead_code)] // compatibility helper retained for focused handshake tests
pub(crate) async fn authenticate_initiator<F, Fut, T>(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_public_key: [u8; 32],
    session_binding: &str,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    authenticate_initiator_with_policy(
        connection,
        local_identity,
        expected_peer_id,
        expected_peer_public_key,
        session_binding,
        E2eePolicy::Required,
        resolve_remote_session,
    )
    .await
}

pub(crate) async fn authenticate_initiator_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_public_key: [u8; 32],
    session_binding: &str,
    e2ee_policy: E2eePolicy,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    initiate_generic_with_policy(
        connection,
        local_identity,
        expected_peer_id,
        expected_peer_public_key,
        session_binding,
        e2ee_policy,
        resolve_remote_session,
    )
    .await
}

#[allow(dead_code)] // compatibility helper retained for focused handshake tests
pub(crate) async fn authenticate_responder<F, Fut, T>(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    resolve_local_session_binding: F,
) -> Result<AuthenticatedPeer<T>, CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    authenticate_responder_with_policy(
        connection,
        local_identity,
        trusted_peer_keys,
        E2eePolicy::Required,
        resolve_local_session_binding,
    )
    .await
}

#[allow(dead_code)] // compatibility helper retained for focused handshake tests
pub(crate) async fn authenticate_responder_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: E2eePolicy,
    resolve_local_session_binding: F,
) -> Result<AuthenticatedPeer<T>, CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (peer_id, crypto, admission) = respond_generic_with_policy(
        connection,
        local_identity,
        trusted_peer_keys,
        e2ee_policy,
        resolve_local_session_binding,
    )
    .await?;
    Ok(AuthenticatedPeer {
        peer_id,
        session_binding: crypto.remote_session_binding.clone(),
        crypto,
        admission,
    })
}

/// Authenticate an inbound generic route using the policy advertised inside
/// its authenticated PathHandshake metadata. The peer identity is not
/// available until the Noise proof, so the runtime verifies the configured
/// peer policy immediately after this function returns and before publishing
/// the physical path.
pub(crate) async fn authenticate_responder_auto_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    local_identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    resolve_local_session_binding: F,
) -> Result<AuthenticatedPeer<T>, CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (peer_id, crypto, admission) = crate::crypto_handshake::respond_generic_auto_policy(
        connection,
        local_identity,
        trusted_peer_keys,
        resolve_local_session_binding,
    )
    .await?;
    Ok(AuthenticatedPeer {
        peer_id,
        session_binding: crypto.remote_session_binding.clone(),
        crypto,
        admission,
    })
}
