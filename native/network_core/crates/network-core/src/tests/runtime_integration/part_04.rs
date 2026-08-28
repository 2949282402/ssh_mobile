/// Restart the receiver runtime with the same identity/trust material on a
/// different UDP port.  The sender updates only the explicit peer endpoint
/// and connects again; no pairing exchange or relay path is involved.
#[test]
fn receiver_runtime_restart_restores_direct_trust_without_repairing() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b1 = NetworkRuntime::new().expect("runtime B1");
    runtime_a.start().expect("start runtime A");
    runtime_b1.start().expect("start runtime B1");

    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-native-receiver-restart-{}",
        rand::random::<u64>()
    ));
    let receive_root = test_root.join("receive-b");
    fs::create_dir_all(&test_root).expect("test root");

    let identity_seed_a = [191u8; 32];
    let identity_seed_b = [192u8; 32];
    let e2e_seed_a = [201u8; 32];
    let e2e_seed_b = [202u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("receiver-restart-a".into(), identity_seed_a, e2e_seed_a)
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("receiver-restart-b".into(), identity_seed_b, e2e_seed_b)
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "receiver-restart-a",
        identity_seed_a,
        e2e_seed_a,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b1 = configure_runtime_for_test(
        &runtime_b1,
        "receiver-restart-b",
        identity_seed_b,
        e2e_seed_b,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        receive_root.clone(),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command_with_routes(
            "receiver-restart-upsert-b1",
            "receiver-restart-b",
            address_b1,
            public_key_b,
            e2e_seed_b,
            true,
            false,
        ),
    );
    send_and_expect_accepted(
        &runtime_b1,
        upsert_command_with_routes(
            "receiver-restart-upsert-a1",
            "receiver-restart-a",
            address_a,
            public_key_a,
            e2e_seed_a,
            true,
            false,
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "receiver-restart-connect-b1".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "receiver-restart-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(wait_for_session_connected(
        &runtime_a,
        "receiver-restart-b",
        Duration::from_secs(20)
    ));
    assert!(wait_for_session_connected(
        &runtime_b1,
        "receiver-restart-a",
        Duration::from_secs(20)
    ));

    let old_port = address_b1.port();
    runtime_b1.stop().expect("stop receiver B1");
    drop(runtime_b1);
    assert!(
        poll_until(&runtime_a, Duration::from_secs(15), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::PeerState(state))
                    if state.peer_id == "receiver-restart-b"
                        && state.state == PeerConnectionState::Disconnected as i32
            )
        })
        .is_some(),
        "sender never observed receiver runtime shutdown"
    );

    // Reserve a known-unused port different from B1 before configuring B2 so
    // this assertion does not depend on the OS ephemeral-port allocator.
    let new_port = loop {
        let guard = std::net::UdpSocket::bind(("127.0.0.1", 0)).expect("reserve new UDP port");
        let candidate = guard.local_addr().expect("reserved UDP address").port();
        if candidate != old_port {
            drop(guard);
            break candidate;
        }
    };
    let runtime_b2 = NetworkRuntime::new().expect("runtime B2");
    runtime_b2.start().expect("start receiver B2");
    let address_b2 = configure_runtime_for_test(
        &runtime_b2,
        "receiver-restart-b",
        identity_seed_b,
        e2e_seed_b,
        SocketAddr::from(([127, 0, 0, 1], new_port)),
        receive_root.clone(),
    );
    assert_ne!(address_b2.port(), old_port, "receiver must bind a new port");

    // Reinstall the same static peer keys on the new runtime. This is trust
    // restoration from local configuration, not a new pairing ceremony.
    send_and_expect_accepted(
        &runtime_b2,
        upsert_command_with_routes(
            "receiver-restart-upsert-a2",
            "receiver-restart-a",
            address_a,
            public_key_a,
            e2e_seed_a,
            true,
            false,
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command_with_routes(
            "receiver-restart-upsert-b2",
            "receiver-restart-b",
            address_b2,
            public_key_b,
            e2e_seed_b,
            true,
            false,
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "receiver-restart-connect-b2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "receiver-restart-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(wait_for_session_connected(
        &runtime_a,
        "receiver-restart-b",
        Duration::from_secs(20)
    ));
    assert!(wait_for_session_connected(
        &runtime_b2,
        "receiver-restart-a",
        Duration::from_secs(20)
    ));

    let source_path = test_root.join("image.jpg");
    let source_data = vec![0xA5u8];
    fs::write(&source_path, &source_data).expect("restart source payload");
    let transfer_id = "receiver-restart-transfer";
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "receiver-restart-send".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendFile(SendFileCommand {
                transfer_id: transfer_id.into(),
                peer_id: "receiver-restart-b".into(),
                file_path: source_path.to_string_lossy().into_owned(),
            })),
        },
    );
    let destination_path = receive_root.join("image.jpg");
    let offer = poll_until(&runtime_b2, Duration::from_secs(30), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::IncomingTransferOffer(offer))
                if offer.transfer_id == transfer_id
                    && offer.file_name == "image.jpg"
                    && offer.file_size == 1
                    && offer.route_type == Some(RouteType::QuicDirect as i32)
        )
    });
    assert!(
        offer.is_some(),
        "receiver B2 did not emit the direct transfer offer"
    );
    send_and_expect_accepted(
        &runtime_b2,
        NetworkCommand {
            command_id: "receiver-restart-accept".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::RespondIncomingTransfer(
                RespondIncomingTransferCommand {
                    transfer_id: transfer_id.into(),
                    accept: true,
                },
            )),
        },
    );
    assert!(
        poll_until(&runtime_b2, Duration::from_secs(30), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::TransferCompleted(completed))
                    if completed.transfer_id == transfer_id
                        && completed.peer_id == "receiver-restart-a"
                        && completed.local_path == destination_path.to_string_lossy()
            )
        })
        .is_some(),
        "receiver B2 did not complete the transfer"
    );
    assert!(
        poll_until(&runtime_a, Duration::from_secs(30), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::TransferCompleted(completed))
                    if completed.transfer_id == transfer_id
                        && completed.peer_id == "receiver-restart-b"
                        && completed.local_path.is_empty()
            )
        })
        .is_some(),
        "sender did not complete the post-restart transfer"
    );
    let received_data = fs::read(&destination_path).expect("restart received payload");
    assert_eq!(received_data, source_data);
    assert_eq!(
        hex::encode(Sha256::digest(&received_data)),
        hex::encode(Sha256::digest(&source_data))
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b2.stop().expect("stop receiver B2");
    fs::remove_dir_all(test_root).ok();
}
