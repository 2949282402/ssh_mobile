/// §20 可靠消息恢复。消息未 ACK 时 Connection 丢失，随后建立新 Connection
/// （新 SessionId 加新 Noise root），发送端以同一个 MessageId 重发，接收端按
/// MessageId 去重而不重复执行业务，显式 ACK 跨新连接完成。
///
/// transport-network v2（§18）：新连接 = 新 SessionId；pending 属于 Peer 业务
/// 作用域，连接丢失时保留。
#[test]
fn delivery_reliable_message_resends_same_message_id_after_reconnect() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-delivery-reconnect-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");

    let identity_seed_a = [161u8; 32];
    let identity_seed_b = [162u8; 32];
    let e2e_seed_a = [171u8; 32];
    let e2e_seed_b = [172u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("reconnect-a".into(), identity_seed_a, e2e_seed_a)
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("reconnect-b".into(), identity_seed_b, e2e_seed_b)
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "reconnect-a",
        identity_seed_a,
        e2e_seed_a,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "reconnect-b",
        identity_seed_b,
        e2e_seed_b,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command(
            "reconnect-upsert-b",
            "reconnect-b",
            address_b,
            public_key_b,
            e2e_seed_b,
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command(
            "reconnect-upsert-a",
            "reconnect-a",
            address_a,
            public_key_a,
            e2e_seed_a,
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "reconnect-connect-1".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "reconnect-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "reconnect-b"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());

    // 发送可靠消息；接收端收到但**不 ACK**。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "reconnect-send".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "reconnect-b".into(),
                channel_id: "control".into(),
                payload: b"reconnect-me".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
            })),
        },
    );
    let first_message = poll_until(&runtime_b, Duration::from_secs(15), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(ChannelMessageEvent {
                peer_id,
                channel_id,
                payload,
                ..
            })) if peer_id == "reconnect-a" && channel_id == "control" && payload == b"reconnect-me"
        )
    })
    .expect("receiver should observe the first delivery");
    let (first_session_id, message_id) = match first_message.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    assert_eq!(message_id.len(), 16);
    let message_id_bytes: [u8; 16] = message_id.as_slice().try_into().expect("16 bytes");

    let state_a = runtime_a
        .state
        .lock()
        .expect("runtime A state lock")
        .clone()
        .expect("runtime A state");
    let original_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("reconnect-b")
            .await
            .expect("A Session ID")
    });

    // 关闭 A→B 的当前 route：transport 丢失，A 侧 Session 被销毁；pending 保留。
    runtime_a
        .handle()
        .block_on(state_a.close_path_for_test("reconnect-b"));
    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "reconnect-b"
                    && state.state == PeerConnectionState::Disconnected as i32
        )
    })
    .is_some());

    // 业务显式重连（§35 不自动重连）；A 得到全新 SessionId + 新 Noise root。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "reconnect-connect-2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "reconnect-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "reconnect-b"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());
    let reconnected_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("reconnect-b")
            .await
            .expect("reconnected A Session ID")
    });
    assert_ne!(original_session_id, reconnected_session_id);

    // 重连后 A 以同一个 MessageId 重发；等接收端观测到该重放帧（active 记录
    // 的 wire 代数被更新），证明重放已落地并被按 MessageId 去重。
    let state_b = runtime_b
        .state
        .lock()
        .expect("runtime B state lock")
        .clone()
        .expect("runtime B state");
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut observed_replay_epoch = 0u64;
    while Instant::now() < deadline {
        observed_replay_epoch = runtime_b
            .handle()
            .block_on(state_b.delivery.incoming_recovery_epoch(
                "reconnect-a",
                "control",
                crate::delivery::MessageId::from_bytes(message_id_bytes),
            ))
            .unwrap_or(0);
        if observed_replay_epoch >= 2 {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        observed_replay_epoch >= 2,
        "receiver never observed the re-sent MessageId after reconnect"
    );

    // 接收端确认重放落地后，发送端 Peer 作用域连接代数必然已递增
    // （每次 Connection Ready 的 recover_peer 递增一次）。
    let peer_generation = runtime_a
        .handle()
        .block_on(state_a.delivery.current_peer_recovery_epoch("reconnect-b"));
    assert!(
        peer_generation >= 2,
        "sender peer generation should advance after reconnect (got {peer_generation})"
    );

    // 去重：接收端不会再次把同一个 MessageId 交给应用。
    let duplicate = poll_until(&runtime_b, Duration::from_secs(1), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.message_id == message_id
        )
    });
    assert!(
        duplicate.is_none(),
        "receiver double-delivered the same MessageId after reconnect"
    );

    // InFlight 重放不自动 ACK。
    let unexpected_ack = poll_until(&runtime_a, Duration::from_secs(1), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                ..
            })) if peer_id == "reconnect-b" && acknowledged_id == &message_id
        )
    });
    assert!(
        unexpected_ack.is_none(),
        "InFlight duplicate was incorrectly ACKed"
    );

    // 显式 ACK（携带第一次事件看到的 wire session_id；关联只认 MessageId）
    // 跨新连接完成。
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "reconnect-ack".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "reconnect-a".into(),
                    session_id: first_session_id,
                    channel_id: "control".into(),
                    message_id: message_id.clone(),
                },
            )),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                ..
            })) if peer_id == "reconnect-b" && acknowledged_id == &message_id
        )
    })
    .is_some());

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

