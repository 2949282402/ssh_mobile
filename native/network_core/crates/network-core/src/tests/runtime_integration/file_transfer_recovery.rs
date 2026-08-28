/// §40 Recovery：文件传输中断（TransferOperation = PAUSED，§19）→ ConnectionSession
/// 销毁 → 重新建连（新 ConnectionSession + 新 Noise root）→ `ResumeTransfer(transfer_id)`
/// 与对端协商 confirmed_offset（checkpoint）→ 从 checkpoint 继续，最终完成。
///
/// 传输状态按 transfer_id + peer_id 保存在 TransferManager，不依赖 SessionId；新连接
/// 建立后由 ConnectivityAttemptCoordinator 触发 `resume_transfers_for_peer`
/// 领取暂停传输并在新连接上恢复。
#[test]
fn file_transfer_resumes_across_a_fresh_connection() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-transfer-resume-{}",
        rand::random::<u64>()
    ));
    let source_dir = test_root.join("source");
    let receive_b = test_root.join("receive-b");
    fs::create_dir_all(&source_dir).expect("source directory");
    fs::create_dir_all(&receive_b).expect("receive directory");
    let source_path = source_dir.join("payload.bin");
    let source_data: Vec<u8> = (0..1024u32).map(|i| (i % 251) as u8).collect();
    fs::write(&source_path, &source_data).expect("source file");
    const TRANSFER_ID: &str = "resume-transfer-1";
    const CONFIRMED_OFFSET: u64 = 256;

    let identity_seed_a = [41u8; 32];
    let identity_seed_b = [42u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("resume-a".into(), identity_seed_a, [51u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("resume-b".into(), identity_seed_b, [52u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "resume-a",
        identity_seed_a,
        [51u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "resume-b",
        identity_seed_b,
        [52u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        receive_b.clone(),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command(
            "resume-upsert-b",
            "resume-b",
            address_b,
            public_key_b,
            [52u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command(
            "resume-upsert-a",
            "resume-a",
            address_a,
            public_key_a,
            [51u8; 32],
        ),
    );

    // 第一次连接（第一个 ConnectionSession）。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "resume-connect-1".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "resume-b".into(),
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
                    if state.peer_id == "resume-b"
                        && state.state == PeerConnectionState::Connected as i32
                        && state.route_type == RouteType::QuicDirect as i32
            )
        })
        .is_some(),
        "first connection never reached connected state"
    );

    let state_a = runtime_a
        .state
        .lock()
        .expect("runtime A state lock")
        .clone()
        .expect("runtime A state");
    let old_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("resume-b")
            .await
            .expect("first ConnectionSession id")
    });
    let manifest = runtime_a
        .handle()
        .block_on(build_file_manifest(TRANSFER_ID.into(), &source_path))
        .expect("build transfer manifest");
    // 模拟中断：TransferOperation 已协商到 CONFIRMED_OFFSET 后网络断开 → PAUSED。
    runtime_a.handle().block_on(async {
        assert!(
            state_a
                .transfer
                .manager
                .register_outgoing(manifest, source_path.clone(), "resume-b".into())
                .await
        );
        assert!(
            state_a
                .transfer
                .manager
                .mark_transferring(TRANSFER_ID)
                .await
        );
        assert!(
            state_a
                .transfer
                .manager
                .update_progress(TRANSFER_ID, CONFIRMED_OFFSET)
                .await
        );
        assert!(
            state_a
                .transfer
                .manager
                .pause_for_network(TRANSFER_ID)
                .await
        );
    });
    // 接收端保留同 checkpoint 的 `.part` 文件。
    fs::write(
        receive_b.join(format!("{TRANSFER_ID}.part")),
        &source_data[..CONFIRMED_OFFSET as usize],
    )
    .expect("receiver partial checkpoint");

    // transport 丢失：销毁 ConnectionSession（§19：ConnectionSession=DESTROYED，
    // TransferOperation=PAUSED 保留在 TransferManager）。
    runtime_a.handle().block_on(async {
        crate::connect::connectivity_attempt::tests::close_session_and_unregister(
            Arc::clone(&state_a),
            "resume-b".into(),
            old_session_id,
        )
        .await;
    });
    assert!(
        poll_until(&runtime_b, Duration::from_secs(10), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::PeerState(state))
                    if state.peer_id == "resume-a"
                        && state.state == PeerConnectionState::Disconnected as i32
            )
        })
        .is_some(),
        "receiver never observed the transport loss"
    );

    // 重新建连（新 ConnectionSession）→ ConnectivityAttemptCoordinator 触发
    // ResumeTransfer(transfer_id)。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "resume-connect-2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "resume-b".into(),
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
                    if state.peer_id == "resume-b"
                        && state.state == PeerConnectionState::Connected as i32
                        && state.route_type == RouteType::QuicDirect as i32
            )
        })
        .is_some(),
        "fresh connection never reached connected state"
    );
    let new_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("resume-b")
            .await
            .expect("fresh ConnectionSession id")
    });
    assert_ne!(
        old_session_id, new_session_id,
        "fresh connection must get a fresh SessionId"
    );

    // 接收端收到 ResumeTransfer 的重新 Offer；协商 confirmed_offset 后从 checkpoint 继续。
    let offer = poll_until(&runtime_b, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::IncomingTransferOffer(offer))
                if offer.transfer_id == TRANSFER_ID
        )
    });
    assert!(
        offer.is_some(),
        "receiver never saw the resumed transfer offer"
    );
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "resume-accept".into(),
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
    assert!(
        completed.is_some(),
        "resumed transfer never completed across the fresh connection"
    );
    assert_eq!(
        fs::read(receive_b.join("payload.bin")).expect("received resumed file"),
        source_data
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}
