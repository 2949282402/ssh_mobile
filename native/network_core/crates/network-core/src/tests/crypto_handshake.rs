use super::*;
use network_identity::DeviceIdentity;
use network_transport::{TcpTransport, Transport};
use tokio::net::TcpListener;

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
    let responder_proof =
        proof_payload_with_signature(&responder, 2, &responder_binding, responder_local_binding)
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

    let initiator_proof = proof_payload_with_signature(&initiator, 1, binding, binding).unwrap();
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
    assert!(responder_material.has_application_e2ee());
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
    let (initiator, responder, binding) =
        completed_identity_handshake_with_policy(path_handshake::E2eePolicy::Disabled);
    let initiator = initiator
        .into_established_with_policy(binding.to_string(), path_handshake::E2eePolicy::Disabled)
        .unwrap();
    let responder = responder
        .into_established_with_policy(binding.to_string(), path_handshake::E2eePolicy::Disabled)
        .unwrap();
    let (responder, encrypted_binding) = responder.begin_identity_only("0000000000000002").unwrap();
    let initiator = initiator
        .accept_identity_only_binding(&encrypted_binding)
        .unwrap();
    assert_eq!(initiator.remote_session_binding, "0000000000000002");
    let (initiator, encrypted_confirm) = initiator.confirm("0000000000000003".to_string()).unwrap();
    let (encrypted_accept, responder_material) =
        responder.accept_confirm(&encrypted_confirm).unwrap();
    let initiator_material = initiator.accept(&encrypted_accept).unwrap();
    assert_eq!(initiator_material.root_key, [0u8; 32]);
    assert_eq!(responder_material.root_key, [0u8; 32]);
    assert!(!initiator_material.has_application_e2ee());
    assert!(!responder_material.has_application_e2ee());
    assert_eq!(
        initiator_material.path_security,
        path_handshake::PathSecurity::IdentityOnly
    );
    assert_eq!(
        responder_material.path_security,
        path_handshake::PathSecurity::IdentityOnly
    );
    assert_eq!(initiator_material.local_session_binding, "0000000000000003");
    assert_eq!(
        initiator_material.remote_session_binding,
        "0000000000000002"
    );
    assert_eq!(responder_material.local_session_binding, "0000000000000002");
    assert_eq!(
        responder_material.remote_session_binding,
        "0000000000000003"
    );
    assert_eq!(
        initiator_material.e2ee_policy,
        path_handshake::E2eePolicy::Disabled
    );
    assert_eq!(
        responder_material.e2ee_policy,
        path_handshake::E2eePolicy::Disabled
    );
}

#[test]
fn disabled_policy_never_enters_the_root_exchange() {
    let (initiator, responder, binding) =
        completed_identity_handshake_with_policy(path_handshake::E2eePolicy::Disabled);
    let initiator = initiator
        .into_established_with_policy(binding.clone(), path_handshake::E2eePolicy::Disabled)
        .unwrap();
    let responder = responder
        .into_established_with_policy(binding, path_handshake::E2eePolicy::Disabled)
        .unwrap();
    assert!(responder.begin_responder("0000000000000002").is_err());
    assert!(initiator
        .accept_root_seed(&[0u8; ROOT_SEED_BYTES + NOISE_TRANSPORT_TAG_BYTES])
        .is_err());
}

#[test]
fn relay_disabled_policy_fails_closed_before_noise_root_exchange() {
    let (initiator_identity, responder_identity) = identities();
    let binding = "0000000000000001";
    assert!(matches!(
        RelayInitiatorHandshake::start_with_policy(
            Arc::clone(&initiator_identity),
            binding,
            path_handshake::E2eePolicy::Disabled,
        ),
        Err(CryptoHandshakeError::Path(
            path_handshake::PathHandshakeError::RelayRequiresE2ee
        ))
    ));

    let (_, hello) = RelayInitiatorHandshake::start(initiator_identity, binding).unwrap();
    assert!(matches!(
        RelayResponderHandshake::accept_hello_with_policy(
            responder_identity,
            &hello,
            path_handshake::E2eePolicy::Disabled,
        ),
        Err(CryptoHandshakeError::Path(
            path_handshake::PathHandshakeError::RelayRequiresE2ee
        ))
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
            root_exchange_payload(ROOT_EXCHANGE_ROOT_SEED, binding, &vec![7u8; length]).unwrap();
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

#[test]
fn relay_frames_and_exchange_payloads_enforce_wire_boundaries() {
    for step in [
        RELAY_CRYPTO_HELLO,
        RELAY_CRYPTO_RESPONSE,
        RELAY_CRYPTO_FINAL,
        RELAY_CRYPTO_ROOT_SEED,
        RELAY_CRYPTO_ROOT_CONFIRM,
        RELAY_CRYPTO_ACCEPT,
    ] {
        let frame = encode_relay_frame(step, b"payload").expect("valid relay frame");
        let decoded = decode_relay_frame(&frame).expect("decode relay frame");
        assert_eq!(decoded, (step, b"payload".as_slice()));
    }
    assert!(encode_relay_frame(0, b"payload").is_err());
    assert!(encode_relay_frame(RELAY_CRYPTO_HELLO, &[]).is_err());
    assert!(
        encode_relay_frame(RELAY_CRYPTO_HELLO, &vec![0; MAX_HANDSHAKE_FRAME_BYTES + 1]).is_err()
    );
    assert!(decode_relay_frame(&[]).is_err());
    assert!(decode_relay_frame(&[0, 1]).is_err());

    let binding = "00112233445566778899aabbccddeeff";
    let root = root_exchange_payload(ROOT_EXCHANGE_ROOT_SEED, binding, b"seed")
        .expect("root exchange payload");
    assert_eq!(
        parse_root_exchange_payload(&root, ROOT_EXCHANGE_ROOT_SEED, binding).unwrap(),
        b"seed"
    );
    assert!(parse_root_exchange_payload(&root, ROOT_EXCHANGE_ROOT_CONFIRM, binding).is_err());
    assert!(root_exchange_payload(0, binding, b"seed").is_err());
    assert!(root_exchange_payload(
        ROOT_EXCHANGE_ROOT_SEED,
        binding,
        &vec![0; MAX_HANDSHAKE_PAYLOAD_BYTES + 1]
    )
    .is_err());

    let seed = [7u8; ROOT_SEED_BYTES];
    let seed_with_binding = root_seed_payload(&seed, binding).expect("root seed");
    assert!(seed_with_binding.len() > ROOT_SEED_BYTES);
    let encoded_seed =
        root_exchange_payload(ROOT_EXCHANGE_ROOT_SEED, binding, &seed).expect("encoded root seed");
    assert_eq!(
        parse_fixed_root_exchange_payload::<ROOT_SEED_BYTES>(
            &encoded_seed,
            ROOT_EXCHANGE_ROOT_SEED,
            binding,
        )
        .unwrap()
        .as_slice(),
        seed.as_slice(),
    );
    let identity_only = identity_only_binding_payload(binding).expect("identity binding");
    assert_eq!(
        parse_identity_only_binding_payload(&identity_only).unwrap(),
        binding
    );
    assert!(parse_identity_only_binding_payload(&[0, 1, b'x']).is_err());
    assert!(validate_binding("").is_err());
    assert!(validate_binding("not-hex").is_err());
}

#[test]
fn relay_path_metadata_rejects_wrong_kind_and_policy() {
    let binding = "00112233445566778899aabbccddeeff";
    let relay =
        relay_path_metadata(binding, path_handshake::E2eePolicy::Required).expect("relay metadata");
    assert_eq!(
        validate_relay_path_metadata(&relay, path_handshake::E2eePolicy::Required)
            .expect("relay security"),
        path_handshake::PathSecurity::E2ee
    );
    assert!(relay_path_metadata(binding, path_handshake::E2eePolicy::Disabled).is_err());

    let direct = direct_path_metadata(
        binding,
        b"direct/quic/v2".to_vec(),
        path_handshake::E2eePolicy::Required,
    )
    .expect("direct metadata");
    assert!(validate_relay_path_metadata(&direct, path_handshake::E2eePolicy::Required).is_err());
    assert!(validate_direct_path_metadata(
        &relay,
        b"direct/quic/v2",
        path_handshake::E2eePolicy::Required,
    )
    .is_err());
}

#[tokio::test]
async fn generic_identity_only_handshake_round_trips_without_application_root() {
    let (initiator_identity, responder_identity) = identities();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let address = listener.local_addr().expect("listener address");
    let trusted_key = initiator_identity.public_identity_key().to_bytes();
    let responder_for_task = Arc::clone(&responder_identity);
    let responder_task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept generic peer");
        let mut connection =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let trusted = RwLock::new(HashMap::from([("initiator".into(), trusted_key)]));
        respond_generic_with_policy(
            &mut connection,
            responder_for_task,
            &trusted,
            path_handshake::E2eePolicy::Disabled,
            |_peer_id, _remote_binding| async move { Ok(("0022".into(), ())) },
        )
        .await
    });

    let mut initiator = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), address)
        .await
        .expect("connect generic peer");
    let (material, ()) = initiate_generic_with_policy(
        &mut initiator,
        Arc::clone(&initiator_identity),
        "responder",
        responder_identity.public_identity_key().to_bytes(),
        "0011",
        path_handshake::E2eePolicy::Disabled,
        |_peer_id, _remote_binding| async move { Ok(("0011".into(), ())) },
    )
    .await
    .expect("identity-only generic handshake");
    let (peer_id, responder_material, ()) = responder_task
        .await
        .expect("responder task")
        .expect("responder handshake");

    assert_eq!(peer_id, "initiator");
    assert_eq!(material.root_key, [0; 32]);
    assert_eq!(responder_material.root_key, [0; 32]);
    assert!(!material.has_application_e2ee());
    assert!(!responder_material.has_application_e2ee());
}

#[tokio::test]
async fn generic_e2ee_handshake_round_trips_a_fresh_application_root() {
    let (initiator_identity, responder_identity) = identities();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let address = listener.local_addr().expect("listener address");
    let trusted_key = initiator_identity.public_identity_key().to_bytes();
    let responder_for_task = Arc::clone(&responder_identity);
    let responder_task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept generic peer");
        let mut connection =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let trusted = RwLock::new(HashMap::from([("initiator".into(), trusted_key)]));
        respond_generic_with_policy(
            &mut connection,
            responder_for_task,
            &trusted,
            path_handshake::E2eePolicy::Required,
            |_peer_id, _remote_binding| async move { Ok(("0022".into(), ())) },
        )
        .await
    });

    let mut initiator = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), address)
        .await
        .expect("connect generic peer");
    let (material, ()) = initiate_generic_with_policy(
        &mut initiator,
        Arc::clone(&initiator_identity),
        "responder",
        responder_identity.public_identity_key().to_bytes(),
        "0011",
        path_handshake::E2eePolicy::Required,
        |_peer_id, _remote_binding| async move { Ok(("0011".into(), ())) },
    )
    .await
    .expect("E2EE generic handshake");
    let (peer_id, responder_material, ()) = responder_task
        .await
        .expect("responder task")
        .expect("responder handshake");

    assert_eq!(peer_id, "initiator");
    assert_eq!(material.root_key, responder_material.root_key);
    assert_ne!(material.root_key, [0; 32]);
    assert!(material.has_application_e2ee());
    assert!(responder_material.has_application_e2ee());
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
            &proof_payload_with_signature(&responder, 2, &responder_binding, &responder_binding)
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
    completed_identity_handshake_with_policy(path_handshake::E2eePolicy::Required)
}

fn completed_identity_handshake_with_policy(
    e2ee_policy: path_handshake::E2eePolicy,
) -> (NoiseHandshake, NoiseHandshake, String) {
    let (initiator_identity, responder_identity) = identities();
    let binding = "0000000000000001".to_string();
    let metadata =
        direct_path_metadata(&binding, b"direct/generic/v2".to_vec(), e2ee_policy).unwrap();
    let mut initiator = NoiseHandshake::new(initiator_identity, true).unwrap();
    let mut responder = NoiseHandshake::new(responder_identity, false).unwrap();
    let hello = initiator
        .write(&hello_payload_with_path(&binding, &metadata).unwrap())
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
    let _ = initiator.read(&response).unwrap();
    let final_message = initiator
        .write(
            &proof_payload_with_signature_with_path(&initiator, 1, &binding, &binding, &metadata)
                .unwrap(),
        )
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
