//! Session-owned application cryptography.
//!
//! The transport only carries opaque bytes.  A `CryptoContext` is created for
//! one logical `(peer, SessionId)` pair and does **not** survive transport loss
//! (transport-network v2 §18): every new connection derives a fresh Noise root
//! and installs a fresh context.  The traffic root is installed only after the
//! authenticated Noise XX handshake in `crypto_handshake.rs`; long-lived
//! DeviceIdentity keys do not directly become application traffic keys.

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use hkdf::Hkdf;
#[cfg(test)]
use network_identity::DeviceIdentity;
use rand::RngCore;
use sha2::Sha256;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::sync::{Arc, Mutex};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

/// The application crypto suite carried by encrypted Relay offer metadata.
/// Network Protocol V2 always uses the ConnectionSession-owned E2EE context;
/// crypto mode is not negotiated per message.
pub(crate) const APPLICATION_CRYPTO_SUITE: &str = "hkdf-sha256-aes256gcm-v1";

#[cfg(test)]
const TEST_ROOT_KDF_INFO: &[u8] = b"ssh-mobile/session/application/test-root/v1";
const INITIATOR_TO_RESPONDER_KDF_INFO: &[u8] =
    b"ssh-mobile/session/application/initiator-to-responder/v2";
const RESPONDER_TO_INITIATOR_KDF_INFO: &[u8] =
    b"ssh-mobile/session/application/responder-to-initiator/v2";
const NONCE_PREFIX_KDF_INFO: &[u8] = b"ssh-mobile/session/application/nonce-prefix/v2";
const OFFER_KDF_INFO: &[u8] = b"ssh-mobile/session/application/offer/v1";
const OFFER_AAD_PREFIX: &[u8] = b"ssh-mobile/session/application/offer/v1";
const FILE_CHUNK_AAD_PREFIX: &[u8] = b"ssh-mobile/session/application/file-chunk/v1";
const ENVELOPE_MAGIC: &[u8; 4] = b"SME1";
const ENVELOPE_VERSION: u8 = 1;
const X25519_PUBLIC_KEY_BYTES: usize = 32;
const GCM_NONCE_BYTES: usize = 12;
const GCM_TAG_BYTES: usize = 16;
const ENVELOPE_HEADER_BYTES: usize = 4 + 1 + 1 + std::mem::size_of::<u64>() + GCM_NONCE_BYTES;
const REPLAY_WINDOW_CAPACITY: usize = 4096;
const MAX_RETAINED_KEY_EPOCHS: u64 = 4;
pub(crate) const MAX_MESSAGES_PER_KEY: u64 = 1_048_576;
pub(crate) const MAX_BYTES_PER_KEY: u64 = 1 << 30;
const NONCE_PREFIX_BYTES: usize = 4;

/// Whether bytes carry the frozen application E2EE envelope marker.
///
/// Disabled Direct paths intentionally carry the authenticated application
/// payload unchanged. Receivers use this marker only to reject an encrypted
/// payload arriving under a Disabled policy; transport identity/authentication
/// remains mandatory in both modes.
pub(crate) fn is_application_envelope(bytes: &[u8]) -> bool {
    bytes.len() >= ENVELOPE_MAGIC.len() && bytes[..ENVELOPE_MAGIC.len()] == *ENVELOPE_MAGIC
}

/// Numeric suite marker in the application envelope.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CryptoSuite {
    HkdfSha256Aes256GcmV1,
}

impl CryptoSuite {
    fn code(self) -> u8 {
        match self {
            Self::HkdfSha256Aes256GcmV1 => 1,
        }
    }

    fn from_code(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::HkdfSha256Aes256GcmV1),
            _ => None,
        }
    }
}

/// Monotonic application key epoch.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct KeyEpoch(u64);

impl KeyEpoch {
    pub(crate) const INITIAL: Self = Self(0);
}

/// Bounded nonce replay/reuse window.
///
/// Entries are retained in insertion order so an attacker cannot grow this
/// structure without bound.  A nonce is accepted at most once while it is in
/// the window; AEAD authentication is performed before receive-side inserts.
#[derive(Clone, Debug)]
pub(crate) struct ReplayWindow {
    capacity: usize,
    seen: HashSet<[u8; GCM_NONCE_BYTES]>,
    order: VecDeque<[u8; GCM_NONCE_BYTES]>,
}

impl Default for ReplayWindow {
    fn default() -> Self {
        Self::new(REPLAY_WINDOW_CAPACITY)
    }
}

impl ReplayWindow {
    pub(crate) fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            seen: HashSet::new(),
            order: VecDeque::new(),
        }
    }

    fn reserve(&mut self, nonce: [u8; GCM_NONCE_BYTES]) -> Result<(), CryptoError> {
        if !self.seen.insert(nonce) {
            return Err(CryptoError::NonceReuse);
        }
        self.order.push_back(nonce);
        while self.order.len() > self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.seen.remove(&evicted);
            }
        }
        Ok(())
    }

    fn accept_received(&mut self, nonce: [u8; GCM_NONCE_BYTES]) -> Result<(), CryptoError> {
        if self.seen.contains(&nonce) {
            return Err(CryptoError::ReplayDetected);
        }
        self.reserve(nonce).map_err(|_| CryptoError::ReplayDetected)
    }
}

/// Errors exposed by the native crypto boundary without including key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CryptoError {
    InvalidEnvelope,
    InvalidKey,
    KeyDerivation,
    Encryption,
    Decryption,
    SequenceOverflow,
    ReplayDetected,
    NonceReuse,
    KeyEpochUnavailable,
    NoncePrefixMismatch,
    E2eeRequired,
    StateUnavailable,
}

impl fmt::Display for CryptoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidEnvelope => "invalid application crypto envelope",
            Self::InvalidKey => "invalid application crypto key",
            Self::KeyDerivation => "application key derivation failed",
            Self::Encryption => "application encryption failed",
            Self::Decryption => "application decryption failed",
            Self::SequenceOverflow => "application sequence overflow",
            Self::ReplayDetected => "application ciphertext replay detected",
            Self::NonceReuse => "application nonce reuse rejected",
            Self::KeyEpochUnavailable => "application key epoch is unavailable",
            Self::NoncePrefixMismatch => "application nonce prefix is invalid",
            Self::E2eeRequired => "application E2EE context is required",
            Self::StateUnavailable => "application crypto state is unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CryptoError {}

/// Session-owned AEAD context. It owns directional keys, key epoch state,
/// structured nonce counters, and bounded replay windows; it has no Route or
/// Connection handle dependency.
pub(crate) struct CryptoContext {
    suite: CryptoSuite,
    root_key: [u8; 32],
    tx_info: &'static [u8],
    rx_info: &'static [u8],
    send_epoch: KeyEpoch,
    receive_epoch: KeyEpoch,
    send_counter: u64,
    messages_in_epoch: u64,
    bytes_in_epoch: u64,
    send_window: ReplayWindow,
    receive_window: ReplayWindow,
    #[cfg(test)]
    allow_arbitrary_test_nonce: bool,
}

impl CryptoContext {
    /// Creates a context from the root produced by an authenticated Noise
    /// handshake. The root is already bound to the handshake transcript and
    /// logical Session binding; only directional traffic keys are expanded
    /// here.
    pub(crate) fn from_session_root(root_key: [u8; 32], initiator: bool) -> Self {
        let (tx_info, rx_info) = if initiator {
            (
                INITIATOR_TO_RESPONDER_KDF_INFO,
                RESPONDER_TO_INITIATOR_KDF_INFO,
            )
        } else {
            (
                RESPONDER_TO_INITIATOR_KDF_INFO,
                INITIATOR_TO_RESPONDER_KDF_INFO,
            )
        };
        Self {
            suite: CryptoSuite::HkdfSha256Aes256GcmV1,
            root_key,
            tx_info,
            rx_info,
            send_epoch: KeyEpoch::INITIAL,
            receive_epoch: KeyEpoch::INITIAL,
            send_counter: 0,
            messages_in_epoch: 0,
            bytes_in_epoch: 0,
            send_window: ReplayWindow::default(),
            receive_window: ReplayWindow::default(),
            #[cfg(test)]
            allow_arbitrary_test_nonce: false,
        }
    }

    #[allow(dead_code)]
    pub(crate) fn suite(&self) -> CryptoSuite {
        self.suite
    }

    #[allow(dead_code)]
    pub(crate) fn current_epoch(&self) -> KeyEpoch {
        self.send_epoch.max(self.receive_epoch)
    }

    /// Advance the local send epoch.  The authenticated epoch marker lets the
    /// peer derive the same bounded epoch key on its next receive.
    #[allow(dead_code)]
    pub(crate) fn rotate_key(&mut self) -> Result<KeyEpoch, CryptoError> {
        let next = self
            .send_epoch
            .0
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        self.send_epoch = KeyEpoch(next);
        self.send_counter = 0;
        self.messages_in_epoch = 0;
        self.bytes_in_epoch = 0;
        Ok(self.send_epoch)
    }

    pub(crate) fn encrypt(&mut self, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let plaintext_bytes =
            u64::try_from(plaintext.len()).map_err(|_| CryptoError::SequenceOverflow)?;
        if self.messages_in_epoch >= MAX_MESSAGES_PER_KEY
            || self.bytes_in_epoch > MAX_BYTES_PER_KEY.saturating_sub(plaintext_bytes)
        {
            self.rotate_key()?;
        }
        let nonce = self.next_nonce()?;
        let envelope = self.encrypt_with_nonce(aad, plaintext, nonce)?;
        self.messages_in_epoch = self
            .messages_in_epoch
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        self.bytes_in_epoch = self
            .bytes_in_epoch
            .checked_add(plaintext_bytes)
            .ok_or(CryptoError::SequenceOverflow)?;
        Ok(envelope)
    }

    /// Deterministic nonce injection is test-only support for proving that a
    /// nonce cannot be reused. Production sends use the structured counter in
    /// [`Self::encrypt`].
    pub(crate) fn encrypt_with_nonce(
        &mut self,
        aad: &[u8],
        plaintext: &[u8],
        nonce: [u8; GCM_NONCE_BYTES],
    ) -> Result<Vec<u8>, CryptoError> {
        self.send_window.reserve(nonce)?;
        let key = self.epoch_key(self.tx_info, self.send_epoch)?;
        let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|_| CryptoError::Encryption)?;
        let mut envelope = Vec::with_capacity(ENVELOPE_HEADER_BYTES + ciphertext.len());
        envelope.extend_from_slice(ENVELOPE_MAGIC);
        envelope.push(ENVELOPE_VERSION);
        envelope.push(self.suite.code());
        envelope.extend_from_slice(&self.send_epoch.0.to_be_bytes());
        envelope.extend_from_slice(&nonce);
        envelope.extend_from_slice(&ciphertext);
        Ok(envelope)
    }

    pub(crate) fn decrypt(&mut self, aad: &[u8], envelope: &[u8]) -> Result<Vec<u8>, CryptoError> {
        self.decrypt_internal(aad, envelope, false)
    }

    /// Decrypt a reliable Delivery envelope idempotently. A duplicate wire
    /// frame is still authenticated, then returned to Delivery so its
    /// DuplicateInFlight/Processed semantics can decide whether to emit or
    /// re-ACK. Best-effort payloads use strict `decrypt` instead.
    pub(crate) fn decrypt_for_delivery(
        &mut self,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        self.decrypt_internal(aad, envelope, true)
    }

    fn decrypt_internal(
        &mut self,
        aad: &[u8],
        envelope: &[u8],
        allow_authenticated_replay: bool,
    ) -> Result<Vec<u8>, CryptoError> {
        if envelope.len() < ENVELOPE_HEADER_BYTES + GCM_TAG_BYTES
            || &envelope[..ENVELOPE_MAGIC.len()] != ENVELOPE_MAGIC
            || envelope[ENVELOPE_MAGIC.len()] != ENVELOPE_VERSION
        {
            return Err(CryptoError::InvalidEnvelope);
        }
        let suite = CryptoSuite::from_code(envelope[5]).ok_or(CryptoError::InvalidEnvelope)?;
        if suite != self.suite {
            return Err(CryptoError::InvalidEnvelope);
        }
        let epoch = KeyEpoch(u64::from_be_bytes(
            envelope[6..14]
                .try_into()
                .map_err(|_| CryptoError::InvalidEnvelope)?,
        ));
        if epoch.0 > self.receive_epoch.0.saturating_add(1)
            || self.receive_epoch.0.saturating_sub(epoch.0) >= MAX_RETAINED_KEY_EPOCHS
        {
            return Err(CryptoError::KeyEpochUnavailable);
        }
        let nonce: [u8; GCM_NONCE_BYTES] = envelope[14..26]
            .try_into()
            .map_err(|_| CryptoError::InvalidEnvelope)?;
        let nonce_prefix_matches = nonce[..NONCE_PREFIX_BYTES]
            == self.nonce_prefix(self.rx_info, epoch)?[..NONCE_PREFIX_BYTES];
        #[cfg(test)]
        let nonce_prefix_matches = nonce_prefix_matches || self.allow_arbitrary_test_nonce;
        if !nonce_prefix_matches {
            return Err(CryptoError::NoncePrefixMismatch);
        }
        let key = self.epoch_key(self.rx_info, epoch)?;
        let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
        let clear = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &envelope[ENVELOPE_HEADER_BYTES..],
                    aad,
                },
            )
            .map_err(|_| CryptoError::Decryption)?;
        if self.receive_window.seen.contains(&nonce) {
            if !allow_authenticated_replay {
                return Err(CryptoError::ReplayDetected);
            }
        } else {
            self.receive_window.accept_received(nonce)?;
        }
        if epoch > self.receive_epoch {
            self.receive_epoch = epoch;
        }
        Ok(clear)
    }

    fn next_nonce(&mut self) -> Result<[u8; GCM_NONCE_BYTES], CryptoError> {
        let counter = self.send_counter;
        self.send_counter = self
            .send_counter
            .checked_add(1)
            .ok_or(CryptoError::SequenceOverflow)?;
        let mut nonce = [0u8; GCM_NONCE_BYTES];
        nonce[..NONCE_PREFIX_BYTES].copy_from_slice(
            &self.nonce_prefix(self.tx_info, self.send_epoch)?[..NONCE_PREFIX_BYTES],
        );
        nonce[NONCE_PREFIX_BYTES..].copy_from_slice(&counter.to_be_bytes());
        Ok(nonce)
    }

    fn nonce_prefix(&self, info: &'static [u8], epoch: KeyEpoch) -> Result<[u8; 32], CryptoError> {
        let key = self.epoch_key(info, epoch)?;
        derive_material(&key, &[], NONCE_PREFIX_KDF_INFO)
    }

    fn epoch_key(&self, info: &'static [u8], epoch: KeyEpoch) -> Result<[u8; 32], CryptoError> {
        let mut epoch_info = Vec::with_capacity(info.len() + 8);
        epoch_info.extend_from_slice(info);
        epoch_info.extend_from_slice(&epoch.0.to_be_bytes());
        derive_material(&self.root_key, &[], &epoch_info)
    }

    #[cfg(test)]
    pub(crate) fn from_identity(
        local_identity: &DeviceIdentity,
        peer_public_key: [u8; 32],
        session_id: &str,
    ) -> Result<Self, CryptoError> {
        let local_public = X25519PublicKey::from(&local_identity.e2e_key);
        let peer_public = X25519PublicKey::from(peer_public_key);
        let shared = local_identity.e2e_key.diffie_hellman(&peer_public);
        if shared.as_bytes().iter().all(|byte| *byte == 0) {
            return Err(CryptoError::InvalidKey);
        }
        let root_key =
            derive_material(shared.as_bytes(), session_id.as_bytes(), TEST_ROOT_KDF_INFO)?;
        let mut context =
            Self::from_session_root(root_key, local_public.as_bytes() <= peer_public.as_bytes());
        context.allow_arbitrary_test_nonce = true;
        Ok(context)
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct CryptoContextKey {
    peer_id: String,
    session_id: String,
}

/// App Scope owner for Session application contexts.  Contexts are keyed by
/// logical Session rather than transport route and are removed only when a
/// Session is explicitly closed.
pub(crate) struct SessionCryptoManager {
    contexts: Mutex<HashMap<CryptoContextKey, Arc<Mutex<CryptoContext>>>>,
}

impl Default for SessionCryptoManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionCryptoManager {
    pub(crate) fn new() -> Self {
        Self {
            contexts: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn install_material_aliases(
        &self,
        peer_id: &str,
        session_ids: &[&str],
        root_key: [u8; 32],
        initiator: bool,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        let mut contexts = self
            .contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?;
        // §18 1:1：每次连接都安装**全新** root。A peer owns one logical Session
        // at a time, so every alias for that peer is retired before the new root
        // is installed; a new alias must never discover an older context by
        // collision. There is no ContinueExisting reuse path.
        contexts.retain(|key, _| key.peer_id != peer_id);
        let context = Arc::new(Mutex::new(CryptoContext::from_session_root(
            root_key, initiator,
        )));
        for session_id in session_ids {
            contexts.insert(
                CryptoContextKey {
                    peer_id: peer_id.to_string(),
                    session_id: (*session_id).to_string(),
                },
                Arc::clone(&context),
            );
        }
        Ok(context)
    }

    #[cfg(test)]
    fn get_or_create(
        &self,
        peer_id: &str,
        session_id: &str,
        identity: &DeviceIdentity,
        peer_public_key: [u8; 32],
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        let key = CryptoContextKey {
            peer_id: peer_id.to_string(),
            session_id: session_id.to_string(),
        };
        let mut contexts = self
            .contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?;
        if let Some(context) = contexts.get(&key) {
            return Ok(Arc::clone(context));
        }
        let context = Arc::new(Mutex::new(CryptoContext::from_identity(
            identity,
            peer_public_key,
            session_id,
        )?));
        contexts.insert(key, Arc::clone(&context));
        Ok(context)
    }

    pub(crate) fn get(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        self.contexts
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .get(&CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            })
            .cloned()
            .ok_or(CryptoError::E2eeRequired)
    }

    pub(crate) fn remove_session(&self, peer_id: &str, session_id: &str) {
        if let Ok(mut contexts) = self.contexts.lock() {
            let key = CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            };
            let Some(context) = contexts.remove(&key) else {
                return;
            };
            contexts.retain(|_, current| !Arc::ptr_eq(current, &context));
        }
    }

    #[cfg(test)]
    fn contains(&self, peer_id: &str, session_id: &str) -> bool {
        self.contexts
            .lock()
            .expect("context lock")
            .contains_key(&CryptoContextKey {
                peer_id: peer_id.to_string(),
                session_id: session_id.to_string(),
            })
    }
}

/// Encrypt an offer with an ephemeral X25519 key and an HKDF-derived AEAD key.
/// This protects Relay control metadata; the Relay never sees the clear offer.
pub(crate) fn encrypt_application_offer(
    plaintext: &[u8],
    peer_public_key: [u8; 32],
    session_id: &[u8; 16],
) -> Result<Vec<u8>, CryptoError> {
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&X25519PublicKey::from(peer_public_key));
    let key = derive_material(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
    let mut nonce = [0u8; GCM_NONCE_BYTES];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let aad = offer_aad(session_id);
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| CryptoError::Encryption)?;
    let mut envelope =
        Vec::with_capacity(X25519_PUBLIC_KEY_BYTES + GCM_NONCE_BYTES + encrypted.len());
    envelope.extend_from_slice(ephemeral_public.as_bytes());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&encrypted);
    Ok(envelope)
}

/// Decrypt an application offer using the recipient's long-lived E2E secret.
pub(crate) fn decrypt_application_offer(
    envelope: &[u8],
    local_secret: &StaticSecret,
    session_id: &[u8; 16],
) -> Result<Vec<u8>, CryptoError> {
    let minimum = X25519_PUBLIC_KEY_BYTES + GCM_NONCE_BYTES + GCM_TAG_BYTES;
    if envelope.len() < minimum {
        return Err(CryptoError::InvalidEnvelope);
    }
    let ephemeral_key: [u8; 32] = envelope[..X25519_PUBLIC_KEY_BYTES]
        .try_into()
        .map_err(|_| CryptoError::InvalidEnvelope)?;
    let nonce = &envelope[X25519_PUBLIC_KEY_BYTES..minimum - GCM_TAG_BYTES];
    let shared = local_secret.diffie_hellman(&X25519PublicKey::from(ephemeral_key));
    let key = derive_material(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
    let aad = offer_aad(session_id);
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: &envelope[minimum - GCM_TAG_BYTES..],
                aad: &aad,
            },
        )
        .map_err(|_| CryptoError::Decryption)
}

/// Construct stable associated data for a Relay file chunk.
pub(crate) fn file_chunk_aad(
    session_id: &str,
    transfer_id: &str,
    manifest_hash: &str,
    sequence: u64,
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(
        FILE_CHUNK_AAD_PREFIX.len()
            + session_id.len()
            + transfer_id.len()
            + manifest_hash.len()
            + std::mem::size_of::<u64>()
            + 12,
    );
    aad.extend_from_slice(FILE_CHUNK_AAD_PREFIX);
    append_len_prefixed(&mut aad, session_id.as_bytes());
    append_len_prefixed(&mut aad, transfer_id.as_bytes());
    append_len_prefixed(&mut aad, manifest_hash.as_bytes());
    aad.extend_from_slice(&sequence.to_be_bytes());
    aad
}

/// Advance an ordered transfer sequence without wrapping.
pub(crate) fn next_sequence(sequence: u64) -> Result<u64, CryptoError> {
    sequence.checked_add(1).ok_or(CryptoError::SequenceOverflow)
}

/// Build AAD from a DataMessage's clear metadata. The payload is intentionally
/// excluded, so retries can replace ciphertext without changing the binding.
pub(crate) fn data_message_aad(
    session_id: &str,
    channel_id: &str,
    message_id: &[u8],
    sequence: u64,
    recovery_epoch: u64,
    policy: i32,
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(64 + session_id.len() + channel_id.len() + message_id.len());
    append_len_prefixed(&mut aad, session_id.as_bytes());
    append_len_prefixed(&mut aad, channel_id.as_bytes());
    append_len_prefixed(&mut aad, message_id);
    aad.extend_from_slice(&sequence.to_be_bytes());
    aad.extend_from_slice(&recovery_epoch.to_be_bytes());
    aad.extend_from_slice(&policy.to_be_bytes());
    aad
}

fn append_len_prefixed(output: &mut Vec<u8>, bytes: &[u8]) {
    output.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    output.extend_from_slice(bytes);
}

fn derive_material(
    input_key_material: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; 32], CryptoError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), input_key_material);
    let mut key = [0u8; 32];
    hkdf.expand(info, &mut key)
        .map_err(|_| CryptoError::KeyDerivation)?;
    Ok(key)
}

fn offer_aad(session_id: &[u8; 16]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(OFFER_AAD_PREFIX.len() + session_id.len());
    aad.extend_from_slice(OFFER_AAD_PREFIX);
    aad.extend_from_slice(session_id);
    aad
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identities() -> (DeviceIdentity, DeviceIdentity) {
        (
            DeviceIdentity::from_private_keys("sender".into(), [1u8; 32], [2u8; 32]),
            DeviceIdentity::from_private_keys("receiver".into(), [3u8; 32], [4u8; 32]),
        )
    }

    #[test]
    fn e2ee_round_trip_is_route_independent() {
        let (sender_identity, receiver_identity) = identities();
        let mut sender = CryptoContext::from_identity(
            &sender_identity,
            *receiver_identity.public_e2e_key().as_bytes(),
            "0000000000000001",
        )
        .unwrap();
        let mut receiver = CryptoContext::from_identity(
            &receiver_identity,
            *sender_identity.public_e2e_key().as_bytes(),
            "0000000000000001",
        )
        .unwrap();
        let aad = b"same Session, QUIC or Relay";
        let ciphertext = sender.encrypt(aad, b"secret").unwrap();
        assert_ne!(ciphertext, b"secret");
        assert_eq!(receiver.decrypt(aad, &ciphertext).unwrap(), b"secret");
        assert_eq!(sender.suite(), CryptoSuite::HkdfSha256Aes256GcmV1);
    }

    #[test]
    fn tamper_wrong_key_and_replay_are_rejected() {
        let (sender_identity, receiver_identity) = identities();
        let mut sender = CryptoContext::from_identity(
            &sender_identity,
            *receiver_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let mut receiver = CryptoContext::from_identity(
            &receiver_identity,
            *sender_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let mut wrong_receiver = CryptoContext::from_identity(
            &receiver_identity,
            *DeviceIdentity::generate("wrong".into())
                .public_e2e_key()
                .as_bytes(),
            "session-a",
        )
        .unwrap();
        let aad = b"aad";
        let mut ciphertext = sender.encrypt(aad, b"secret").unwrap();
        assert!(wrong_receiver.decrypt(aad, &ciphertext).is_err());
        *ciphertext.last_mut().unwrap() ^= 1;
        assert!(receiver.decrypt(aad, &ciphertext).is_err());
        let ciphertext = sender.encrypt(aad, b"secret").unwrap();
        assert_eq!(receiver.decrypt(aad, &ciphertext).unwrap(), b"secret");
        assert_eq!(
            receiver.decrypt(aad, &ciphertext),
            Err(CryptoError::ReplayDetected)
        );
    }

    #[test]
    fn key_rotation_accepts_one_new_epoch_and_rejects_large_jump() {
        let (sender_identity, receiver_identity) = identities();
        let mut sender = CryptoContext::from_identity(
            &sender_identity,
            *receiver_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let mut receiver = CryptoContext::from_identity(
            &receiver_identity,
            *sender_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        sender.rotate_key().unwrap();
        let ciphertext = sender.encrypt(b"aad", b"rotated").unwrap();
        assert_eq!(receiver.decrypt(b"aad", &ciphertext).unwrap(), b"rotated");
        assert_eq!(receiver.current_epoch(), KeyEpoch(1));
        sender.rotate_key().unwrap();
        sender.rotate_key().unwrap();
        assert_eq!(sender.current_epoch(), KeyEpoch(3));
        let ciphertext = sender.encrypt(b"aad", b"too far").unwrap();
        assert_eq!(
            receiver.decrypt(b"aad", &ciphertext),
            Err(CryptoError::KeyEpochUnavailable)
        );
    }

    #[test]
    fn nonce_reuse_is_rejected_before_ciphertext_is_reused() {
        let (sender_identity, receiver_identity) = identities();
        let mut sender = CryptoContext::from_identity(
            &sender_identity,
            *receiver_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let nonce = [7u8; GCM_NONCE_BYTES];
        sender.encrypt_with_nonce(b"aad", b"one", nonce).unwrap();
        assert_eq!(
            sender.encrypt_with_nonce(b"aad", b"two", nonce),
            Err(CryptoError::NonceReuse)
        );
    }

    #[test]
    fn reliable_delivery_can_authenticate_an_exact_duplicate_for_dedup() {
        let (sender_identity, receiver_identity) = identities();
        let mut sender = CryptoContext::from_identity(
            &sender_identity,
            *receiver_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let mut receiver = CryptoContext::from_identity(
            &receiver_identity,
            *sender_identity.public_e2e_key().as_bytes(),
            "session-a",
        )
        .unwrap();
        let ciphertext = sender.encrypt(b"message-aad", b"reliable payload").unwrap();
        assert_eq!(
            receiver
                .decrypt_for_delivery(b"message-aad", &ciphertext)
                .unwrap(),
            b"reliable payload"
        );
        assert_eq!(
            receiver
                .decrypt_for_delivery(b"message-aad", &ciphertext)
                .unwrap(),
            b"reliable payload"
        );
        assert_eq!(
            receiver.decrypt(b"message-aad", &ciphertext),
            Err(CryptoError::ReplayDetected)
        );
    }

    #[test]
    fn structured_nonce_is_unique_across_one_hundred_thousand_messages() {
        let mut context = CryptoContext::from_session_root([0x31; 32], true);
        let mut nonces = HashSet::with_capacity(100_000);
        for _ in 0..100_000 {
            let envelope = context.encrypt(b"nonce-test", b"payload").unwrap();
            assert!(nonces.insert(envelope[14..26].to_vec()));
        }
        assert_eq!(nonces.len(), 100_000);
    }

    #[test]
    fn missing_session_root_rejects_the_e2ee_default() {
        assert!(matches!(
            SessionCryptoManager::new().get("peer", "session"),
            Err(CryptoError::E2eeRequired)
        ));
    }

    #[test]
    fn session_manager_preserves_context_across_route_changes_until_close() {
        let (sender_identity, receiver_identity) = identities();
        let manager = SessionCryptoManager::new();
        let first = manager
            .get_or_create(
                "peer",
                "session",
                &sender_identity,
                *receiver_identity.public_e2e_key().as_bytes(),
            )
            .unwrap();
        let second = manager
            .get_or_create(
                "peer",
                "session",
                &sender_identity,
                *receiver_identity.public_e2e_key().as_bytes(),
            )
            .unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert!(manager.contains("peer", "session"));
        manager.remove_session("peer", "session");
        assert!(!manager.contains("peer", "session"));
    }

    #[test]
    fn every_install_is_a_fresh_root_never_reused_across_connections() {
        // §18：每次连接安装全新 root。即使同一 (peer, alias) 再次安装，也绝不复用
        // 旧 context（ContinueExisting 已删除）。
        let manager = SessionCryptoManager::new();
        let first = manager
            .install_material_aliases("peer", &["local-a", "remote-a"], [1u8; 32], true)
            .unwrap();
        let second = manager
            .install_material_aliases("peer", &["local-a", "remote-a"], [2u8; 32], true)
            .unwrap();
        assert!(!Arc::ptr_eq(&first, &second));
        // 安装新 root 会 retire 该 peer 的所有旧 alias。
        let third = manager
            .install_material_aliases("peer", &["local-b", "remote-b"], [3u8; 32], true)
            .unwrap();
        assert!(!Arc::ptr_eq(&first, &third));
        assert!(manager.get("peer", "local-a").is_err());
        assert!(manager.get("peer", "remote-a").is_err());
        assert!(manager.get("peer", "local-b").is_ok());
        assert!(manager.get("peer", "remote-b").is_ok());
    }

    #[test]
    fn offer_round_trip_and_file_aad_bind_the_application_context() {
        let recipient = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let session_id = [0x42; 16];
        let envelope = encrypt_application_offer(
            b"offer",
            *X25519PublicKey::from(&recipient).as_bytes(),
            &session_id,
        )
        .unwrap();
        assert_eq!(
            decrypt_application_offer(&envelope, &recipient, &session_id).unwrap(),
            b"offer"
        );
        assert_ne!(
            file_chunk_aad("session", "transfer", &"a".repeat(64), 1),
            file_chunk_aad("session", "transfer", &"a".repeat(64), 2)
        );
    }

    #[test]
    fn sequence_cannot_wrap() {
        assert_eq!(next_sequence(0).unwrap(), 1);
        assert_eq!(next_sequence(u64::MAX), Err(CryptoError::SequenceOverflow));
    }
}
