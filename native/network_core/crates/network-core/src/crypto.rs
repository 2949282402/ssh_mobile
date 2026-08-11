//! Relay E2E cryptography shared by offer and data-plane processing.
//!
//! The Relay server only forwards the envelope and opaque chunks. This module
//! keeps key derivation, nonce construction, associated data, and AEAD usage in
//! one place so control and data frames cannot silently drift apart.

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use std::fmt;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

/// The negotiated Relay crypto suite carried inside the encrypted offer.
///
/// The outer envelope remains opaque to the Relay service. A suite marker in
/// the clear offer makes an upgrade fail closed instead of accidentally
/// interpreting old raw-X25519-key material with the new derivation.
pub(crate) const RELAY_CRYPTO_SUITE: &str = "hkdf-sha256-aes256gcm-v1";

const OFFER_KDF_INFO: &[u8] = b"ssh-mobile/relay/offer/hkdf-sha256-aes256gcm-v1";
const CHUNK_KDF_INFO: &[u8] = b"ssh-mobile/relay/chunk/hkdf-sha256-aes256gcm-v1";
const OFFER_AAD_PREFIX: &[u8] = b"ssh-mobile/relay/offer/v1";
const CHUNK_AAD_PREFIX: &[u8] = b"ssh-mobile/relay/chunk/v1";
const X25519_PUBLIC_KEY_BYTES: usize = 32;
const GCM_NONCE_BYTES: usize = 12;
const GCM_TAG_BYTES: usize = 16;

/// Errors exposed by the native crypto boundary without including key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CryptoError {
    InvalidEnvelope,
    InvalidKey,
    KeyDerivation,
    Encryption,
    Decryption,
    SequenceOverflow,
}

impl fmt::Display for CryptoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidEnvelope => "invalid Relay crypto envelope",
            Self::InvalidKey => "invalid Relay crypto key",
            Self::KeyDerivation => "Relay key derivation failed",
            Self::Encryption => "Relay encryption failed",
            Self::Decryption => "Relay decryption failed",
            Self::SequenceOverflow => "Relay sequence overflow",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CryptoError {}

/// Encrypt an offer with an ephemeral X25519 key and an HKDF-derived AEAD key.
///
/// Envelope layout is intentionally unchanged: ephemeral public key (32
/// bytes), nonce (12 bytes), then AES-GCM ciphertext and tag. The session ID
/// is used as HKDF salt and authenticated associated data.
pub(crate) fn encrypt_relay_offer(
    plaintext: &[u8],
    peer_public_key: [u8; 32],
    session_id: &[u8; 16],
) -> Result<Vec<u8>, CryptoError> {
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&X25519PublicKey::from(peer_public_key));
    let key = derive_key(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
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

/// Decrypt an offer using the recipient's long-lived X25519 secret.
pub(crate) fn decrypt_relay_offer(
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
    let key = derive_key(shared.as_bytes(), session_id, OFFER_KDF_INFO)?;
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

/// AEAD context for the ordered Relay data plane.
pub(crate) struct RelayChunkCipher {
    cipher: Aes256Gcm,
    session_id: [u8; 16],
    nonce_prefix: [u8; 4],
}

impl RelayChunkCipher {
    /// Derive a per-session data key from the secret carried in the offer.
    pub(crate) fn new(
        content_secret: &[u8; 32],
        session_id: &[u8; 16],
        nonce_prefix: [u8; 4],
    ) -> Result<Self, CryptoError> {
        let key = derive_key(content_secret, session_id, CHUNK_KDF_INFO)?;
        let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CryptoError::InvalidKey)?;
        Ok(Self {
            cipher,
            session_id: *session_id,
            nonce_prefix,
        })
    }

    /// Encrypt one ordered data chunk with sequence-bound nonce and AAD.
    pub(crate) fn encrypt(&self, sequence: u64, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let nonce = chunk_nonce(self.nonce_prefix, sequence);
        let aad = chunk_aad(&self.session_id, sequence);
        self.cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| CryptoError::Encryption)
    }

    /// Decrypt one ordered data chunk with the same session-bound context.
    pub(crate) fn decrypt(&self, sequence: u64, ciphertext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        if ciphertext.len() < GCM_TAG_BYTES {
            return Err(CryptoError::InvalidEnvelope);
        }
        let nonce = chunk_nonce(self.nonce_prefix, sequence);
        let aad = chunk_aad(&self.session_id, sequence);
        self.cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| CryptoError::Decryption)
    }
}

/// Advance an ordered Relay sequence without wrapping a nonce.
pub(crate) fn next_sequence(sequence: u64) -> Result<u64, CryptoError> {
    sequence.checked_add(1).ok_or(CryptoError::SequenceOverflow)
}

fn derive_key(
    input_key_material: &[u8],
    salt: &[u8; 16],
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

fn chunk_nonce(nonce_prefix: [u8; 4], sequence: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(&nonce_prefix);
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    nonce
}

fn chunk_aad(session_id: &[u8; 16], sequence: u64) -> Vec<u8> {
    let mut aad =
        Vec::with_capacity(CHUNK_AAD_PREFIX.len() + session_id.len() + std::mem::size_of::<u64>());
    aad.extend_from_slice(CHUNK_AAD_PREFIX);
    aad.extend_from_slice(session_id);
    aad.extend_from_slice(&sequence.to_be_bytes());
    aad
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offer_round_trip_uses_hkdf_and_session_binding() {
        let sender = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let recipient = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let session_id = [0x42; 16];
        let plaintext = b"relay offer metadata";

        let envelope = encrypt_relay_offer(
            plaintext,
            *X25519PublicKey::from(&recipient).as_bytes(),
            &session_id,
        )
        .expect("offer encryption should succeed");
        let clear = decrypt_relay_offer(&envelope, &recipient, &session_id)
            .expect("offer decryption should succeed");
        assert_eq!(clear, plaintext);

        let shared = sender.diffie_hellman(&X25519PublicKey::from(&recipient));
        let derived = derive_key(shared.as_bytes(), &session_id, OFFER_KDF_INFO)
            .expect("HKDF should derive a key");
        assert_ne!(derived, *shared.as_bytes());
        assert!(decrypt_relay_offer(&envelope, &recipient, &[0x43; 16]).is_err());
    }

    #[test]
    fn offer_rejects_tampering_and_wrong_recipient() {
        let recipient = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let wrong_recipient = StaticSecret::random_from_rng(rand::rngs::OsRng);
        let session_id = [7u8; 16];
        let mut envelope = encrypt_relay_offer(
            b"metadata",
            *X25519PublicKey::from(&recipient).as_bytes(),
            &session_id,
        )
        .expect("offer encryption should succeed");
        *envelope.last_mut().expect("tag must exist") ^= 1;

        assert!(decrypt_relay_offer(&envelope, &recipient, &session_id).is_err());
        assert!(decrypt_relay_offer(&envelope, &wrong_recipient, &session_id).is_err());
    }

    #[test]
    fn chunk_cipher_binds_session_and_sequence() {
        let content_secret = [9u8; 32];
        let session_id = [8u8; 16];
        let nonce_prefix = [7u8; 4];
        let sender = RelayChunkCipher::new(&content_secret, &session_id, nonce_prefix)
            .expect("chunk cipher should initialize");
        let receiver = RelayChunkCipher::new(&content_secret, &session_id, nonce_prefix)
            .expect("chunk cipher should initialize");
        let ciphertext = sender
            .encrypt(3, b"chunk")
            .expect("chunk encryption should succeed");

        assert_eq!(receiver.decrypt(3, &ciphertext).unwrap(), b"chunk");
        assert!(receiver.decrypt(2, &ciphertext).is_err());
        assert!(
            RelayChunkCipher::new(&content_secret, &[6u8; 16], nonce_prefix)
                .unwrap()
                .decrypt(3, &ciphertext)
                .is_err()
        );
    }

    #[test]
    fn sequence_cannot_wrap() {
        assert_eq!(next_sequence(0).unwrap(), 1);
        assert_eq!(next_sequence(u64::MAX), Err(CryptoError::SequenceOverflow));
    }
}
