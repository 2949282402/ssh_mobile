use super::*;

#[test]
fn generated_identity_signs_and_verifies_a_peer_proof() {
    let identity = DeviceIdentity::generate("device-a".to_owned());
    let nonce = b"fresh-challenge";
    let signature = identity.sign_proof(nonce);

    assert_eq!(identity.device_id, "device-a");
    assert_eq!(signature.len(), 64);
    assert!(DeviceIdentity::verify_peer_proof(
        &identity.public_identity_key(),
        nonce,
        &signature,
    ));
}

#[test]
fn verification_rejects_tampering_wrong_nonce_and_wrong_peer() {
    let identity = DeviceIdentity::generate("device-a".to_owned());
    let other = DeviceIdentity::generate("device-b".to_owned());
    let signature = identity.sign_proof(b"nonce-a");

    assert!(!DeviceIdentity::verify_peer_proof(
        &identity.public_identity_key(),
        b"nonce-b",
        &signature,
    ));
    assert!(!DeviceIdentity::verify_peer_proof(
        &other.public_identity_key(),
        b"nonce-a",
        &signature,
    ));

    let mut tampered = signature.clone();
    tampered[0] ^= 0x80;
    assert!(!DeviceIdentity::verify_peer_proof(
        &identity.public_identity_key(),
        b"nonce-a",
        &tampered,
    ));
    assert!(!DeviceIdentity::verify_peer_proof(
        &identity.public_identity_key(),
        b"nonce-a",
        &signature[..63],
    ));
}

#[test]
fn restoring_private_keys_reproduces_both_public_keys() {
    let identity_bytes = [0x11_u8; 32];
    let e2e_bytes = [0x22_u8; 32];
    let identity =
        DeviceIdentity::from_private_keys("restored".to_owned(), identity_bytes, e2e_bytes);
    let restored =
        DeviceIdentity::from_private_keys("restored".to_owned(), identity_bytes, e2e_bytes);

    assert_eq!(identity.device_id, "restored");
    assert_eq!(
        identity.public_identity_key().to_bytes(),
        restored.public_identity_key().to_bytes()
    );
    assert_eq!(
        identity.public_e2e_key().as_bytes(),
        restored.public_e2e_key().as_bytes()
    );
    assert_ne!(
        identity.public_identity_key().to_bytes().as_slice(),
        identity.public_e2e_key().as_bytes()
    );
}
