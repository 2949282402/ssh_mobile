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
use std::future::Future;
use std::sync::Arc;
use subtle::ConstantTimeEq;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::RwLock;
use zeroize::Zeroizing;

use crate::connection::{GenericConnection, RouteTransport};

// PathHandshakeV2 is the authenticated metadata/admission evolution carried
// by this module's existing Noise/DATA_ENV_CRYPTO transport. It deliberately
// does not introduce another key exchange or security envelope.
#[allow(dead_code)]
pub(crate) mod path_handshake {
    include!("path_handshake.rs");
}

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
    #[error(transparent)]
    Path(#[from] path_handshake::PathHandshakeError),
}

/// Direction-independent material produced by one successful Noise session.
/// `initiator` controls the later directional traffic-key derivation.
#[derive(Clone)]
pub(crate) struct SessionCryptoMaterial {
    pub(crate) root_key: [u8; 32],
    pub(crate) local_session_binding: String,
    pub(crate) remote_session_binding: String,
    pub(crate) initiator: bool,
    #[allow(dead_code)]
    pub(crate) e2ee_policy: path_handshake::E2eePolicy,
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
    e2ee_policy: path_handshake::E2eePolicy,
}

struct InitiatorRootExchange {
    noise: EstablishedNoise,
    root_key: Zeroizing<[u8; 32]>,
    expected_confirm: Zeroizing<[u8; ROOT_CONFIRM_BYTES]>,
    remote_session_binding: String,
    local_session_binding: String,
}

struct ResponderRootExchange {
    noise: EstablishedNoise,
    root_key: Zeroizing<[u8; 32]>,
    expected_confirm: Zeroizing<[u8; ROOT_CONFIRM_BYTES]>,
    local_session_binding: String,
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
        self.into_established_with_policy(session_binding, path_handshake::E2eePolicy::Required)
    }

    fn into_established_with_policy(
        self,
        session_binding: String,
        e2ee_policy: path_handshake::E2eePolicy,
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
            e2ee_policy,
        })
    }
}

impl EstablishedNoise {
    fn begin_responder(
        mut self,
        local_session_binding: &str,
    ) -> Result<(ResponderRootExchange, Vec<u8>), CryptoHandshakeError> {
        if self.initiator {
            return Err(CryptoHandshakeError::Failed);
        }
        validate_binding(local_session_binding)?;
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
        let seed_payload = root_seed_payload(&root_seed, local_session_binding)?;
        let encrypted_seed = self.encrypt_exchange(ROOT_EXCHANGE_ROOT_SEED, &seed_payload)?;
        Ok((
            ResponderRootExchange {
                noise: self,
                root_key,
                expected_confirm,
                local_session_binding: local_session_binding.to_string(),
            },
            encrypted_seed,
        ))
    }

    fn accept_root_seed(
        mut self,
        encrypted_seed: &[u8],
    ) -> Result<InitiatorRootExchange, CryptoHandshakeError> {
        if !self.initiator {
            return Err(CryptoHandshakeError::Failed);
        }
        let (root_seed, remote_session_binding) =
            self.decrypt_root_seed_exchange(encrypted_seed)?;
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
        Ok(InitiatorRootExchange {
            noise: self,
            root_key,
            expected_confirm: confirm,
            remote_session_binding,
            local_session_binding: String::new(),
        })
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

    fn decrypt_root_seed_exchange(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<(Zeroizing<[u8; ROOT_SEED_BYTES]>, String), CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            ROOT_EXCHANGE_ROOT_SEED,
            &self.session_binding,
        )?;
        if payload.len() < ROOT_SEED_BYTES + 2 {
            return Err(CryptoHandshakeError::Invalid);
        }
        let root_seed = Zeroizing::new(
            payload[..ROOT_SEED_BYTES]
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        );
        let mut cursor = Cursor::new(&payload[ROOT_SEED_BYTES..]);
        let remote_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
        if !cursor.done() {
            return Err(CryptoHandshakeError::Invalid);
        }
        validate_binding(&remote_session_binding)?;
        Ok((root_seed, remote_session_binding))
    }

    fn decrypt_root_confirm_exchange(
        &mut self,
        ciphertext: &[u8],
    ) -> Result<(Zeroizing<[u8; ROOT_CONFIRM_BYTES]>, String), CryptoHandshakeError> {
        if ciphertext.is_empty() || ciphertext.len() > MAX_HANDSHAKE_FRAME_BYTES {
            return Err(CryptoHandshakeError::Invalid);
        }
        let mut plaintext = Zeroizing::new([0u8; MAX_HANDSHAKE_PAYLOAD_BYTES]);
        let length = self
            .transport
            .read_message(ciphertext, &mut plaintext[..])
            .map_err(|_| CryptoHandshakeError::Failed)?;
        let payload = parse_root_exchange_payload(
            &plaintext[..length],
            ROOT_EXCHANGE_ROOT_CONFIRM,
            &self.session_binding,
        )?;
        if payload.len() < ROOT_CONFIRM_BYTES + 2 {
            return Err(CryptoHandshakeError::Invalid);
        }
        let confirm = Zeroizing::new(
            payload[..ROOT_CONFIRM_BYTES]
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        );
        let mut cursor = Cursor::new(&payload[ROOT_CONFIRM_BYTES..]);
        let remote_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
        if !cursor.done() {
            return Err(CryptoHandshakeError::Invalid);
        }
        validate_binding(&remote_session_binding)?;
        Ok((confirm, remote_session_binding))
    }

    fn into_material(
        self,
        root_key: [u8; 32],
        local_session_binding: String,
        remote_session_binding: String,
    ) -> SessionCryptoMaterial {
        SessionCryptoMaterial {
            root_key,
            local_session_binding,
            remote_session_binding,
            initiator: self.initiator,
            e2ee_policy: self.e2ee_policy,
        }
    }
}

impl InitiatorRootExchange {
    fn confirm(
        mut self,
        local_session_binding: String,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        validate_binding(&local_session_binding)?;
        let payload = root_confirm_payload(&self.expected_confirm, &local_session_binding)?;
        let encrypted_confirm = self
            .noise
            .encrypt_exchange(ROOT_EXCHANGE_ROOT_CONFIRM, &payload)?;
        self.local_session_binding = local_session_binding;
        Ok((self, encrypted_confirm))
    }

    fn accept(
        self,
        encrypted_accept: &[u8],
    ) -> Result<SessionCryptoMaterial, CryptoHandshakeError> {
        let mut noise = self.noise;
        noise.decrypt_fixed_exchange::<0>(ROOT_EXCHANGE_ACCEPT, encrypted_accept)?;
        Ok(noise.into_material(
            *self.root_key,
            self.local_session_binding,
            self.remote_session_binding,
        ))
    }
}

impl ResponderRootExchange {
    fn accept_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(Vec<u8>, SessionCryptoMaterial), CryptoHandshakeError> {
        let mut noise = self.noise;
        let (confirm, remote_session_binding) =
            noise.decrypt_root_confirm_exchange(encrypted_confirm)?;
        if !bool::from(confirm[..].ct_eq(&self.expected_confirm[..])) {
            return Err(CryptoHandshakeError::Failed);
        }
        let encrypted_accept = noise.encrypt_exchange(ROOT_EXCHANGE_ACCEPT, &[])?;
        let local_session_binding = self.local_session_binding;
        Ok((
            encrypted_accept,
            noise.into_material(
                *self.root_key,
                local_session_binding,
                remote_session_binding,
            ),
        ))
    }
}

pub(crate) async fn initiate_generic_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let path_metadata = direct_path_metadata(
        session_binding,
        match connection.profile().route().transport() {
            RouteTransport::Tcp => b"direct/tcp/v2".to_vec(),
            RouteTransport::WebSocket => b"direct/websocket/v2".to_vec(),
            RouteTransport::Quic | RouteTransport::Udp => return Err(CryptoHandshakeError::Failed),
        },
        e2ee_policy,
    )?;
    let mut handshake = NoiseHandshake::new(identity, true)?;
    let hello = hello_payload_with_path(session_binding, &path_metadata)?;
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
    let _remote_session_binding = validate_proof_with_path(
        &responder_payload,
        2,
        expected_peer_id,
        &expected_peer_identity_key,
        &handshake,
        session_binding,
        &path_metadata,
    )?;
    let initiator_proof = proof_payload_with_signature_with_path(
        &handshake,
        1,
        session_binding,
        session_binding,
        &path_metadata,
    )?;
    connection
        .send(&handshake.write(&initiator_proof)?)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let established =
        handshake.into_established_with_policy(session_binding.to_string(), e2ee_policy)?;
    let encrypted_seed = connection
        .recv()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let initiator = established.accept_root_seed(&encrypted_seed)?;
    let remote_session_binding = initiator.remote_session_binding.clone();
    let (local_session_binding, admission) =
        resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
    let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
    connection
        .send(&encrypted_confirm)
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let encrypted_accept = connection
        .recv()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((initiator.accept(&encrypted_accept)?, admission))
}

pub(crate) async fn respond_generic_with_policy<F, Fut, T>(
    connection: &mut GenericConnection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let hello = handshake.read(
        &connection
            .recv()
            .await
            .map_err(|_| CryptoHandshakeError::Failed)?,
    )?;
    let (session_binding, path_metadata) = parse_hello_with_path(&hello)?;
    validate_direct_path_metadata(
        &path_metadata,
        match connection.profile().route().transport() {
            RouteTransport::Tcp => b"direct/tcp/v2".as_slice(),
            RouteTransport::WebSocket => b"direct/websocket/v2".as_slice(),
            RouteTransport::Quic | RouteTransport::Udp => return Err(CryptoHandshakeError::Failed),
        },
        e2ee_policy,
    )?;
    // Generic routes do not expose the authenticated peer identity until the
    // initiator proof arrives. Keep the responder proof bound to the same
    // initiator Session binding; the actual responder binding is carried in
    // the encrypted RootSeed exchange after ConnectionSessionStore admission.
    let responder_proof = proof_payload_with_signature_with_path(
        &handshake,
        2,
        &session_binding,
        &session_binding,
        &path_metadata,
    )?;
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
    let (peer_id, peer_key, peer_session_binding) = parse_proof_identity_with_path(
        &initiator_payload,
        1,
        &handshake,
        &session_binding,
        &path_metadata,
    )?;
    if peer_session_binding != session_binding {
        return Err(CryptoHandshakeError::InvalidBinding);
    }
    let expected = trusted_peer_keys
        .read()
        .await
        .get(&peer_id)
        .copied()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
    if expected != peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature_with_path(
        &initiator_payload,
        &peer_id,
        &session_binding,
        &peer_session_binding,
        &peer_key,
        &path_metadata,
    )?;
    let (local_session_binding, admission) =
        resolve_local_session_binding(&peer_id, &session_binding).await?;
    let established =
        handshake.into_established_with_policy(session_binding.clone(), e2ee_policy)?;
    let (responder, encrypted_seed) = established.begin_responder(&local_session_binding)?;
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
    Ok((peer_id, material, admission))
}

/// Relay carries the Noise XX messages plus the post-handshake root exchange
/// as six opaque control payloads.
/// The relay event loop owns the message exchange; these small state objects
/// keep the handshake transcript and identity proof in this crypto module.
pub(crate) struct RelayInitiatorHandshake {
    handshake: NoiseHandshake,
    session_binding: String,
    path_metadata: path_handshake::PathHandshakeMetadata,
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
        let path_metadata = relay_path_metadata(session_binding)?;
        let mut handshake = NoiseHandshake::new(identity, true)?;
        let message =
            handshake.write(&hello_payload_with_path(session_binding, &path_metadata)?)?;
        Ok((
            Self {
                handshake,
                session_binding: session_binding.to_string(),
                path_metadata,
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
        let _remote_session_binding = validate_proof_with_path(
            &responder_payload,
            2,
            expected_peer_id,
            &expected_peer_identity_key,
            &self.handshake,
            &self.session_binding,
            &self.path_metadata,
        )?;
        let initiator_proof = proof_payload_with_signature_with_path(
            &self.handshake,
            1,
            &self.session_binding,
            &self.session_binding,
            &self.path_metadata,
        )?;
        self.handshake.write(&initiator_proof)
    }

    pub(crate) fn accept_root_seed(
        self,
        encrypted_seed: &[u8],
    ) -> Result<RelayInitiatorConfirmation, CryptoHandshakeError> {
        let established = self.handshake.into_established(self.session_binding)?;
        let exchange = established.accept_root_seed(encrypted_seed)?;
        Ok(RelayInitiatorConfirmation { exchange })
    }
}

impl RelayInitiatorConfirmation {
    pub(crate) fn remote_session_binding(&self) -> &str {
        &self.exchange.remote_session_binding
    }

    pub(crate) fn confirm(
        mut self,
        local_session_binding: String,
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        let (exchange, encrypted_confirm) = self.exchange.confirm(local_session_binding)?;
        self.exchange = exchange;
        Ok((self, encrypted_confirm))
    }

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
    path_metadata: path_handshake::PathHandshakeMetadata,
}

pub(crate) struct RelayResponderConfirmation<T> {
    peer_id: String,
    exchange: ResponderRootExchange,
    admission: T,
}

impl RelayResponderHandshake {
    pub(crate) fn accept_hello(
        identity: Arc<DeviceIdentity>,
        hello: &[u8],
    ) -> Result<(Self, Vec<u8>), CryptoHandshakeError> {
        let mut handshake = NoiseHandshake::new(identity, false)?;
        let (session_binding, path_metadata) = parse_hello_with_path(&handshake.read(hello)?)?;
        validate_relay_path_metadata(&path_metadata)?;
        let responder_proof = proof_payload_with_signature_with_path(
            &handshake,
            2,
            &session_binding,
            &session_binding,
            &path_metadata,
        )?;
        let response = handshake.write(&responder_proof)?;
        Ok((
            Self {
                handshake,
                session_binding,
                path_metadata,
            },
            response,
        ))
    }

    pub(crate) async fn accept_final<F, Fut, T>(
        mut self,
        final_message: &[u8],
        trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
        resolve_local_session_binding: F,
    ) -> Result<(String, RelayResponderConfirmation<T>, Vec<u8>), CryptoHandshakeError>
    where
        F: FnOnce(&str, &str) -> Fut,
        Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
    {
        let initiator_payload = self.handshake.read(final_message)?;
        let (peer_id, peer_key, peer_session_binding) = parse_proof_identity_with_path(
            &initiator_payload,
            1,
            &self.handshake,
            &self.session_binding,
            &self.path_metadata,
        )?;
        if peer_session_binding != self.session_binding {
            return Err(CryptoHandshakeError::InvalidBinding);
        }
        let expected = trusted_peer_keys
            .read()
            .await
            .get(&peer_id)
            .copied()
            .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
        if expected != peer_key {
            return Err(CryptoHandshakeError::UntrustedIdentity);
        }
        verify_proof_signature_with_path(
            &initiator_payload,
            &peer_id,
            &self.session_binding,
            &peer_session_binding,
            &peer_key,
            &self.path_metadata,
        )?;
        let (local_session_binding, admission) =
            resolve_local_session_binding(&peer_id, &self.session_binding).await?;
        let established = self
            .handshake
            .into_established(self.session_binding.clone())?;
        let (exchange, encrypted_seed) = established.begin_responder(&local_session_binding)?;
        Ok((
            peer_id.clone(),
            RelayResponderConfirmation {
                peer_id,
                exchange,
                admission,
            },
            encrypted_seed,
        ))
    }
}

impl<T> RelayResponderConfirmation<T> {
    pub(crate) fn accept_root_confirm(
        self,
        encrypted_confirm: &[u8],
    ) -> Result<(String, Vec<u8>, SessionCryptoMaterial, T), CryptoHandshakeError> {
        let (encrypted_accept, material) = self.exchange.accept_confirm(encrypted_confirm)?;
        Ok((self.peer_id, encrypted_accept, material, self.admission))
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
pub(crate) async fn initiate_quic<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    initiate_quic_with_policy(
        connection,
        identity,
        expected_peer_id,
        expected_peer_identity_key,
        session_binding,
        path_handshake::E2eePolicy::Required,
        resolve_remote_session,
    )
    .await
}

pub(crate) async fn initiate_quic_with_policy<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    expected_peer_id: &str,
    expected_peer_identity_key: [u8; 32],
    session_binding: &str,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_remote_session: F,
) -> Result<(SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (mut send, mut recv) = connection
        .open_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let path_metadata =
        direct_path_metadata(session_binding, b"direct/quic/v2".to_vec(), e2ee_policy)?;
    let mut handshake = NoiseHandshake::new(identity, true)?;
    write_quic_frame(
        &mut send,
        &handshake.write(&hello_payload_with_path(session_binding, &path_metadata)?)?,
    )
    .await?;
    let responder_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    let _remote_session_binding = validate_proof_with_path(
        &responder_payload,
        2,
        expected_peer_id,
        &expected_peer_identity_key,
        &handshake,
        session_binding,
        &path_metadata,
    )?;
    let initiator_proof = proof_payload_with_signature_with_path(
        &handshake,
        1,
        session_binding,
        session_binding,
        &path_metadata,
    )?;
    write_quic_frame(&mut send, &handshake.write(&initiator_proof)?).await?;
    let established =
        handshake.into_established_with_policy(session_binding.to_string(), e2ee_policy)?;
    let encrypted_seed = read_quic_frame(&mut recv).await?;
    let initiator = established.accept_root_seed(&encrypted_seed)?;
    let remote_session_binding = initiator.remote_session_binding.clone();
    let (local_session_binding, admission) =
        resolve_remote_session(expected_peer_id, &remote_session_binding).await?;
    let (initiator, encrypted_confirm) = initiator.confirm(local_session_binding)?;
    write_quic_frame(&mut send, &encrypted_confirm).await?;
    let encrypted_accept = read_quic_frame(&mut recv).await?;
    let material = initiator.accept(&encrypted_accept)?;
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((material, admission))
}

pub(crate) async fn respond_quic<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    respond_quic_with_policy(
        connection,
        identity,
        trusted_peer_keys,
        path_handshake::E2eePolicy::Required,
        resolve_local_session_binding,
    )
    .await
}

pub(crate) async fn respond_quic_with_policy<F, Fut, T>(
    connection: &quinn::Connection,
    identity: Arc<DeviceIdentity>,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
    e2ee_policy: path_handshake::E2eePolicy,
    resolve_local_session_binding: F,
) -> Result<(String, SessionCryptoMaterial, T), CryptoHandshakeError>
where
    F: FnOnce(&str, &str) -> Fut,
    Fut: Future<Output = Result<(String, T), CryptoHandshakeError>>,
{
    let (mut send, mut recv) = connection
        .accept_bi()
        .await
        .map_err(|_| CryptoHandshakeError::Failed)?;
    let mut handshake = NoiseHandshake::new(identity, false)?;
    let (session_binding, path_metadata) =
        parse_hello_with_path(&handshake.read(&read_quic_frame(&mut recv).await?)?)?;
    validate_direct_path_metadata(&path_metadata, b"direct/quic/v2", e2ee_policy)?;
    // The peer identity is not available until the final Noise proof. Use the
    // initiator binding as a pre-authentication placeholder; the authenticated
    // local binding is sent inside the encrypted RootSeed exchange below.
    let responder_proof = proof_payload_with_signature_with_path(
        &handshake,
        2,
        &session_binding,
        &session_binding,
        &path_metadata,
    )?;
    write_quic_frame(&mut send, &handshake.write(&responder_proof)?).await?;
    let initiator_payload = handshake.read(&read_quic_frame(&mut recv).await?)?;
    let (peer_id, peer_key, peer_session_binding) = parse_proof_identity_with_path(
        &initiator_payload,
        1,
        &handshake,
        &session_binding,
        &path_metadata,
    )?;
    if peer_session_binding != session_binding {
        return Err(CryptoHandshakeError::InvalidBinding);
    }
    let expected = trusted_peer_keys
        .read()
        .await
        .get(&peer_id)
        .copied()
        .ok_or(CryptoHandshakeError::UntrustedIdentity)?;
    if expected != peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature_with_path(
        &initiator_payload,
        &peer_id,
        &session_binding,
        &peer_session_binding,
        &peer_key,
        &path_metadata,
    )?;
    let (local_session_binding, admission) =
        resolve_local_session_binding(&peer_id, &session_binding).await?;
    let established =
        handshake.into_established_with_policy(session_binding.clone(), e2ee_policy)?;
    let (responder, encrypted_seed) = established.begin_responder(&local_session_binding)?;
    write_quic_frame(&mut send, &encrypted_seed).await?;
    let encrypted_confirm = read_quic_frame(&mut recv).await?;
    let (encrypted_accept, material) = responder.accept_confirm(&encrypted_confirm)?;
    write_quic_frame(&mut send, &encrypted_accept).await?;
    send.finish().map_err(|_| CryptoHandshakeError::Failed)?;
    Ok((peer_id, material, admission))
}

fn prologue() -> &'static [u8] {
    HANDSHAKE_DOMAIN
}

fn direct_path_metadata(
    session_binding: &str,
    connection_profile: Vec<u8>,
    policy: path_handshake::E2eePolicy,
) -> Result<path_handshake::PathHandshakeMetadata, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    Ok(path_handshake::PathHandshakeMetadata::new(
        policy,
        path_handshake::PathKind::Direct,
        session_binding.as_bytes().to_vec(),
        connection_profile,
    )?)
}

fn relay_path_metadata(
    session_binding: &str,
) -> Result<path_handshake::PathHandshakeMetadata, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    Ok(path_handshake::PathHandshakeMetadata::new(
        path_handshake::E2eePolicy::Required,
        path_handshake::PathKind::Relay,
        session_binding.as_bytes().to_vec(),
        b"relay-data/v2".to_vec(),
    )?)
}

fn validate_direct_path_metadata(
    metadata: &path_handshake::PathHandshakeMetadata,
    profile: &[u8],
    policy: path_handshake::E2eePolicy,
) -> Result<(), CryptoHandshakeError> {
    if metadata.path_kind != path_handshake::PathKind::Direct {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    if metadata.connection_profile != profile {
        return Err(path_handshake::PathHandshakeError::ConnectionProfileMismatch.into());
    }
    path_handshake::negotiate_security(metadata.path_kind, policy, metadata.e2ee_policy)?;
    Ok(())
}

fn validate_relay_path_metadata(
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<(), CryptoHandshakeError> {
    if metadata.path_kind != path_handshake::PathKind::Relay
        || metadata.connection_profile != b"relay-data/v2"
    {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    path_handshake::negotiate_security(
        metadata.path_kind,
        path_handshake::E2eePolicy::Required,
        metadata.e2ee_policy,
    )?;
    Ok(())
}

#[cfg(test)]
fn hello_payload(session_binding: &str) -> Result<Vec<u8>, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    hello_payload_with_path(session_binding, &metadata)
}

fn hello_payload_with_path(
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    let mut payload = Vec::with_capacity(
        4 + 4
            + 2
            + session_binding.len()
            + 4
            + 4
            + 2
            + metadata.path_binding.len()
            + metadata.connection_profile.len()
            + HANDSHAKE_CAPABILITY.len(),
    );
    payload.extend_from_slice(HANDSHAKE_HELLO_MAGIC);
    payload.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string(&mut payload, session_binding)?;
    metadata.encode(&mut payload)?;
    append_bytes(&mut payload, HANDSHAKE_CAPABILITY)?;
    Ok(payload)
}

#[cfg(test)]
fn parse_hello(payload: &[u8]) -> Result<String, CryptoHandshakeError> {
    parse_hello_with_path(payload)
        .map(|(binding, _)| binding)
        .map_err(|error| match error {
            // The compatibility-only test helper treats a pre-PathHandshake
            // payload as the rejected legacy capability, preserving the
            // fail-closed downgrade assertion without keeping a production
            // legacy parser alive.
            CryptoHandshakeError::Path(_) => CryptoHandshakeError::Unsupported,
            other => other,
        })
}

fn parse_hello_with_path(
    payload: &[u8],
) -> Result<(String, path_handshake::PathHandshakeMetadata), CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    if cursor.take(4)? != HANDSHAKE_HELLO_MAGIC || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION {
        return Err(CryptoHandshakeError::Invalid);
    }
    let binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    validate_binding(&binding)?;
    let metadata = path_handshake::PathHandshakeMetadata::decode(&mut cursor)?;
    if cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY || !cursor.done() {
        return Err(CryptoHandshakeError::Unsupported);
    }
    Ok((binding, metadata))
}

#[cfg(test)]
fn proof_payload_with_signature(
    handshake: &NoiseHandshake,
    role: u8,
    session_binding: &str,
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    proof_payload_with_signature_with_path(
        handshake,
        role,
        session_binding,
        local_session_binding,
        &metadata,
    )
}

fn proof_payload_with_signature_with_path(
    handshake: &NoiseHandshake,
    role: u8,
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(session_binding)?;
    validate_binding(local_session_binding)?;
    let unsigned = proof_payload_with_path(
        role,
        &handshake.identity.device_id,
        &handshake.identity_public,
        &handshake.local_static_public,
        session_binding,
        local_session_binding,
        metadata,
    );
    let signature = handshake.identity.sign_proof(&unsigned);
    let mut output = unsigned;
    if signature.len() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    output.extend_from_slice(&signature);
    Ok(output)
}

fn proof_payload_with_path(
    role: u8,
    device_id: &str,
    identity_public: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    noise_static_public: &[u8; NOISE_PUBLIC_KEY_BYTES],
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Vec<u8> {
    let mut output = Vec::with_capacity(128);
    output.extend_from_slice(HANDSHAKE_PROOF_MAGIC);
    output.push(role);
    output.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string_unchecked(&mut output, device_id);
    output.extend_from_slice(identity_public);
    output.extend_from_slice(noise_static_public);
    append_string_unchecked(&mut output, session_binding);
    append_string_unchecked(&mut output, local_session_binding);
    metadata
        .encode(&mut output)
        .expect("validated PathHandshakeV2 metadata is encodable");
    append_bytes_unchecked(&mut output, HANDSHAKE_CAPABILITY);
    output
}

#[cfg(test)]
fn validate_proof(
    payload: &[u8],
    role: u8,
    expected_peer_id: &str,
    expected_peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<String, CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    validate_proof_with_path(
        payload,
        role,
        expected_peer_id,
        expected_peer_key,
        handshake,
        session_binding,
        &metadata,
    )
}

fn validate_proof_with_path(
    payload: &[u8],
    role: u8,
    expected_peer_id: &str,
    expected_peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    handshake: &NoiseHandshake,
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<String, CryptoHandshakeError> {
    let (peer_id, peer_key, local_session_binding) =
        parse_proof_identity_with_path(payload, role, handshake, session_binding, metadata)?;
    if peer_id != expected_peer_id || peer_key != *expected_peer_key {
        return Err(CryptoHandshakeError::UntrustedIdentity);
    }
    verify_proof_signature_with_path(
        payload,
        &peer_id,
        session_binding,
        &local_session_binding,
        &peer_key,
        metadata,
    )?;
    Ok(local_session_binding)
}

#[cfg(test)]
fn verify_proof_signature(
    payload: &[u8],
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
) -> Result<(), CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    verify_proof_signature_with_path(
        payload,
        peer_id,
        session_binding,
        local_session_binding,
        peer_key,
        &metadata,
    )
}

fn verify_proof_signature_with_path(
    payload: &[u8],
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    peer_key: &[u8; IDENTITY_PUBLIC_KEY_BYTES],
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<(), CryptoHandshakeError> {
    let signature_offset =
        proof_unsigned_length_with_path(peer_id, session_binding, local_session_binding, metadata);
    if payload.len() != signature_offset + SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    verify_signature(
        peer_key,
        &payload[..signature_offset],
        &payload[signature_offset..],
    )
}

#[cfg(test)]
fn parse_proof_identity(
    payload: &[u8],
    role: u8,
    handshake: &NoiseHandshake,
    session_binding: &str,
) -> Result<(String, [u8; IDENTITY_PUBLIC_KEY_BYTES], String), CryptoHandshakeError> {
    let metadata = direct_path_metadata(
        session_binding,
        b"direct/generic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )?;
    parse_proof_identity_with_path(payload, role, handshake, session_binding, &metadata)
}

fn parse_proof_identity_with_path(
    payload: &[u8],
    role: u8,
    handshake: &NoiseHandshake,
    session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> Result<(String, [u8; IDENTITY_PUBLIC_KEY_BYTES], String), CryptoHandshakeError> {
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
    let claimed_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    let local_session_binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    let peer_metadata = path_handshake::PathHandshakeMetadata::decode(&mut cursor)?;
    if peer_metadata.e2ee_policy != metadata.e2ee_policy {
        return Err(path_handshake::PathHandshakeError::SecurityPolicyMismatch.into());
    }
    if peer_metadata.path_kind != metadata.path_kind
        || peer_metadata.path_binding != metadata.path_binding
    {
        return Err(path_handshake::PathHandshakeError::PathBindingMismatch.into());
    }
    if peer_metadata.connection_profile != metadata.connection_profile {
        return Err(path_handshake::PathHandshakeError::ConnectionProfileMismatch.into());
    }
    if claimed_session_binding != session_binding
        || validate_binding(&local_session_binding).is_err()
        || cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)? != HANDSHAKE_CAPABILITY
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    if cursor.remaining() != SIGNATURE_BYTES {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok((peer_id, peer_key, local_session_binding))
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

fn root_seed_payload(
    root_seed: &[u8; ROOT_SEED_BYTES],
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(local_session_binding)?;
    let mut payload = Vec::with_capacity(ROOT_SEED_BYTES + 2 + local_session_binding.len());
    payload.extend_from_slice(root_seed);
    append_string(&mut payload, local_session_binding)?;
    Ok(payload)
}

fn root_confirm_payload(
    confirm: &[u8; ROOT_CONFIRM_BYTES],
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(local_session_binding)?;
    let mut payload = Vec::with_capacity(ROOT_CONFIRM_BYTES + 2 + local_session_binding.len());
    payload.extend_from_slice(confirm);
    append_string(&mut payload, local_session_binding)?;
    Ok(payload)
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

fn proof_unsigned_length_with_path(
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> usize {
    4 + 1
        + 4
        + 2
        + peer_id.len()
        + IDENTITY_PUBLIC_KEY_BYTES
        + NOISE_PUBLIC_KEY_BYTES
        + 2
        + session_binding.len()
        + 2
        + local_session_binding.len()
        + 4
        + 4
        + 1
        + 1
        + 2
        + metadata.path_binding.len()
        + 2
        + metadata.connection_profile.len()
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

impl<'a> path_handshake::MetadataCursor for Cursor<'a> {
    fn take_byte(&mut self) -> Result<u8, path_handshake::PathHandshakeError> {
        self.take(1)
            .map(|bytes| bytes[0])
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)
    }

    fn take_u32(&mut self) -> Result<u32, path_handshake::PathHandshakeError> {
        let bytes = self
            .take(4)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?;
        Ok(u32::from_be_bytes(bytes.try_into().map_err(|_| {
            path_handshake::PathHandshakeError::InvalidFrame
        })?))
    }

    fn take_bytes(&mut self, max: usize) -> Result<&[u8], path_handshake::PathHandshakeError> {
        let bytes = self
            .take(2)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?;
        let length = u16::from_be_bytes(
            bytes
                .try_into()
                .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(path_handshake::PathHandshakeError::InvalidFrame);
        }
        self.take(length)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)
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
        let responder_local_binding = "0000000000000002";
        let responder_proof = proof_payload_with_signature(
            &responder,
            2,
            &responder_binding,
            responder_local_binding,
        )
        .unwrap();
        let response = responder.write(&responder_proof).unwrap();
        let payload = initiator.read(&response).unwrap();
        let observed_responder_binding = validate_proof(
            &payload,
            2,
            &responder_identity.device_id,
            &responder_identity.public_identity_key().to_bytes(),
            &initiator,
            binding,
        )
        .unwrap();
        assert_eq!(observed_responder_binding, responder_local_binding);

        let initiator_proof =
            proof_payload_with_signature(&initiator, 1, binding, binding).unwrap();
        let final_message = initiator.write(&initiator_proof).unwrap();
        let payload = responder.read(&final_message).unwrap();
        let (peer_id, peer_key, peer_session_binding) =
            parse_proof_identity(&payload, 1, &responder, binding).unwrap();
        assert_eq!(peer_id, initiator_identity.device_id);
        assert_eq!(
            peer_key,
            initiator_identity.public_identity_key().to_bytes()
        );
        verify_proof_signature(
            &payload,
            &peer_id,
            binding,
            &peer_session_binding,
            &peer_key,
        )
        .unwrap();

        let (initiator_material, responder_material) = complete_root_exchange(
            initiator,
            responder,
            binding.to_string(),
            responder_local_binding.to_string(),
        );
        assert_eq!(initiator_material.root_key, responder_material.root_key);
        assert_eq!(initiator_material.local_session_binding, binding);
        assert_eq!(
            initiator_material.remote_session_binding,
            responder_local_binding
        );
        assert_eq!(
            responder_material.local_session_binding,
            responder_local_binding
        );
        assert_eq!(responder_material.remote_session_binding, binding);
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
            proof_payload_with_signature(&responder, 2, &responder_binding, &responder_binding)
                .unwrap();
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
        let responder = responder.into_established(binding.clone()).unwrap();
        let (_, mut encrypted_seed) = responder.begin_responder(&binding).unwrap();
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
        let responder = responder.into_established(binding.clone()).unwrap();
        let (responder, encrypted_seed) = responder.begin_responder(&binding).unwrap();
        let _ = initiator
            .decrypt_root_seed_exchange(&encrypted_seed)
            .unwrap();
        let wrong_confirm_payload = root_confirm_payload(&[0u8; ROOT_CONFIRM_BYTES], &binding)
            .expect("well-formed wrong confirmation payload");
        let encrypted_wrong_confirm = initiator
            .encrypt_exchange(ROOT_EXCHANGE_ROOT_CONFIRM, &wrong_confirm_payload)
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
        let responder = responder.into_established(binding.clone()).unwrap();
        let (responder, encrypted_seed) = responder.begin_responder(&binding).unwrap();
        let initiator = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (initiator, encrypted_confirm) = initiator.confirm(binding.to_string()).unwrap();
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

    #[test]
    fn noise_path_metadata_rejects_profile_and_policy_mismatch() {
        let binding = "0000000000000001";
        let required = direct_path_metadata(
            binding,
            b"direct/tcp/v2".to_vec(),
            path_handshake::E2eePolicy::Required,
        )
        .unwrap();
        let mut encoded = hello_payload_with_path(binding, &required).unwrap();
        let parsed = parse_hello_with_path(&encoded).unwrap().1;
        assert_eq!(parsed, required);
        assert!(matches!(
            validate_direct_path_metadata(
                &parsed,
                b"direct/websocket/v2",
                path_handshake::E2eePolicy::Required,
            ),
            Err(CryptoHandshakeError::Path(
                path_handshake::PathHandshakeError::ConnectionProfileMismatch
            ))
        ));

        let disabled = direct_path_metadata(
            binding,
            b"direct/tcp/v2".to_vec(),
            path_handshake::E2eePolicy::Disabled,
        )
        .unwrap();
        assert!(matches!(
            validate_direct_path_metadata(
                &disabled,
                b"direct/tcp/v2",
                path_handshake::E2eePolicy::Required,
            ),
            Err(CryptoHandshakeError::Path(
                path_handshake::PathHandshakeError::SecurityPolicyMismatch
            ))
        ));

        // 4-byte magic + 4-byte protocol + 2-byte binding length + 16-byte binding
        // places the metadata policy byte at offset 34.
        encoded[34] = 0xff;
        assert!(matches!(
            parse_hello_with_path(&encoded),
            Err(CryptoHandshakeError::Path(
                path_handshake::PathHandshakeError::InvalidFrame
            ))
        ));
    }

    #[test]
    fn direct_disabled_material_is_marked_identity_only() {
        let (initiator_identity, responder_identity) = identities();
        let binding = "0000000000000001";
        let metadata = direct_path_metadata(
            binding,
            b"direct/tcp/v2".to_vec(),
            path_handshake::E2eePolicy::Disabled,
        )
        .unwrap();
        let mut initiator = NoiseHandshake::new(initiator_identity, true).unwrap();
        let mut responder = NoiseHandshake::new(responder_identity, false).unwrap();
        let hello = initiator
            .write(&hello_payload_with_path(binding, &metadata).unwrap())
            .unwrap();
        let responder_binding = parse_hello_with_path(&responder.read(&hello).unwrap())
            .unwrap()
            .0;
        let response = responder
            .write(
                &proof_payload_with_signature_with_path(
                    &responder,
                    2,
                    &responder_binding,
                    &responder_binding,
                    &metadata,
                )
                .unwrap(),
            )
            .unwrap();
        let response_payload = initiator.read(&response).unwrap();
        validate_proof_with_path(
            &response_payload,
            2,
            "responder",
            &identities().1.public_identity_key().to_bytes(),
            &initiator,
            binding,
            &metadata,
        )
        .unwrap();
        let final_message = initiator
            .write(
                &proof_payload_with_signature_with_path(&initiator, 1, binding, binding, &metadata)
                    .unwrap(),
            )
            .unwrap();
        let final_payload = responder.read(&final_message).unwrap();
        parse_proof_identity_with_path(&final_payload, 1, &responder, binding, &metadata).unwrap();
        let initiator = initiator
            .into_established_with_policy(binding.to_string(), path_handshake::E2eePolicy::Disabled)
            .unwrap();
        let responder = responder
            .into_established_with_policy(binding.to_string(), path_handshake::E2eePolicy::Disabled)
            .unwrap();
        let (responder, encrypted_seed) = responder.begin_responder(binding).unwrap();
        let initiator = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (initiator, encrypted_confirm) = initiator.confirm(binding.to_string()).unwrap();
        let (encrypted_accept, responder_material) =
            responder.accept_confirm(&encrypted_confirm).unwrap();
        let initiator_material = initiator.accept(&encrypted_accept).unwrap();
        assert_eq!(
            initiator_material.e2ee_policy,
            path_handshake::E2eePolicy::Disabled
        );
        assert_eq!(
            responder_material.e2ee_policy,
            path_handshake::E2eePolicy::Disabled
        );
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
                .accept_final(&final_message, &RwLock::new(trusted), |_, binding| {
                    let binding = binding.to_string();
                    async move { Ok((binding, ())) }
                })
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
            .accept_final(&final_message, &trusted, |_, binding| {
                let binding = binding.to_string();
                async move { Ok((binding, ())) }
            })
            .await
            .unwrap();
        let initiator = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (initiator, encrypted_confirm) = initiator.confirm(binding.to_string()).unwrap();
        let (_, encrypted_accept, responder_material, _) =
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
            .accept_final(&final_message, &trusted, |_, binding| {
                let binding = binding.to_string();
                async move { Ok((binding, ())) }
            })
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
            .write(
                &proof_payload_with_signature(
                    &responder,
                    2,
                    &responder_binding,
                    &responder_binding,
                )
                .unwrap(),
            )
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
            .write(&proof_payload_with_signature(&initiator, 1, binding, binding).unwrap())
            .unwrap();
        let final_payload = responder.read(&final_message).unwrap();
        let (peer_id, peer_key, peer_session_binding) =
            parse_proof_identity(&final_payload, 1, &responder, binding).unwrap();
        verify_proof_signature(
            &final_payload,
            &peer_id,
            binding,
            &peer_session_binding,
            &peer_key,
        )
        .unwrap();
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
            .write(
                &proof_payload_with_signature(
                    &responder,
                    2,
                    &responder_binding,
                    &responder_binding,
                )
                .unwrap(),
            )
            .unwrap();
        let _ = initiator.read(&response).unwrap();
        let final_message = initiator
            .write(&proof_payload_with_signature(&initiator, 1, &binding, &binding).unwrap())
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
        let initiator = initiator
            .into_established(initiator_binding.clone())
            .unwrap();
        let responder = responder
            .into_established(initiator_binding.clone())
            .unwrap();
        let (responder, encrypted_seed) = responder.begin_responder(&responder_binding).unwrap();
        let initiator = initiator.accept_root_seed(&encrypted_seed).unwrap();
        let (initiator, encrypted_confirm) = initiator.confirm(initiator_binding).unwrap();
        let (encrypted_accept, responder_material) =
            responder.accept_confirm(&encrypted_confirm).unwrap();
        let initiator_material = initiator.accept(&encrypted_accept).unwrap();
        (initiator_material, responder_material)
    }
}
