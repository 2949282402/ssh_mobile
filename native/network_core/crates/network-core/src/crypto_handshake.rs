//! Forward-secret, identity-bound application crypto handshake.
//!
//! The transport authentication performed by QUIC/TCP/WebSocket answers
//! "which device opened this socket?".  This module establishes the
//! Session-owned application root separately with Noise XX.  Each handshake
//! generates a fresh X25519 keypair; the long-lived Ed25519 DeviceIdentity is
//! used only to sign the Noise static key and the logical Session binding.
//! The resulting root is never logged or exposed outside the native crypto
//! owner.

use ed25519_dalek::VerifyingKey;
use network_identity::DeviceIdentity;
use network_protocol::NETWORK_PROTOCOL_VERSION;
use snow::{params::NoiseParams, Builder, HandshakeState};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::RwLock;

use crate::connection::GenericConnection;

const NOISE_PATTERN: &str = "Noise_XX_25519_AESGCM_SHA256";
const HANDSHAKE_DOMAIN: &[u8] = b"ssh-mobile/session-e2ee/noise-xx/v1";
const HANDSHAKE_HELLO_MAGIC: &[u8; 4] = b"SMEH";
const HANDSHAKE_PROOF_MAGIC: &[u8; 4] = b"SMEP";
const HANDSHAKE_CAPABILITY: &[u8] = b"e2ee/noise-xx-aes256gcm-v2";
const MAX_DEVICE_ID_BYTES: usize = 128;
const MAX_SESSION_BINDING_BYTES: usize = 128;
const MAX_HANDSHAKE_PAYLOAD_BYTES: usize = 4 * 1024;
const MAX_HANDSHAKE_FRAME_BYTES: usize = 64 * 1024;
const NOISE_PUBLIC_KEY_BYTES: usize = 32;
const IDENTITY_PUBLIC_KEY_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;

#[derive(Debug, thiserror::Error)]
pub(crate) enum CryptoHandshakeError {
    #[error("application crypto handshake is invalid")]
    Invalid,
    #[error("application crypto handshake identity is not trusted")]
    UntrustedIdentity,
    #[error("application crypto handshake Session binding is invalid")]
    InvalidBinding,
    #[error("application crypto handshake capability is unavailable")]
    Unsupported,
    #[error("application crypto handshake failed")]
    Failed,
    #[error("application crypto handshake transport failed: {0}")]
    Transport(#[from] std::io::Error),
}

/// Direction-independent material produced by one successful Noise session.
/// `initiator` controls the later directional traffic-key derivation.
#[derive(Clone)]
pub(crate) struct SessionCryptoMaterial {
    pub(crate) root_key: [u8; 32],
    pub(crate) session_binding: String,
    pub(crate) initiator: bool,
}

struct NoiseHandshake {
    state: HandshakeState,
    identity: Arc<DeviceIdentity>,
    local_static_public: [u8; NOISE_PUBLIC_KEY_BYTES],
    identity_public: [u8; IDENTITY_PUBLIC_KEY_BYTES],
    initiator: bool,
}

impl NoiseHandshake {
    fn new(identity: Arc<DeviceIdentity>, initiator: bool) -> Result<Self, CryptoHandshakeError> {
        let params: NoiseParams = NOISE_PATTERN
            .parse()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let builder = Builder::new(params.clone());
        let keypair = builder
            .generate_keypair()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let local_static_public: [u8; NOISE_PUBLIC_KEY_BYTES] = keypair
            .public
            .as_slice()
            .try_into()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let identity_public = identity.public_identity_key().to_bytes();
        let state = if initiator {
            Builder::new(params)
                .local_private_key(&keypair.private)
                .prologue(prologue())
                .build_initiator()
        } else {
            Builder::new(params)
                .local_private_key(&keypair.private)
                .prologue(prologue())
                .build_responder()
        }
        .map_err(|_| CryptoHandshakeError::Failed)?;
        Ok(Self {
            state,
            identity,
            local_static_public,
            identity_public,
            initiator,
        })
    }

    fn write(&mut self, payload: &[u8]) -> Result<Vec<u8>, CryptoHandshakeError> {
        let mut message = vec![0u8; MAX_HANDSHAKE_FRAME_BYTES];
        let length = self
            .state
            .write_message(payload, &mut message)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        message.truncate(length);
        Ok(message)
    }

    fn read(&mut self, message: &[u8]) -> Result<Vec<u8>, CryptoHandshakeError> {
        if message.is_empty() || message.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut payload = vec![0u8; MAX_HANDSHAKE_PAYLOAD_BYTES];
        let length = self
            .state
            .read_message(message, &mut payload)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        payload.truncate(length);
        Ok(payload)
    }

    fn finish(
        self,
        session_binding: String,
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        if !self.state.is_handshake_finished() {
            return Err(CryptoHandshakeError::Failed);
        }
        let handshake_hash = self.state.get_handshake_hash();
        let root_key = derive_session_root(handshake_hash, &session_binding)?;
        self.state
            .into_transport_mode()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        Ok(SessionCryptoMaterial {
            root_key,
            session_binding,
            initiator: self.initiator,
        })
    }
}

/// Performs Noise XX over the already connected generic stream/message
/// transport.  The identity proof is encrypted by the Noise handshake before
/// it is checked by the peer.
pub(crate) async fn initiate_generic(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
    let mut handshake = NoiseHandshake::new(identity, true)?;
    let hello = hello_payload(session_binding)?;
    connection
        .send(&handshake.write(&hello)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let responder_payload = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
    validate_proof(
        &responder_payload,
        2,
        expected_peer_id,
        &expected_peer_identity_key,
        &handshake,
        session_binding,
    )?;
    let initiator_proof = proof_payload_with_signature(&handshake, 1, session_binding)?;
    connection
        .send(&handshake.write(&initiator_proof)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    handshake.finish(session_binding.to_string())
}

/// Performs Noise XX as the responder and resolves the claimed peer against
/// the same pinned identity registry used by the transport handshake.
pub(crate) async fn respond_generic(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
) -> Result<(String, SessionCryptoMaterial), CryptoHandshakeError> {
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let hello = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
    let session_binding = parse_hello(&hello)?;
    let responder_proof = proof_payload_with_signature(&handshake, 2, &session_binding)?;
    connection
        .send(&handshake.write(&responder_proof)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let initiator_payload = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
    let (peer_id, peer_key) =
        parse_proof_identity(&initiator_payload, 1, &handshake, &session_binding)?;
    let expected = trusted_peer_keys
        .read()
        .await
        .get(&peer_id)
        .copied()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
    if expected != peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature(&initiator_payload, &peer_id, &session_binding, &peer_key)?;
    let material = handshake.finish(session_binding)?;
    Ok((peer_id, material))
}

/// Relay carries the same three Noise XX messages as opaque control payloads.
/// The relay event loop owns the message exchange; these small state objects
/// keep the handshake transcript and identity proof in this crypto module.
pub(crate) struct RelayInitiatorHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
}

impl RelayInitiatorHandshake {
    pub(crate) fn start(
        identity: Arc<DeviceIdentity>,
        session_binding: &str,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        validate_binding(session_binding)?;
        let mut handshake = NoiseHandshake::new(identity, true)?;
        let message = handshake.write(&hello_payload(session_binding)?)?;
        Ok((
            Self {
                handshake,
                session_binding: session_binding.to_string(),
            },
            message,
        ))
    }

    pub(crate) fn accept_response(
        &mut self,
        response: &[u8],
        expected_peer_id: &str,
        expected_peer_identity_key: [u8; 32],
    ) -> Result<Vec<u8>, CryptoHandshakeError> {
        let responder_payload = self.handshake.read(response)?;
        validate_proof(
            &responder_payload,
            2,
            expected_peer_id,
            &expected_peer_identity_key,
            &self.handshake,
            &self.session_binding,
        )?;
        let initiator_proof =
            proof_payload_with_signature(&self.handshake, 1, &self.session_binding)?;
        self.handshake.write(&initiator_proof)
    }

    pub(crate) fn finish(self) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        self.handshake.finish(self.session_binding)
    }
}

pub(crate) struct RelayResponderHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
}

impl RelayResponderHandshake {
    pub(crate) fn accept_hello(
        identity: Arc<DeviceIdentity>,
        hello: &[u8],
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        let mut handshake = NoiseHandshake::new(identity, false)?;
        let session_binding = parse_hello(&handshake.read(hello)?)?;
        let responder_proof = proof_payload_with_signature(&handshake, 2, &session_binding)?;
        let response = handshake.write(&responder_proof)?;
        Ok((
            Self {
                handshake,
                session_binding,
            },
            response,
        ))
    }

    pub(crate) async fn accept_final(
        mut self,
        final_message: &[u8],
        trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    ) -> Result<(String, SessionCryptoMaterial), CryptoHandshakeError> {
        let initiator_payload = self.handshake.read(final_message)?;
        let (peer_id, peer_key) = parse_proof_identity(
            &initiator_payload,
            1,
            &self.handshake,
            &self.session_binding,
        )?;
        let expected = trusted_peer_keys
            .read()
            .await
            .get(&peer_id)
            .copied()
            .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
        if expected != peer_key {
            return Err(CryptoHandshakeError::UntrustedIdentity);
        }
        verify_proof_signature(
            &initiator_payload,
            &peer_id,
            &self.session_binding,
            &peer_key,
        )?;
        let material = self.handshake.finish(self.session_binding)?;
        Ok((peer_id, material))
    }
}

pub(crate) const RELAY_CRYPTO_HELLO: u8 = 1;
pub(crate) const RELAY_CRYPTO_RESPONSE: u8 = 2;
pub(crate) const RELAY_CRYPTO_FINAL: u8 = 3;

pub(crate) fn encode_relay_frame(
    step: u8,
    payload: &[u8],
) -> Result<Vec<u8>, CryptoHandshakeError> {
    if !matches!(
        step,
        RELAY_CRYPTO_HELLO | RELAY_CRYPTO_RESPONSE | RELAY_CRYPTO_FINAL
    ) || payload.is_empty()
        || payload.len() > MAX_HANDSHAKE_FRAME_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let mut frame = Vec::with_capacity(payload.len() + 1);
    frame.push(step);
    frame.extend_from_slice(payload);
    Ok(frame)
}

pub(crate) fn decode_relay_frame(frame: &[u8]) -> Result<(u8, &[u8]), CryptoHandshakeError> {
    let (&step, payload) = frame.split_first().ok_or(CryptoHandshakeError::Invalid)?;
    if !matches!(
        step,
        RELAY_CRYPTO_HELLO | RELAY_CRYPTO_RESPONSE | RELAY_CRYPTO_FINAL
    ) || payload.is_empty()
        || payload.len() > MAX_HANDSHAKE_FRAME_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok((step, payload))
}

/// The QUIC route uses one additional bidirectional stream for the same
/// application handshake.  The stream is discarded after the root is derived.
pub(crate) async fn initiate_quic(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
    let (mut send, mut recv) = connection
        .open_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let mut handshake = NoiseHandshake::new(identity, true)?;
    write_quic_frame(
        &mut send,
        &handshake.write(&hello_payload(session_binding)?)?,
    )
    .await?;
    let responder_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    validate_proof(
        &responder_payload,
        2,
        expected_peer_id,
        &expected_peer_identity_key,
        &handshake,
        session_binding,
    )?;
    let initiator_proof = proof_payload_with_signature(&handshake, 1, session_binding)?;
    write_quic_frame(&mut send, &handshake.write(&initiator_proof)?).await?;
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    handshake.finish(session_binding.to_string())
}

pub(crate) async fn respond_quic(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
) -> Result<(String, SessionCryptoMaterial), CryptoHandshakeError> {
    let (mut send, mut recv) = connection
        .accept_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let session_binding = parse_hello(&handshake.read(&read_quic_frame(&mut recv).await?)?)?;
    let responder_proof = proof_payload_with_signature(&handshake, 2, &session_binding)?;
    write_quic_frame(&mut send, &handshake.write(&responder_proof)?).await?;
    let initiator_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    let (peer_id, peer_key) =
        parse_proof_identity(&initiator_payload, 1, &handshake, &session_binding)?;
    let expected = trusted_peer_keys
        .read()
        .await
        .get(&peer_id)
        .copied()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
    if expected != peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature(&initiator_payload, &peer_id, &session_binding, &peer_key)?;
    let material = handshake.finish(session_binding)?;
    Ok((peer_id, material))
}

fn prologue() -> &'static [u8] {
    HANDSHAKE_DOMAIN
}

fn hello_payload(session_binding: &str) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    let mut payload =
        Vec::with_capacity(4 + 4 + 2 + session_binding.len() + HANDSHAKE_CAPABILITY.len());
    payload.extend_from_slice(HANDSHAKE_HELLO_MAGIC);
    payload.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string(&mut payload, session_binding)?;
    append_bytes(&mut payload, HANDSHAKE_CAPABILITY)?;
    Ok(payload)
}

fn parse_hello(payload: &[u8]) -> Result<String, CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    if cursor.take(4)? != HANDSHAKE_HELLO_MAGIC || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION {
        return Err(CryptoHandshakeError::Invalid);
    }
    let binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    validate_binding(&binding)?;
    if cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY || !cursor.done() {
        return Err(CryptoHandshakeError::Unsupported);
    }
    Ok(binding)
}

fn proof_payload_with_signature(
    handshake: &NoiseHandshake,
    role: u8,
    session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    let unsigned = proof_payload(
        role,
        &handshake.identity.device_id,
        &handshake.identity_public,
        &handshake.local_static_public,
        session_binding,
    );
    let signature = handshake.identity.sign_proof(&unsigned);
    let mut output = unsigned;
    if signature.len() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    output.extend_from_slice(&signature);
    Ok(output)
}

fn proof_payload(
    role: u8,
    device_id: &str,
    identity_public: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    noise_static_public: &[u8; NOISE_PUBLIC_KEY_BYTES],
    session_binding: &str,
) -> Vec<u8> {
    let mut output = Vec::with_capacity(128);
    output.extend_from_slice(HANDSHAKE_PROOF_MAGIC);
    output.push(role);
    output.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string_unchecked(&mut output, device_id);
    output.extend_from_slice(identity_public);
    output.extend_from_slice(noise_static_public);
    append_string_unchecked(&mut output, session_binding);
    append_bytes_unchecked(&mut output, HANDSHAKE_CAPABILITY);
    output
}

fn validate_proof(
    payload: &[u8],
    role: u8,
    expected_peer_id: &str,
    expected_peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<(), CryptoHandshakeError> {
    let (peer_id, peer_key) = parse_proof_identity(payload, role, handshake, session_binding)?;
    if peer_id != expected_peer_id || peer_key != *expected_peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    let signature_offset = proof_unsigned_length(&peer_id, session_binding);
    verify_signature(
        &peer_key,
        &payload[..signature_offset],
        &payload[signature_offset..],
    )
}

fn verify_proof_signature(
    payload: &[u8],
    peer_id: &str,
    session_binding: &str,
    peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
) -> Result<(), CryptoHandshakeError> {
    let signature_offset = proof_unsigned_length(peer_id, session_binding);
    if payload.len() != signature_offset + SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    verify_signature(
        peer_key,
        &payload[..signature_offset],
        &payload[signature_offset..],
    )
}

fn parse_proof_identity(
    payload: &[u8],
    role: u8,
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<(String, [u8; IDENTITY_PUBLIC_KEY_BYTES]), CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    if cursor.take(4)? != HANDSHAKE_PROOF_MAGIC
        || cursor.take_byte()? != role
        || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let peer_id = cursor.take_string(MAX_DEVICE_ID_BYTES)?;
    let peer_key: [u8; IDENTITY_PUBLIC_KEY_BYTES] = cursor
        .take_fixed(IDENTITY_PUBLIC_KEY_BYTES)?
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    let noise_static: [u8; NOISE_PUBLIC_KEY_BYTES] = cursor
        .take_fixed(NOISE_PUBLIC_KEY_BYTES)?
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    if noise_static.as_slice() != remote_noise_static(handshake)? {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    if cursor.take_string(MAX_SESSION_BINDING_BYTES)? != session_binding
        || cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    if cursor.remaining() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok((peer_id, peer_key))
}

fn remote_noise_static(handshake: &NoiseHandshake) -> Result<&[u8], CryptoHandshakeError> {
    handshake
        .state
        .get_remote_static()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)
}

fn verify_signature(
    public_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    payload: &[u8],
    signature: &[u8],
) -> Result<(), CryptoHandshakeError> {
    let key = VerifyingKey::from_bytes(public_key).map_err(|_| CryptoHandshakeError::Invalid)?;
    if DeviceIdentity::verify_peer_proof(&key, payload, signature) {
        Ok(())
    } else {
        Err(CryptoHandshakeError::UntrustedIdentity)
    }
}

fn derive_session_root(
    handshake_hash: &[u8],
    session_binding: &str,
) -> Result<[u8; 32], CryptoHandshakeError> {
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(session_binding.as_bytes()), handshake_hash);
    let mut root = [0u8; 32];
    hkdf.expand(b"ssh-mobile/session/application/noise-root/v2", &mut root)
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(root)
}

fn validate_binding(binding: &str) -> Result<(), CryptoHandshakeError> {
    if binding.is_empty()
        || binding.len() > MAX_SESSION_BINDING_BYTES
        || !binding.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CryptoHandshakeError::InvalidBinding);
    }
    Ok(())
}

fn append_string(output: &mut Vec<u8>, value: &str) -> Result<(), CryptoHandshakeError> {
    if value.len() > u16::MAX as usize {
        return Err(CryptoHandshakeError::Invalid);
    }
    append_string_unchecked(output, value);
    Ok(())
}

fn append_string_unchecked(output: &mut Vec<u8>, value: &str) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value.as_bytes());
}

fn append_bytes(output: &mut Vec<u8>, value: &[u8]) -> Result<(), CryptoHandshakeError> {
    if value.len() > u16::MAX as usize {
        return Err(CryptoHandshakeError::Invalid);
    }
    append_bytes_unchecked(output, value);
    Ok(())
}

fn append_bytes_unchecked(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value);
}

fn proof_unsigned_length(peer_id: &str, session_binding: &str) -> usize {
    4 + 1
        + 4
        + 2
        + peer_id.len()
        + IDENTITY_PUBLIC_KEY_BYTES
        + NOISE_PUBLIC_KEY_BYTES
        + 2
        + session_binding.len()
        + 2
        + HANDSHAKE_CAPABILITY.len()
}

async fn write_quic_frame(
    stream: &mut quinn::SendStream,
    payload: &[u8],
) -> Result<(), CryptoHandshakeError> {
    if payload.is_empty() || payload.len() > MAX_HANDSHAKE_FRAME_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    stream
        .write_u32(payload.len() as u32)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    stream
        .write_all(payload)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)
}

async fn read_quic_frame(stream: &mut quinn::RecvStream) -> Result<Vec<u8>, CryptoHandshakeError> {
    let length = stream
        .read_u32()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)? as usize;
    if length == 0 || length > MAX_HANDSHAKE_FRAME_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    let mut payload = vec![0u8; length];
    stream
        .read_exact(&mut payload)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(payload)
}

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(CryptoHandshakeError::Invalid)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(CryptoHandshakeError::Invalid)?;
        self.offset = end;
        Ok(value)
    }

    fn take_byte(&mut self) -> Result<u8, CryptoHandshakeError> {
        Ok(self.take(1)?[0])
    }

    fn take_u32(&mut self) -> Result<u32, CryptoHandshakeError> {
        Ok(u32::from_be_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ))
    }

    fn take_fixed(&mut self, length: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        self.take(length)
    }

    fn take_string(&mut self, max: usize) -> Result<String, CryptoHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(CryptoHandshakeError::Invalid);
        }
        String::from_utf8(self.take(length)?.to_vec()).map_err(|_| CryptoHandshakeError::Invalid)
    }

    fn take_bytes(&mut self, max: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ) as usize;
        if length > max {
            return Err(CryptoHandshakeError::Invalid);
        }
        self.take(length)
    }

    fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.offset)
    }

    fn done(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_identity::DeviceIdentity;

    fn identities() -> (Arc<DeviceIdentity>, Arc<DeviceIdentity>) {
        (
            Arc::new(DeviceIdentity::from_private_keys(
                "initiator".into(),
                [1u8; 32],
                [2u8; 32],
            )),
            Arc::new(DeviceIdentity::from_private_keys(
                "responder".into(),
                [3u8; 32],
                [4u8; 32],
            )),
        )
    }

    #[test]
    fn noise_xx_authenticates_identity_and_binds_session() {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = NoiseHandshake::new(Arc::clone(&initiator_identity), true).unwrap();
        let mut responder = NoiseHandshake::new(Arc::clone(&responder_identity), false).unwrap();
        let binding = "0000000000000001";

        let hello = initiator.write(&hello_payload(binding).unwrap()).unwrap();
        let responder_binding = parse_hello(&responder.read(&hello).unwrap()).unwrap();
        let responder_proof =
            proof_payload_with_signature(&responder, 2, &responder_binding).unwrap();
        let response = responder.write(&responder_proof).unwrap();
        let payload = initiator.read(&response).unwrap();
        validate_proof(
            &payload,
            2,
            &responder_identity.device_id,
            &responder_identity.public_identity_key().to_bytes(),
            &initiator,
            binding,
        )
        .unwrap();

        let initiator_proof = proof_payload_with_signature(&initiator, 1, binding).unwrap();
        let final_message = initiator.write(&initiator_proof).unwrap();
        let payload = responder.read(&final_message).unwrap();
        let (peer_id, peer_key) = parse_proof_identity(&payload, 1, &responder, binding).unwrap();
        assert_eq!(peer_id, initiator_identity.device_id);
        assert_eq!(
            peer_key,
            initiator_identity.public_identity_key().to_bytes()
        );
        verify_proof_signature(&payload, &peer_id, binding, &peer_key).unwrap();

        let initiator_material = initiator.finish(binding.to_string()).unwrap();
        let responder_material = responder.finish(responder_binding).unwrap();
        assert_eq!(initiator_material.root_key, responder_material.root_key);
        assert_ne!(initiator_material.root_key, [0u8; 32]);
        assert!(initiator_material.initiator);
        assert!(!responder_material.initiator);
    }

    #[test]
    fn noise_xx_rejects_a_wrong_pinned_identity() {
        let (initiator_identity, responder_identity) = identities();
        let wrong_identity = DeviceIdentity::generate("wrong-responder".into());
        let mut initiator = NoiseHandshake::new(Arc::clone(&initiator_identity), true).unwrap();
        let mut responder = NoiseHandshake::new(Arc::clone(&responder_identity), false).unwrap();
        let binding = "0000000000000001";
        let hello = initiator.write(&hello_payload(binding).unwrap()).unwrap();
        let responder_binding = parse_hello(&responder.read(&hello).unwrap()).unwrap();
        let responder_proof =
            proof_payload_with_signature(&responder, 2, &responder_binding).unwrap();
        let response = responder.write(&responder_proof).unwrap();
        let payload = initiator.read(&response).unwrap();
        assert!(matches!(
            validate_proof(
                &payload,
                2,
                &responder_identity.device_id,
                &wrong_identity.public_identity_key().to_bytes(),
                &initiator,
                binding,
            ),
            Err(CryptoHandshakeError::UntrustedIdentity)
        ));
    }

    #[tokio::test]
    async fn relay_noise_xx_preserves_the_same_session_root() {
        let (initiator_identity, responder_identity) = identities();
        let binding = "0000000000000001";
        let (mut initiator, hello) =
            RelayInitiatorHandshake::start(Arc::clone(&initiator_identity), binding).unwrap();
        let (responder, response) =
            RelayResponderHandshake::accept_hello(Arc::clone(&responder_identity), &hello).unwrap();
        let final_message = initiator
            .accept_response(
                &response,
                &responder_identity.device_id,
                responder_identity.public_identity_key().to_bytes(),
            )
            .unwrap();
        let mut trusted = HashMap::new();
        trusted.insert(
            initiator_identity.device_id.clone(),
            initiator_identity.public_identity_key().to_bytes(),
        );
        let trusted = RwLock::new(trusted);
        let (_, responder_material) = responder
            .accept_final(&final_message, &trusted)
            .await
            .unwrap();
        let initiator_material = initiator.finish().unwrap();
        assert_eq!(initiator_material.root_key, responder_material.root_key);
    }

    #[test]
    fn repeated_noise_sessions_have_different_roots() {
        let (initiator_identity, responder_identity) = identities();
        let first = complete_pair(&initiator_identity, &responder_identity, "0000000000000001");
        let second = complete_pair(&initiator_identity, &responder_identity, "0000000000000001");
        assert_ne!(first, second);
    }

    fn complete_pair(
        initiator_identity: &Arc<DeviceIdentity>,
        responder_identity: &Arc<DeviceIdentity>,
        binding: &str,
    ) -> [u8; 32] {
        let mut initiator = NoiseHandshake::new(Arc::clone(initiator_identity), true).unwrap();
        let mut responder = NoiseHandshake::new(Arc::clone(responder_identity), false).unwrap();
        let hello = initiator.write(&hello_payload(binding).unwrap()).unwrap();
        let responder_binding = parse_hello(&responder.read(&hello).unwrap()).unwrap();
        let response = responder
            .write(&proof_payload_with_signature(&responder, 2, &responder_binding).unwrap())
            .unwrap();
        let response_payload = initiator.read(&response).unwrap();
        validate_proof(
            &response_payload,
            2,
            &responder_identity.device_id,
            &responder_identity.public_identity_key().to_bytes(),
            &initiator,
            binding,
        )
        .unwrap();
        let final_message = initiator
            .write(&proof_payload_with_signature(&initiator, 1, binding).unwrap())
            .unwrap();
        let final_payload = responder.read(&final_message).unwrap();
        let (peer_id, peer_key) =
            parse_proof_identity(&final_payload, 1, &responder, binding).unwrap();
        verify_proof_signature(&final_payload, &peer_id, binding, &peer_key).unwrap();
        initiator.finish(binding.to_string()).unwrap().root_key
    }
}
