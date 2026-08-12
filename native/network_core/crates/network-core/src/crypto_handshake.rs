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
use rand::{rngs::OsRng, RngCore};
use snow::{params::NoiseParams, Builder, HandshakeState, TransportState};
use std::collections::HashMap;
use std::sync::Arc;
use subtle::ConstantTimeEq;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::RwLock;
use zeroize::Zeroizing;

use crate::connection::GenericConnection;

const NOISE_PATTERN: &str = "Noise_XX_25519_AESGCM_SHA256";
const HANDSHAKE_DOMAIN: &[u8] = b"ssh-mobile/session-e2ee/noise-xx/v1";
const HANDSHAKE_HELLO_MAGIC: &[u8; 4] = b"SMEH";
const HANDSHAKE_PROOF_MAGIC: &[u8; 4] = b"SMEP";
const HANDSHAKE_CAPABILITY: &[u8] = b"e2ee/noise-xx-aes256gcm-v3";
const ROOT_EXCHANGE_MAGIC: &[u8; 4] = b"SMKR";
const ROOT_EXCHANGE_VERSION: u8 = 3;
const ROOT_EXCHANGE_ROOT_SEED: u8 = 1;
const ROOT_EXCHANGE_ROOT_CONFIRM: u8 = 2;
const ROOT_EXCHANGE_ACCEPT: u8 = 3;
const APPLICATION_ROOT_DOMAIN: &[u8] = b"ssh-mobile/session/application/root/v3";
const ROOT_CONFIRM_DOMAIN: &[u8] = b"ssh-mobile/session/application/root-confirm/v3";
const MAX_DEVICE_ID_BYTES: usize = 128;
const MAX_SESSION_BINDING_BYTES: usize = 128;
const MAX_HANDSHAKE_PAYLOAD_BYTES: usize = 4 * 1024;
const MAX_HANDSHAKE_FRAME_BYTES: usize = 64 * 1024;
const NOISE_PUBLIC_KEY_BYTES: usize = 32;
const IDENTITY_PUBLIC_KEY_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;
const ROOT_SEED_BYTES: usize = 32;
const ROOT_CONFIRM_BYTES: usize = 32;
const NOISE_TRANSPORT_TAG_BYTES: usize = 16;

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

struct EstablishedNoise {
    transport: TransportState,
    handshake_hash: [u8; 32],
    session_binding: String,
    initiator: bool,
}

struct InitiatorRootExchange {
    noise: EstablishedNoise,
    root_key: Zeroizing<[u8; 32]>,
}

struct ResponderRootExchange {
    noise: EstablishedNoise,
    root_key: Zeroizing<[u8; 32]>,
    expected_confirm: Zeroizing<[u8; ROOT_CONFIRM_BYTES]>,
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

    fn into_established(
        self,
        session_binding: String,
    ) -> Result<EstablishedNoise, CryptoHandshakeError> {
        if !self.state.is_handshake_finished() {
            return Err(CryptoHandshakeError::Failed);
        }
        validate_binding(&session_binding)?;
        let handshake_hash = self
            .state
            .get_handshake_hash()
            .try_into()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let transport = self
            .state
            .into_transport_mode()
            .map_err(|_| CryptoHandshakeError::Failed)?;
        Ok(EstablishedNoise {
            transport,
            handshake_hash,
            session_binding,
            initiator: self.initiator,
        })
    }
}

impl EstablishedNoise {
    fn begin_responder(mut self) -> Result<(ResponderRootExchange, Vec<u8>), CryptoHandshakeError> {
        if self.initiator {
            return Err(CryptoHandshakeError::Failed);
        }
        let mut root_seed = Zeroizing::new([0u8; ROOT_SEED_BYTES]);
        OsRng.fill_bytes(root_seed.as_mut());
        let root_key = Zeroizing::new(derive_application_root(
            &root_seed,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let expected_confirm = Zeroizing::new(derive_root_confirm(
            &root_key,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let encrypted_seed = self.encrypt_exchange(ROOT_EXCHANGE_ROOT_SEED, root_seed.as_ref())?;
        Ok((
            ResponderRootExchange {
                noise: self,
                root_key,
                expected_confirm,
            },
            encrypted_seed,
        ))
    }

    fn accept_root_seed(
        mut self,
        encrypted_seed: &[u8],
    ) -> Result<(InitiatorRootExchange, Vec<u8>), CryptoHandshakeError> {
        if !self.initiator {
            return Err(CryptoHandshakeError::Failed);
        }
        let root_seed = self
            .decrypt_fixed_exchange::<ROOT_SEED_BYTES>(ROOT_EXCHANGE_ROOT_SEED, encrypted_seed)?;
        let root_key = Zeroizing::new(derive_application_root(
            &root_seed,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let confirm = Zeroizing::new(derive_root_confirm(
            &root_key,
            &self.handshake_hash,
            &self.session_binding,
        )?);
        let encrypted_confirm =
            self.encrypt_exchange(ROOT_EXCHANGE_ROOT_CONFIRM, confirm.as_ref())?;
        Ok((
            InitiatorRootExchange {
                noise: self,
                root_key,
            },
            encrypted_confirm,
        ))
    }

    fn encrypt_exchange(
        &mut self,
        message_type: u8,
        payload: &[u8],
    ) -> Result<Vec<u8>, CryptoHandshakeError> {
        let plaintext = Zeroizing::new(root_exchange_payload(
            message_type,
            &self.session_binding,
            payload,
        )?);
        let mut ciphertext = vec![0u8; plaintext.len() + NOISE_TRANSPORT_TAG_BYTES];
        let length = self
            .transport
            .write_message(&plaintext, &mut ciphertext)
            .map_err(|_| CryptoHandshakeError::Failed)?;
        ciphertext.truncate(length);
        Ok(ciphertext)
    }

    fn decrypt_fixed_exchange<const N: usize>(
        &mut self,
        expected_type: u8,
        ciphertext: &[u8],
    ) -> Result<Zeroizing<[u8; N]>, CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        parse_fixed_root_exchange_payload::<N>(
            &plaintext[..length],
            expected_type,
            &self.session_binding,
        )
    }

    fn into_material(self, root_key: [u8; 32]) -> SessionCryptoMaterial {
        SessionCryptoMaterial {
            root_key,
            session_binding: self.session_binding,
            initiator: self.initiator,
        }
    }
}

impl InitiatorRootExchange {
    fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        let mut noise = self.noise;
        noise.decrypt_fixed_exchange::<0>(ROOT_EXCHANGE_ACCEPT, encrypted_accept)?;
        Ok(noise.into_material(*self.root_key))
    }
}

impl ResponderRootExchange {
    fn accept_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(Vec<u8>, SessionCryptoMaterial), CryptoHandshakeError> {
        let mut noise = self.noise;
        let confirm = noise.decrypt_fixed_exchange::<ROOT_CONFIRM_BYTES>(
            ROOT_EXCHANGE_ROOT_CONFIRM,
            encrypted_confirm,
        )?;
        if !bool::from(confirm[..].ct_eq(&self.expected_confirm[..])) {
            return Err(CryptoHandshakeError::Failed);
        }
        let encrypted_accept = noise.encrypt_exchange(ROOT_EXCHANGE_ACCEPT, &[])?;
        Ok((encrypted_accept, noise.into_material(*self.root_key)))
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
    let established = handshake.into_established(session_binding.to_string())?;
    let encrypted_seed = connection
        .recv()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let (initiator, encrypted_confirm) = established.accept_root_seed(&encrypted_seed)?;
    connection
        .send(&encrypted_confirm)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let encrypted_accept = connection
        .recv()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    initiator.accept(&encrypted_accept)
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
    let established = handshake.into_established(session_binding)?;
    let (responder, encrypted_seed) = established.begin_responder()?;
    connection
        .send(&encrypted_seed)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let encrypted_confirm = connection
        .recv()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
    connection
        .send(&encrypted_accept)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((peer_id, material))
}

/// Relay carries the Noise XX messages plus the post-handshake root exchange
/// as six opaque control payloads.
/// The relay event loop owns the message exchange; these small state objects
/// keep the handshake transcript and identity proof in this crypto module.
pub(crate) struct RelayInitiatorHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
}

pub(crate) struct RelayInitiatorConfirmation {
    exchange: InitiatorRootExchange,
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

    pub(crate) fn accept_root_seed(
        self,
        encrypted_seed: &[u8],
    ) -> Result<(RelayInitiatorConfirmation, Vec<u8>), CryptoHandshakeError> {
        let established = self.handshake.into_established(self.session_binding)?;
        let (exchange, encrypted_confirm) = established.accept_root_seed(encrypted_seed)?;
        Ok((RelayInitiatorConfirmation { exchange }, encrypted_confirm))
    }
}

impl RelayInitiatorConfirmation {
    pub(crate) fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        self.exchange.accept(encrypted_accept)
    }
}

pub(crate) struct RelayResponderHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
}

pub(crate) struct RelayResponderConfirmation {
    peer_id: String,
    exchange: ResponderRootExchange,
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
    ) -> Result<(String, RelayResponderConfirmation, Vec<u8>), CryptoHandshakeError> {
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
        let established = self.handshake.into_established(self.session_binding)?;
        let (exchange, encrypted_seed) = established.begin_responder()?;
        Ok((
            peer_id.clone(),
            RelayResponderConfirmation { peer_id, exchange },
            encrypted_seed,
        ))
    }
}

impl RelayResponderConfirmation {
    pub(crate) fn accept_root_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(String, Vec<u8>, SessionCryptoMaterial), CryptoHandshakeError> {
        let (encrypted_accept, material) = self.exchange.accept_confirm(encrypted_confirm)?;
        Ok((self.peer_id, encrypted_accept, material))
    }
}

pub(crate) const RELAY_CRYPTO_HELLO: u8 = 1;
pub(crate) const RELAY_CRYPTO_RESPONSE: u8 = 2;
pub(crate) const RELAY_CRYPTO_FINAL: u8 = 3;
pub(crate) const RELAY_CRYPTO_ROOT_SEED: u8 = 4;
pub(crate) const RELAY_CRYPTO_ROOT_CONFIRM: u8 = 5;
pub(crate) const RELAY_CRYPTO_ACCEPT: u8 = 6;

pub(crate) fn encode_relay_frame(
    step: u8,
    payload: &[u8],
) -> Result<Vec<u8>, CryptoHandshakeError> {
    if !matches!(
        step,
        RELAY_CRYPTO_HELLO
            | RELAY_CRYPTO_RESPONSE
            | RELAY_CRYPTO_FINAL
            | RELAY_CRYPTO_ROOT_SEED
            | RELAY_CRYPTO_ROOT_CONFIRM
            | RELAY_CRYPTO_ACCEPT
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
        RELAY_CRYPTO_HELLO
            | RELAY_CRYPTO_RESPONSE
            | RELAY_CRYPTO_FINAL
            | RELAY_CRYPTO_ROOT_SEED
            | RELAY_CRYPTO_ROOT_CONFIRM
            | RELAY_CRYPTO_ACCEPT
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
    let established = handshake.into_established(session_binding.to_string())?;
    let encrypted_seed = read_quic_frame(&mut recv).await?;
    let (initiator, encrypted_confirm) = established.accept_root_seed(&encrypted_seed)?;
    write_quic_frame(&mut send, &encrypted_confirm).await?;
    let encrypted_accept = read_quic_frame(&mut recv).await?;
    let material = initiator.accept(&encrypted_accept)?;
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(material)
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
    let established = handshake.into_established(session_binding)?;
    let (responder, encrypted_seed) = established.begin_responder()?;
    write_quic_frame(&mut send, &encrypted_seed).await?;
    let encrypted_confirm = read_quic_frame(&mut recv).await?;
    let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
    write_quic_frame(&mut send, &encrypted_accept).await?;
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
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

fn derive_application_root(
    root_seed: &[u8; ROOT_SEED_BYTES],
    handshake_hash: &[u8],
    session_binding: &str,
) -> Result<[u8; 32], CryptoHandshakeError> {
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(handshake_hash), root_seed);
    let mut root = [0u8; 32];
    let mut info = Vec::with_capacity(APPLICATION_ROOT_DOMAIN.len() + session_binding.len());
    info.extend_from_slice(APPLICATION_ROOT_DOMAIN);
    info.extend_from_slice(session_binding.as_bytes());
    hkdf.expand(&info, &mut root)
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(root)
}

fn derive_root_confirm(
    root_key: &[u8; 32],
    handshake_hash: &[u8; 32],
    session_binding: &str,
) -> Result<[u8; ROOT_CONFIRM_BYTES], CryptoHandshakeError> {
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(handshake_hash), root_key);
    let mut info = Vec::with_capacity(ROOT_CONFIRM_DOMAIN.len() + session_binding.len());
    info.extend_from_slice(ROOT_CONFIRM_DOMAIN);
    info.extend_from_slice(session_binding.as_bytes());
    let mut confirm = [0u8; ROOT_CONFIRM_BYTES];
    hkdf.expand(&info, &mut confirm)
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(confirm)
}

fn root_exchange_payload(
    message_type: u8,
    session_binding: &str,
    payload: &[u8],
) -> Result<Vec<u8>, CryptoHandshakeError> {
    if !matches!(
        message_type,
        ROOT_EXCHANGE_ROOT_SEED | ROOT_EXCHANGE_ROOT_CONFIRM | ROOT_EXCHANGE_ACCEPT
    ) || payload.len() > MAX_HANDSHAKE_PAYLOAD_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    validate_binding(session_binding)?;
    let mut output = Vec::with_capacity(12 + session_binding.len() + payload.len());
    output.extend_from_slice(ROOT_EXCHANGE_MAGIC);
    output.push(ROOT_EXCHANGE_VERSION);
    output.push(message_type);
    output.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string(&mut output, session_binding)?;
    append_bytes(&mut output, payload)?;
    Ok(output)
}

fn parse_root_exchange_payload<'a>(
    message: &'a [u8],
    expected_type: u8,
    session_binding: &str,
) -> Result<&'a [u8], CryptoHandshakeError> {
    let mut cursor = Cursor::new(message);
    if cursor.take(4)? != ROOT_EXCHANGE_MAGIC
        || cursor.take_byte()? != ROOT_EXCHANGE_VERSION
        || cursor.take_byte()? != expected_type
        || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION
        || cursor.take_string(MAX_SESSION_BINDING_BYTES)? != session_binding
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let payload = cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)?;
    if !cursor.done() {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok(payload)
}

fn parse_fixed_root_exchange_payload<const N: usize>(
    message: &[u8],
    expected_type: u8,
    session_binding: &str,
) -> Result<Zeroizing<[u8; N]>, CryptoHandshakeError> {
    let payload = parse_root_exchange_payload(message, expected_type, session_binding)?;
    let value = payload
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    Ok(Zeroizing::new(value))
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

        let (initiator_material, responder_material) =
            complete_root_exchange(initiator, responder, binding.to_string(), responder_binding);
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

    #[test]
    fn application_root_requires_secret_seed_and_binds_transcript() {
        let handshake_hash = [7u8; 32];
        let binding = "0000000000000001";
        let first = derive_application_root(&[1u8; 32], &handshake_hash, binding).unwrap();
        let second = derive_application_root(&[2u8; 32], &handshake_hash, binding).unwrap();
        assert_ne!(first, second);
        assert_ne!(first, handshake_hash);
    }

    #[test]
    fn tampered_root_seed_ciphertext_fails_before_material_exists() {
        let (initiator, responder, binding) = completed_identity_handshake();
        let initiator = initiator.into_established(binding.clone()).unwrap();
        let responder = responder.into_established(binding).unwrap();
        let (_, mut encrypted_seed) = responder.begin_responder().unwrap();
        let last = encrypted_seed.last_mut().unwrap();
        *last ^= 0x80;
        assert!(matches!(
            initiator.accept_root_seed(&encrypted_seed),
            Err(CryptoHandshakeError::Failed)
        ));
    }

    #[test]
    fn incorrect_root_confirmation_is_rejected() {
        let (initiator, responder, binding) = completed_identity_handshake();
        let mut initiator = initiator.into_established(binding.clone()).unwrap();
        let responder = responder.into_established(binding).unwrap();
        let (responder, encrypted_seed) = responder.begin_responder().unwrap();
        let _ = initiator
            .decrypt_fixed_exchange::<ROOT_SEED_BYTES>(ROOT_EXCHANGE_ROOT_SEED, &encrypted_seed)
            .unwrap();
        let encrypted_wrong_confirm = initiator
            .encrypt_exchange(ROOT_EXCHANGE_ROOT_CONFIRM, &[0u8; ROOT_CONFIRM_BYTES])
            .unwrap();
        assert!(matches!(
            responder.accept_confirm(&encrypted_wrong_confirm),
            Err(CryptoHandshakeError::Failed)
        ));
    }

    #[test]
    fn initiator_does_not_receive_material_without_accept() {
        let (initiator, responder, binding) = completed_identity_handshake();
        let initiator = initiator.into_established(binding.clone()).unwrap();
        let responder = responder.into_established(binding).unwrap();
        let (responder, encrypted_seed) = responder.begin_responder().unwrap();
        let (initiator, encrypted_confirm) = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (_, responder_material) = responder.accept_confirm(&encrypted_confirm).unwrap();
        assert_ne!(responder_material.root_key, [0u8; 32]);
        assert!(initiator.accept(&[]).is_err());
    }

    #[test]
    fn v2_capability_is_rejected_without_downgrade() {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = NoiseHandshake::new(initiator_identity, true).unwrap();
        let mut responder = NoiseHandshake::new(responder_identity, false).unwrap();
        let binding = "0000000000000001";
        let mut legacy_hello = Vec::new();
        legacy_hello.extend_from_slice(HANDSHAKE_HELLO_MAGIC);
        legacy_hello.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
        append_string(&mut legacy_hello, binding).unwrap();
        append_bytes(&mut legacy_hello, b"e2ee/noise-xx-aes256gcm-v2").unwrap();
        let message = initiator.write(&legacy_hello).unwrap();
        let payload = responder.read(&message).unwrap();
        assert!(matches!(
            parse_hello(&payload),
            Err(CryptoHandshakeError::Unsupported)
        ));
    }

    #[tokio::test]
    async fn wrong_initiator_identity_never_produces_relay_root_seed() {
        let (initiator_identity, responder_identity) = identities();
        let binding = "0000000000000001";
        let (mut initiator, hello) =
            RelayInitiatorHandshake::start(initiator_identity, binding).unwrap();
        let (responder, response) =
            RelayResponderHandshake::accept_hello(responder_identity, &hello).unwrap();
        let expected_responder = identities().1;
        let final_message = initiator
            .accept_response(
                &response,
                &expected_responder.device_id,
                expected_responder.public_identity_key().to_bytes(),
            )
            .unwrap();
        let mut trusted = HashMap::new();
        let wrong = DeviceIdentity::generate("wrong-initiator".into());
        trusted.insert(
            "initiator".to_string(),
            wrong.public_identity_key().to_bytes(),
        );
        assert!(matches!(
            responder
                .accept_final(&final_message, &RwLock::new(trusted))
                .await,
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
        let (_, confirmer, encrypted_seed) = responder
            .accept_final(&final_message, &trusted)
            .await
            .unwrap();
        let (initiator, encrypted_confirm) = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (_, encrypted_accept, responder_material) =
            confirmer.accept_root_confirm(&encrypted_confirm).unwrap();
        let initiator_material = initiator.accept(&encrypted_accept).unwrap();
        assert_eq!(initiator_material.root_key, responder_material.root_key);
        for (step, payload) in [
            (RELAY_CRYPTO_HELLO, hello.as_slice()),
            (RELAY_CRYPTO_RESPONSE, response.as_slice()),
            (RELAY_CRYPTO_FINAL, final_message.as_slice()),
            (RELAY_CRYPTO_ROOT_SEED, encrypted_seed.as_slice()),
            (RELAY_CRYPTO_ROOT_CONFIRM, encrypted_confirm.as_slice()),
            (RELAY_CRYPTO_ACCEPT, encrypted_accept.as_slice()),
        ] {
            let frame = encode_relay_frame(step, payload).unwrap();
            assert_eq!(decode_relay_frame(&frame).unwrap(), (step, payload));
        }
    }

    #[tokio::test]
    async fn tampered_relay_root_seed_ciphertext_fails_closed() {
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
        let trusted = RwLock::new(HashMap::from([(
            initiator_identity.device_id.clone(),
            initiator_identity.public_identity_key().to_bytes(),
        )]));
        let (_, _, mut encrypted_seed) = responder
            .accept_final(&final_message, &trusted)
            .await
            .unwrap();
        encrypted_seed[0] ^= 0x40;
        assert!(matches!(
            initiator.accept_root_seed(&encrypted_seed),
            Err(CryptoHandshakeError::Failed)
        ));
    }

    #[test]
    fn root_seed_parser_accepts_only_32_bytes() {
        let binding = "00112233445566778899aabbccddeeff";
        let valid = root_exchange_payload(ROOT_EXCHANGE_ROOT_SEED, binding, &[7u8; 32]).unwrap();
        let parsed = parse_fixed_root_exchange_payload::<ROOT_SEED_BYTES>(
            &valid,
            ROOT_EXCHANGE_ROOT_SEED,
            binding,
        )
        .expect("32-byte RootSeed");
        assert_eq!(&parsed[..], &[7u8; 32]);

        for length in [31, 33] {
            let invalid =
                root_exchange_payload(ROOT_EXCHANGE_ROOT_SEED, binding, &vec![7u8; length])
                    .unwrap();
            assert!(parse_fixed_root_exchange_payload::<ROOT_SEED_BYTES>(
                &invalid,
                ROOT_EXCHANGE_ROOT_SEED,
                binding,
            )
            .is_err());
        }
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
        complete_root_exchange(initiator, responder, binding.to_string(), responder_binding)
            .0
            .root_key
    }

    fn completed_identity_handshake() -> (NoiseHandshake, NoiseHandshake, String) {
        let (initiator_identity, responder_identity) = identities();
        let binding = "0000000000000001".to_string();
        let mut initiator = NoiseHandshake::new(initiator_identity, true).unwrap();
        let mut responder = NoiseHandshake::new(responder_identity, false).unwrap();
        let hello = initiator.write(&hello_payload(&binding).unwrap()).unwrap();
        let responder_binding = parse_hello(&responder.read(&hello).unwrap()).unwrap();
        let response = responder
            .write(&proof_payload_with_signature(&responder, 2, &responder_binding).unwrap())
            .unwrap();
        let _ = initiator.read(&response).unwrap();
        let final_message = initiator
            .write(&proof_payload_with_signature(&initiator, 1, &binding).unwrap())
            .unwrap();
        let _ = responder.read(&final_message).unwrap();
        (initiator, responder, binding)
    }

    fn complete_root_exchange(
        initiator: NoiseHandshake,
        responder: NoiseHandshake,
        initiator_binding: String,
        responder_binding: String,
    ) -> (SessionCryptoMaterial, SessionCryptoMaterial) {
        let initiator = initiator.into_established(initiator_binding).unwrap();
        let responder = responder.into_established(responder_binding).unwrap();
        let (responder, encrypted_seed) = responder.begin_responder().unwrap();
        let (initiator, encrypted_confirm) = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (encrypted_accept, responder_material) =
            responder.accept_confirm(&encrypted_confirm).unwrap();
        let initiator_material = initiator.accept(&encrypted_accept).unwrap();
        (initiator_material, responder_material)
    }
}
