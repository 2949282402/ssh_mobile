use ed25519_dalek::VerifyingKey;
use network_identity::DeviceIdentity;
use network_protocol::NETWORK_PROTOCOL_VERSION;
use quinn::{Connection, RecvStream, SendStream};
use std::collections::HashMap;
use std::io::{Error, ErrorKind};
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::AsyncReadExt;
use tokio::sync::RwLock;
use tracing::info;

const MAX_DEVICE_ID_BYTES: usize = 128;
const NONCE_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;
const INITIATOR_DOMAIN: &[u8] = b"ssh-mobile/quic-auth/initiator/v1";
const RESPONDER_DOMAIN: &[u8] = b"ssh-mobile/quic-auth/responder/v1";

pub struct QuicPeerSession {
    pub connection: Connection,
    pub peer_device_id: String,
    authenticated: AtomicBool,
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

    /// Opens a bidirectional stream and authenticates the expected peer with a
    /// nonce-based Ed25519 challenge-response.
    pub async fn perform_handshake(
        &self,
        local_identity: &DeviceIdentity,
        expected_peer_public_key: [u8; 32],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (mut send, mut recv) = self.connection.open_bi().await?;
        let local_public_key = local_identity.public_identity_key().to_bytes();
        let initiator_nonce = rand::random::<[u8; NONCE_BYTES]>();
        let initiator_payload = authentication_payload(
            INITIATOR_DOMAIN,
            &local_identity.device_id,
            &local_public_key,
            &[&initiator_nonce],
        );
        let initiator_signature = local_identity.sign_proof(&initiator_payload);

        write_auth_frame(
            &mut send,
            &local_identity.device_id,
            &local_public_key,
            &initiator_nonce,
            &initiator_signature,
        )
        .await?;
        send.finish()?;

        let response = read_auth_frame(&mut recv).await?;
        validate_peer_frame(
            &response,
            &self.peer_device_id,
            &expected_peer_public_key,
            RESPONDER_DOMAIN,
            &[&initiator_nonce, &response.nonce],
        )?;

        self.authenticated.store(true, Ordering::SeqCst);
        info!(
            "Peer {} authenticated successfully over QUIC",
            self.peer_device_id
        );
        Ok(())
    }

    /// Accepts and verifies an initiator before returning a signed response.
    pub async fn accept_handshake(
        &self,
        local_identity: &DeviceIdentity,
        expected_peer_public_key: [u8; 32],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (mut send, mut recv) = self.connection.accept_bi().await?;
        let request = read_auth_frame(&mut recv).await?;
        validate_peer_frame(
            &request,
            &self.peer_device_id,
            &expected_peer_public_key,
            INITIATOR_DOMAIN,
            &[&request.nonce],
        )?;

        let local_public_key = local_identity.public_identity_key().to_bytes();
        let responder_nonce = rand::random::<[u8; NONCE_BYTES]>();
        let response_payload = authentication_payload(
            RESPONDER_DOMAIN,
            &local_identity.device_id,
            &local_public_key,
            &[&request.nonce, &responder_nonce],
        );
        let response_signature = local_identity.sign_proof(&response_payload);
        write_auth_frame(
            &mut send,
            &local_identity.device_id,
            &local_public_key,
            &responder_nonce,
            &response_signature,
        )
        .await?;
        send.finish()?;

        self.authenticated.store(true, Ordering::SeqCst);
        info!(
            "Peer {} authenticated successfully over QUIC",
            self.peer_device_id
        );
        Ok(())
    }

    /// Authenticates an inbound connection by resolving the claimed device ID
    /// against the current pinned peer-key registry.
    pub async fn accept_trusted(
        connection: Connection,
        local_identity: &DeviceIdentity,
        trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let (mut send, mut recv) = connection.accept_bi().await?;
        let request = read_auth_frame(&mut recv).await?;
        let expected_peer_public_key = trusted_peer_keys
            .read()
            .await
            .get(&request.device_id)
            .copied()
            .ok_or_else(|| Error::new(ErrorKind::PermissionDenied, "untrusted QUIC peer"))?;
        validate_peer_frame(
            &request,
            &request.device_id,
            &expected_peer_public_key,
            INITIATOR_DOMAIN,
            &[&request.nonce],
        )?;

        let local_public_key = local_identity.public_identity_key().to_bytes();
        let responder_nonce = rand::random::<[u8; NONCE_BYTES]>();
        let response_payload = authentication_payload(
            RESPONDER_DOMAIN,
            &local_identity.device_id,
            &local_public_key,
            &[&request.nonce, &responder_nonce],
        );
        let response_signature = local_identity.sign_proof(&response_payload);
        write_auth_frame(
            &mut send,
            &local_identity.device_id,
            &local_public_key,
            &responder_nonce,
            &response_signature,
        )
        .await?;
        send.finish()?;

        let session = Self::new(connection, request.device_id);
        session.authenticated.store(true, Ordering::SeqCst);
        Ok(session)
    }
}

struct AuthFrame {
    device_id: String,
    public_key: [u8; 32],
    nonce: [u8; NONCE_BYTES],
    signature: [u8; SIGNATURE_BYTES],
}

async fn write_auth_frame(
    send: &mut SendStream,
    device_id: &str,
    public_key: &[u8; 32],
    nonce: &[u8; NONCE_BYTES],
    signature: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if device_id.is_empty()
        || device_id.len() > MAX_DEVICE_ID_BYTES
        || signature.len() != SIGNATURE_BYTES
    {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid QUIC auth frame").into());
    }
    send.write_all(&NETWORK_PROTOCOL_VERSION.to_be_bytes())
        .await?;
    send.write_all(&(device_id.len() as u16).to_be_bytes())
        .await?;
    send.write_all(device_id.as_bytes()).await?;
    send.write_all(public_key).await?;
    send.write_all(nonce).await?;
    send.write_all(signature).await?;
    Ok(())
}

async fn read_auth_frame(
    recv: &mut RecvStream,
) -> Result<AuthFrame, Box<dyn std::error::Error + Send + Sync>> {
    let protocol_version = recv.read_u32().await?;
    if protocol_version != NETWORK_PROTOCOL_VERSION {
        return Err(Error::new(ErrorKind::InvalidData, "unsupported QUIC auth version").into());
    }
    let device_id_len = recv.read_u16().await? as usize;
    if device_id_len == 0 || device_id_len > MAX_DEVICE_ID_BYTES {
        return Err(Error::new(ErrorKind::InvalidData, "invalid peer device ID length").into());
    }
    let mut device_id = vec![0u8; device_id_len];
    recv.read_exact(&mut device_id).await?;
    let device_id = String::from_utf8(device_id)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "peer device ID is not UTF-8"))?;

    let mut public_key = [0u8; 32];
    recv.read_exact(&mut public_key).await?;
    let mut nonce = [0u8; NONCE_BYTES];
    recv.read_exact(&mut nonce).await?;
    let mut signature = [0u8; SIGNATURE_BYTES];
    recv.read_exact(&mut signature).await?;
    Ok(AuthFrame {
        device_id,
        public_key,
        nonce,
        signature,
    })
}

fn validate_peer_frame(
    frame: &AuthFrame,
    expected_device_id: &str,
    expected_public_key: &[u8; 32],
    domain: &[u8],
    nonces: &[&[u8]],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if frame.device_id != expected_device_id || &frame.public_key != expected_public_key {
        return Err(
            Error::new(ErrorKind::PermissionDenied, "unexpected QUIC peer identity").into(),
        );
    }
    let peer_key = VerifyingKey::from_bytes(expected_public_key)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "invalid peer Ed25519 key"))?;
    let payload = authentication_payload(domain, &frame.device_id, &frame.public_key, nonces);
    if !DeviceIdentity::verify_peer_proof(&peer_key, &payload, &frame.signature) {
        return Err(Error::new(ErrorKind::PermissionDenied, "invalid QUIC peer proof").into());
    }
    Ok(())
}

fn authentication_payload(
    domain: &[u8],
    device_id: &str,
    public_key: &[u8; 32],
    nonces: &[&[u8]],
) -> Vec<u8> {
    let mut payload = Vec::with_capacity(
        domain.len() + device_id.len() + public_key.len() + NONCE_BYTES * nonces.len() + 8,
    );
    payload.extend_from_slice(domain);
    payload.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    payload.extend_from_slice(&(device_id.len() as u16).to_be_bytes());
    payload.extend_from_slice(device_id.as_bytes());
    payload.extend_from_slice(public_key);
    for nonce in nonces {
        payload.extend_from_slice(nonce);
    }
    payload
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_a_valid_signature_from_the_wrong_identity() {
        let expected = DeviceIdentity::generate("expected".into());
        let attacker = DeviceIdentity::generate("expected".into());
        let nonce = [7u8; NONCE_BYTES];
        let attacker_key = attacker.public_identity_key().to_bytes();
        let payload =
            authentication_payload(INITIATOR_DOMAIN, "expected", &attacker_key, &[&nonce]);
        let frame = AuthFrame {
            device_id: "expected".into(),
            public_key: attacker_key,
            nonce,
            signature: attacker
                .sign_proof(&payload)
                .try_into()
                .expect("signature size"),
        };

        assert!(validate_peer_frame(
            &frame,
            "expected",
            &expected.public_identity_key().to_bytes(),
            INITIATOR_DOMAIN,
            &[&nonce],
        )
        .is_err());
    }
}
