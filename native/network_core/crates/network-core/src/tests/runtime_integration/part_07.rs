/// 验证未 ACK 的消息在显式 recovery 后以**同一个 MessageId** 重放，接收端
/// dedup 不会再次把同一个 MessageId 交给应用（§20），显式 ACK 只按 MessageId
/// 关联、不依赖连接代数对齐。
///
/// recovery 通过显式驱动（连接保持稳定）；真实 Connection 断开重连场景由
/// `delivery_reliable_message_resends_same_message_id_after_reconnect` 覆盖。
#[test]
fn delivery_recovery_replays_same_message_after_explicit_recovery() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let requested_address_a = SocketAddr::from(([127, 0, 0, 1], 0));
    let requested_address_b = SocketAddr::from(([127, 0, 0, 1], 0));
    let identity_seed_a = [41u8; 32];
    let identity_seed_b = [42u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("delivery-a".into(), identity_seed_a, [51u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("delivery-b".into(), identity_seed_b, [52u8; 32])
            .public_identity_key()
            .to_bytes();
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-delivery-recovery-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");

    let address_a = configure_runtime_for_test(
        &runtime_a,
        "delivery-a",
        identity_seed_a,
        [51u8; 32],
        requested_address_a,
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "delivery-b",
        identity_seed_b,
        [52u8; 32],
        requested_address_b,
        test_root.join("receive-b"),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command(
            "delivery-upsert-b",
            "delivery-b",
            address_b,
            public_key_b,
            [52u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command(
            "delivery-upsert-a",
            "delivery-a",
            address_a,
            public_key_a,
            [51u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "delivery-connect".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "delivery-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "delivery-b"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());

    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "delivery-send".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "delivery-b".into(),
                channel_id: "control".into(),
                payload: b"recover-me".to_vec(),
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
            })) if peer_id == "delivery-a" && channel_id == "control" && payload == b"recover-me"
        )
    })
    .expect("receiver should observe the first delivery");
    let (session_id, message_id) = match first_message.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    assert_ne!(session_id, "delivery-b");
    assert_eq!(message_id.len(), 16);

    // 连接保持稳定；显式驱动一次确定性 recovery，把未 ACK 消息以同一个
    // MessageId 重放一次（§20）。验证重放被按 MessageId 去重、不重新发布事件、
    // 不自动 ACK。ACK 不再依赖 recovery epoch 对齐——关联只认 MessageId。
    let recovered_session = runtime_a
        .recover_current_peer_for_test("delivery-b")
        .expect("current session exists");
    assert_eq!(
        recovered_session, session_id,
        "deterministic recovery should drive the same session"
    );

    // 不在第一次事件后 ACK；recovery 重放的重复 DataMessage 仍处于 InFlight，
    // 所以接收端既不重新发布事件，也不能自动 ACK。
    let unexpected_ack = poll_until(&runtime_a, Duration::from_secs(1), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                ..
            })) if peer_id == "delivery-b" && acknowledged_id == &message_id
        )
    });
    assert!(
        unexpected_ack.is_none(),
        "InFlight duplicate was incorrectly ACKed"
    );

    // 重放不会让接收端再次进入应用 handler（MessageId 去重）。
    let duplicate = poll_until(&runtime_b, Duration::from_secs(1), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.message_id == message_id
        )
    });
    assert!(duplicate.is_none(), "dedup delivered the message twice");
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "delivery-ack-recovered".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "delivery-a".into(),
                    session_id: session_id.clone(),
                    channel_id: "control".into(),
                    message_id: message_id.clone(),
                },
            )),
        },
    );
    // ACK 按 MessageId 完成，无论携带的连接代数是多少。
    let recovered_ack = poll_until(&runtime_a, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                ..
            })) if peer_id == "delivery-b" && acknowledged_id == &message_id
        )
    });
    assert!(
        recovered_ack.is_some(),
        "explicit ACK did not complete the recovered MessageId"
    );

    // 再发一条新消息，验证应用在收到事件后显式提交 AcknowledgeMessage，
    // 而不是只依赖 transport-level ACK。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "delivery-send-explicit-ack".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "delivery-b".into(),
                channel_id: "control".into(),
                payload: b"application-ack".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
                // Explicit opt-out exercises the clear application mode; the
                // first message in this test remains the secure default.
            })),
        },
    );
    let explicit_message = poll_until(&runtime_b, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.payload == b"application-ack"
        )
    })
    .expect("explicit ACK message");
    let (explicit_session_id, explicit_message_id) = match explicit_message.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "delivery-ack-explicit".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "delivery-a".into(),
                    session_id: explicit_session_id,
                    channel_id: "control".into(),
                    message_id: explicit_message_id.clone(),
                },
            )),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(20), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id,
                ..
            })) if peer_id == "delivery-b" && message_id == &explicit_message_id
        )
    })
    .is_some());
    fs::remove_dir_all(test_root).ok();
}

