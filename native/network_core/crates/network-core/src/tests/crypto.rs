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
