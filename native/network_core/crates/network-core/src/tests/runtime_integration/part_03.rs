/// 验证直连 QUIC 认证和审批门控文件传输。
#[test]
fn two_runtimes_authenticate_and_transfer_a_verified_file() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let requested_address_a = SocketAddr::from(([127, 0, 0, 1], 0));
    let requested_address_b = SocketAddr::from(([127, 0, 0, 1], 0));
    let identity_seed_a = [11u8; 32];
    let identity_seed_b = [22u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("device-a".into(), identity_seed_a, [31u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("device-b".into(), identity_seed_b, [32u8; 32])
            .public_identity_key()
            .to_bytes();
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-network-core-{}", rand::random::<u64>()));
    let source_dir = test_root.join("source");
    let receive_a = test_root.join("receive-a");
    let receive_b = test_root.join("receive-b");
    fs::create_dir_all(&source_dir).expect("source directory");
    let source_path = source_dir.join("payload.txt");
    let source_data = b"verified native QUIC payload";
    const TRANSFER_ID: &str = "transfer-native-1";
    fs::write(&source_path, source_data).expect("source file");

    let address_a = configure_runtime_for_test(
        &runtime_a,
        "device-a",
        identity_seed_a,
        [31u8; 32],
        requested_address_a,
        receive_a,
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "device-b",
        identity_seed_b,
        [32u8; 32],
        requested_address_b,
        receive_b.clone(),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command("peer-b", "device-b", address_b, public_key_b, [32u8; 32]),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command("peer-a", "device-a", address_a, public_key_a, [31u8; 32]),
    );
    fs::create_dir_all(&receive_b).expect("receive directory");
    fs::write(
        receive_b.join(format!("{TRANSFER_ID}.part")),
        &source_data[..8],
    )
    .expect("partial receive file");
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "connect-b".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "device-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    let connected = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(
                network_protocol::PeerStateChangedEvent {
                    peer_id,
                    state,
                    route_type,
                    ..
                }
            )) if peer_id == "device-b"
                && *state == PeerConnectionState::Connected as i32
                && *route_type == RouteType::QuicDirect as i32
        )
    });
    assert!(connected.is_some(), "peer never reached connected state");
    let route_metrics = poll_until(&runtime_a, Duration::from_secs(15), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::RouteChanged(route))
                if route.peer_id == "device-b"
                    && route.route_type == RouteType::QuicDirect as i32
        )
    });
    assert!(
        route_metrics.is_some(),
        "direct path metrics were not sampled"
    );

    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "send-file".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendFile(SendFileCommand {
                transfer_id: TRANSFER_ID.into(),
                peer_id: "device-b".into(),
                file_path: source_path.to_string_lossy().to_string(),
            })),
        },
    );
    let offer = poll_until(&runtime_b, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::IncomingTransferOffer(offer))
                if offer.transfer_id == TRANSFER_ID
        )
    });
    assert!(offer.is_some(), "receiver never emitted a file offer");
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "accept-file".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::RespondIncomingTransfer(
                RespondIncomingTransferCommand {
                    transfer_id: TRANSFER_ID.into(),
                    accept: true,
                },
            )),
        },
    );
    let completed = poll_until(&runtime_b, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::TransferCompleted(completed))
                if completed.transfer_id == TRANSFER_ID
        )
    });
    assert!(completed.is_some(), "receiver never completed the transfer");
    assert_eq!(
        fs::read(receive_b.join("payload.txt")).expect("received file"),
        source_data
    );
    fs::remove_dir_all(test_root).ok();
}

/// Exercise the native runtime data plane with the boundary sizes used by the
/// V2 acceptance contract.  This deliberately uses one live pair of
/// `NetworkRuntime`s and the command/event boundary for every case; a direct
/// QUIC stream or a transfer-manager mock would not cover the runtime wiring.
#[test]
fn two_runtimes_transfer_binary_boundary_matrix_is_verified_end_to_end() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");

    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-native-transfer-boundaries-{}",
        rand::random::<u64>()
    ));
    let source_root = test_root.join("source");
    let receive_root = test_root.join("receive");
    fs::create_dir_all(&source_root).expect("source root");

    let identity_seed_a = [171u8; 32];
    let identity_seed_b = [172u8; 32];
    let e2e_seed_a = [181u8; 32];
    let e2e_seed_b = [182u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("boundary-a".into(), identity_seed_a, e2e_seed_a)
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("boundary-b".into(), identity_seed_b, e2e_seed_b)
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "boundary-a",
        identity_seed_a,
        e2e_seed_a,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "boundary-b",
        identity_seed_b,
        e2e_seed_b,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        receive_root.clone(),
    );

    // This matrix is intentionally local-only: relay authorization must not
    // be needed for a direct QUIC transfer.
    send_and_expect_accepted(
        &runtime_a,
        upsert_command_with_routes(
            "boundary-upsert-b",
            "boundary-b",
            address_b,
            public_key_b,
            e2e_seed_b,
            true,
            false,
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command_with_routes(
            "boundary-upsert-a",
            "boundary-a",
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
            command_id: "boundary-connect-b".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "boundary-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(
        poll_until(&runtime_a, Duration::from_secs(20), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::PeerState(state))
                    if state.peer_id == "boundary-b"
                        && state.state == PeerConnectionState::Connected as i32
                        && state.route_type == RouteType::QuicDirect as i32
            )
        })
        .is_some(),
        "sender never reached a direct connected state"
    );
    assert!(
        poll_until(&runtime_b, Duration::from_secs(20), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::PeerState(state))
                    if state.peer_id == "boundary-a"
                        && state.state == PeerConnectionState::Connected as i32
                        && state.route_type == RouteType::QuicDirect as i32
            )
        })
        .is_some(),
        "receiver never reached a direct connected state"
    );

    let cases = [
        (1usize, "image.jpg", 0x11u8),
        (512 * 1024 - 1, "video.mp4", 0x22u8),
        (512 * 1024, "archive.zip", 0x33u8),
        (512 * 1024 + 1, "image.jpg", 0x44u8),
        (2 * 1024 * 1024, "video.mp4", 0x55u8),
    ];
    for (index, (size, file_name, seed)) in cases.into_iter().enumerate() {
        let source_data: Vec<u8> = (0..size)
            .map(|offset| (offset as u8).wrapping_mul(31).wrapping_add(seed))
            .collect();
        let source_directory = source_root.join(format!("case-{index}"));
        fs::create_dir_all(&source_directory).expect("case source directory");
        let source_path = source_directory.join(file_name);
        fs::write(&source_path, &source_data).expect("source payload");
        let destination_path = receive_root.join(file_name);
        // The acceptance matrix intentionally reuses the three public labels;
        // remove the verified previous case before the next same-name case.
        if destination_path.exists() {
            fs::remove_file(&destination_path).expect("remove previous verified label");
        }

        let transfer_id = format!("boundary-transfer-{index}");
        send_and_expect_accepted(
            &runtime_a,
            NetworkCommand {
                command_id: format!("boundary-send-{index}"),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::SendFile(SendFileCommand {
                    transfer_id: transfer_id.clone(),
                    peer_id: "boundary-b".into(),
                    file_path: source_path.to_string_lossy().into_owned(),
                })),
            },
        );

        let offer = poll_until(&runtime_b, Duration::from_secs(30), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::IncomingTransferOffer(offer))
                    if offer.transfer_id == transfer_id
                        && offer.file_name == file_name
                        && offer.file_size == size as u64
                        && offer.route_type == Some(RouteType::QuicDirect as i32)
            )
        })
        .unwrap_or_else(|| panic!("receiver did not offer {file_name} ({size} bytes)"));
        assert!(matches!(
            offer.payload,
            Some(network_event::Payload::IncomingTransferOffer(_))
        ));

        send_and_expect_accepted(
            &runtime_b,
            NetworkCommand {
                command_id: format!("boundary-accept-{index}"),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::RespondIncomingTransfer(
                    RespondIncomingTransferCommand {
                        transfer_id: transfer_id.clone(),
                        accept: true,
                    },
                )),
            },
        );

        let receiver_completed = poll_until(&runtime_b, Duration::from_secs(30), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::TransferCompleted(completed))
                    if completed.transfer_id == transfer_id
                        && completed.peer_id == "boundary-a"
                        && completed.local_path == destination_path.to_string_lossy()
            )
        })
        .unwrap_or_else(|| panic!("receiver did not complete {file_name} ({size} bytes)"));
        assert!(matches!(
            receiver_completed.payload,
            Some(network_event::Payload::TransferCompleted(_))
        ));

        let sender_completed = poll_until(&runtime_a, Duration::from_secs(30), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::TransferCompleted(completed))
                    if completed.transfer_id == transfer_id
                        && completed.peer_id == "boundary-b"
                        && completed.local_path.is_empty()
            )
        })
        .unwrap_or_else(|| panic!("sender did not complete {file_name} ({size} bytes)"));
        assert!(matches!(
            sender_completed.payload,
            Some(network_event::Payload::TransferCompleted(_))
        ));

        let received_data = fs::read(&destination_path).expect("received payload");
        assert_eq!(
            received_data, source_data,
            "byte mismatch for {file_name} ({size})"
        );
        let source_hash = hex::encode(Sha256::digest(&source_data));
        let received_hash = hex::encode(Sha256::digest(&received_data));
        assert_eq!(
            received_hash, source_hash,
            "SHA-256 mismatch for {file_name} ({size})"
        );
    }

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}
