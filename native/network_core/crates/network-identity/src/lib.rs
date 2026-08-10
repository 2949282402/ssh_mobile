//! Device identity management, signing/verifying, and key segregation.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret};

/// Enforces strict key segregation between device identity and E2E encryption.
pub struct DeviceIdentity {
    pub device_id: String,
    pub identity_key: SigningKey,
    pub e2e_key: StaticSecret,
}

impl DeviceIdentity {
    pub fn generate(device_id: String) -> Self {
        let mut csprng = OsRng;
        let identity_key = SigningKey::generate(&mut csprng);
        let e2e_key = StaticSecret::random_from_rng(csprng);

        Self {
            device_id,
            identity_key,
            e2e_key,
        }
    }

    /// Restores the two independent long-lived device keys supplied by the
    /// platform secure-storage layer.
    pub fn from_private_keys(
        device_id: String,
        identity_private_key: [u8; 32],
        e2e_private_key: [u8; 32],
    ) -> Self {
        Self {
            device_id,
            identity_key: SigningKey::from_bytes(&identity_private_key),
            e2e_key: StaticSecret::from(e2e_private_key),
        }
    }

    pub fn public_identity_key(&self) -> VerifyingKey {
        self.identity_key.verifying_key()
    }

    pub fn public_e2e_key(&self) -> XPublicKey {
        XPublicKey::from(&self.e2e_key)
    }

    pub fn sign_proof(&self, nonce: &[u8]) -> Vec<u8> {
        let signature: Signature = self.identity_key.sign(nonce);
        signature.to_bytes().to_vec()
    }

    pub fn verify_peer_proof(
        peer_key: &VerifyingKey,
        nonce: &[u8],
        signature_bytes: &[u8],
    ) -> bool {
        if signature_bytes.len() != 64 {
            return false;
        }
        let mut bytes = [0u8; 64];
        bytes.copy_from_slice(signature_bytes);
        let signature = Signature::from_bytes(&bytes);
        peer_key.verify(nonce, &signature).is_ok()
    }
}
