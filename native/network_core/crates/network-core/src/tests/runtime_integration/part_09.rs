/// 对端 runtime 重启会携带新的本地 Session binding；接收端必须换代本地
/// Session/Crypto alias，而不是把新的 Root 当作旧 Session 的普通 reconnect。
#[test]
fn peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery() {
    let runtime_a1 = NetworkRuntime::new().expect("runtime A1");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a1.start().expect("start runtime A1");
    runtime_b.start().expect("start runtime B");
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-peer-runtime-restart-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");

    let identity_seed_a = [141u8; 32];
    let identity_seed_b = [142u8; 32];
    let e2e_seed_a = [151u8; 32];
    let e2e_seed_b = [152u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("restart-a".into(), identity_seed_a, e2e_seed_a)
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("restart-b".into(), identity_seed_b, e2e_seed_b)
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a1,
        "restart-a",
        identity_seed_a,
        e2e_seed_a,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a1"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "restart-b",
        identity_seed_b,
        e2e_seed_b,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    send_and_expect_accepted(
        &runtime_a1,
        upsert_command(
            "restart-upsert-b-a1",
            "restart-b",
            address_b,
            public_key_b,
            e2e_seed_b,
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command(
            "restart-upsert-a-b",
            "restart-a",
            address_a,
            public_key_a,
            e2e_seed_a,
        ),
    );
    send_and_expect_accepted(
        &runtime_a1,
        NetworkCommand {
            command_id: "restart-connect-a1".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "restart-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a1, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "restart-b"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());
    assert!(poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "restart-a"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());

    let state_b = runtime_b
        .state
        .lock()
        .expect("runtime B state lock")
        .clone()
        .expect("runtime B state");
    let old_b_session_id = runtime_b.handle().block_on(async {
        state_b
            .connection_sessions
            .current_session_id("restart-a")
            .await
            .expect("B1 Session ID")
    });
    let old_context = state_b
        .crypto
        .get("restart-a", &old_b_session_id.wire_key())
        .expect("B1 CryptoContext");
    let orphaned_transfer_id = "restart-orphaned-transfer";
    // §19：TransferOperation 按 transfer_id + peer_id 保存；Session 替换后保留并在
    // 新连接上 ResumeTransfer。用真实源文件 + 真实 manifest，使恢复尝试在断言前不会
    // 因源文件缺失而失败移除。
    let orphaned_source_path = test_root.join("restart-payload.bin");
    fs::write(&orphaned_source_path, b"orphan-payload").expect("orphaned transfer source");
    let orphaned_manifest = runtime_b
        .handle()
        .block_on(build_file_manifest(
            orphaned_transfer_id.into(),
            &orphaned_source_path,
        ))
        .expect("build orphaned transfer manifest");
    runtime_b.handle().block_on(async {
        assert!(
            state_b
                .transfer
                .manager
                .register_outgoing(orphaned_manifest, orphaned_source_path, "restart-a".into())
                .await
        );
        assert!(
            state_b
                .transfer
                .manager
                .mark_transferring(orphaned_transfer_id)
                .await
        );
        assert!(
            state_b
                .transfer
                .manager
                .pause_for_network(orphaned_transfer_id)
                .await
        );
    });
    // 在 Peer 业务作用域下 enqueue 一条未 ACK 的 pending 消息（§20）：peer
    // restart 后 ReplaceWithNew 不得清理它；新连接通过 Peer 作用域以同一个
    // MessageId 恢复重发。
    let old_pending = runtime_b
        .handle()
        .block_on(state_b.delivery.enqueue(
            "restart-a",
            "control",
            b"old-session-pending".to_vec(),
            crate::delivery::DeliveryPolicy::AckedDeduplicated,
            Default::default(),
        ))
        .expect("enqueue old-session pending");
    let old_pending_message_id = old_pending.message_id;

    let a_port = address_a.port();
    runtime_a1.stop().expect("stop runtime A1");
    drop(runtime_a1);

    assert!(poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "restart-a"
                    && state.state == PeerConnectionState::Disconnected as i32
        )
    })
    .is_some());

    let runtime_a2 = NetworkRuntime::new().expect("runtime A2");
    runtime_a2.start().expect("start runtime A2");
    let address_a2 = configure_runtime_for_test(
        &runtime_a2,
        "restart-a",
        identity_seed_a,
        e2e_seed_a,
        SocketAddr::from(([127, 0, 0, 1], a_port)),
        test_root.join("receive-a2"),
    );
    assert_eq!(address_a2.port(), a_port);
    send_and_expect_accepted(
        &runtime_a2,
        upsert_command(
            "restart-upsert-b-a2",
            "restart-b",
            address_b,
            public_key_b,
            e2e_seed_b,
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "restart-connect-b2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "restart-a".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(wait_for_session_connected(
        &runtime_b,
        "restart-a",
        Duration::from_secs(20)
    ));
    assert!(wait_for_session_connected(
        &runtime_a2,
        "restart-b",
        Duration::from_secs(20)
    ));
    let new_b_session_id = runtime_b.handle().block_on(async {
        state_b
            .connection_sessions
            .current_session_id("restart-a")
            .await
            .expect("B2 Session ID")
    });
    assert_ne!(old_b_session_id, new_b_session_id);
    // §19/§20：业务状态（pending Delivery / paused Transfer）属于 Peer 业务
    // 作用域，Session 替换/销毁后必须保留。新连接（新 SessionId）通过 Peer
    // 作用域恢复该 pending，并以同一个 MessageId 重发——不再是旧 Session 专属、
    // 不跨 Session 恢复的模型。
    let peer_snapshot = runtime_b
        .handle()
        .block_on(state_b.delivery.recover_peer("restart-a"));
    assert!(
        peer_snapshot
            .messages
            .iter()
            .any(|message| message.message_id == old_pending_message_id),
        "Peer-scoped pending Delivery must survive Session replacement and be recoverable on the next connection"
    );
    let stale_context = state_b
        .crypto
        .get("restart-a", &old_b_session_id.wire_key());
    let current_remote_binding = runtime_b.handle().block_on(async {
        state_b
            .connection_sessions
            .current_remote_session_binding("restart-a")
            .await
    });
    let state_a2 = runtime_a2
        .state
        .lock()
        .expect("runtime A2 state lock")
        .clone()
        .expect("runtime A2 state");
    let current_a2_session_id = runtime_a2.handle().block_on(async {
        state_a2
            .connection_sessions
            .current_session_id("restart-b")
            .await
    });
    assert!(
        stale_context.is_err(),
        "old B1 alias survived: old={old_b_session_id:?}, new={new_b_session_id:?}, remote={current_remote_binding:?}, a2={current_a2_session_id:?}, same_context={}",
        stale_context
            .as_ref()
            .is_ok_and(|context| Arc::ptr_eq(context, &old_context))
    );
    let new_context = state_b
        .crypto
        .get("restart-a", &new_b_session_id.wire_key())
        .expect("B2 CryptoContext");
    assert!(!Arc::ptr_eq(&old_context, &new_context));
    assert!(runtime_b.handle().block_on(async {
        state_b
            .transfer
            .manager
            .snapshot(orphaned_transfer_id)
            .await
            .is_some()
    }));

    send_and_expect_accepted(
        &runtime_a2,
        NetworkCommand {
            command_id: "restart-send-e2ee".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "restart-b".into(),
                channel_id: "control".into(),
                payload: b"after-peer-restart".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
            })),
        },
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == "restart-a"
                    && message.payload == b"after-peer-restart"
        )
    })
    .expect("post-restart E2EE message");
    let (session_id, message_id) = match received.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "restart-ack-e2ee".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "restart-a".into(),
                    session_id,
                    channel_id: "control".into(),
                    message_id,
                },
            )),
        },
    );
    assert!(poll_until(&runtime_a2, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                ..
            })) if peer_id == "restart-b"
        )
    })
    .is_some());

    runtime_a2.stop().expect("stop runtime A2");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

