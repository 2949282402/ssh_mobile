/// QUIC is intentionally closed after both runtimes bind. The same configured
/// numeric port still accepts TCP, proving that fallback is a real authenticated
/// Session route rather than a capability-only wrapper. The test also sends a
/// Delivery message and completes the application ACK through that route.
///
/// transport-network v2（§18）：transport 丢失即销毁 ConnectionSession，重新
/// connect() 必须得到**全新** SessionId（绝不复用旧 id）。
#[test]
fn tcp_fallback_authenticates_delivery_and_gets_a_fresh_session_on_reconnect() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-tcp-fallback-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [101u8; 32];
    let identity_seed_b = [102u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("tcp-a".into(), identity_seed_a, [111u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("tcp-b".into(), identity_seed_b, [112u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "tcp-a",
        identity_seed_a,
        [111u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "tcp-b",
        identity_seed_b,
        [112u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    let state_b = runtime_b
        .state
        .lock()
        .expect("runtime B state lock")
        .clone()
        .expect("runtime B state");
    runtime_b.handle().block_on(async {
        state_b
            .lifecycle
            .endpoint
            .read()
            .await
            .as_ref()
            .expect("B endpoint")
            .close(quinn::VarInt::from_u32(0), b"TCP fallback test");
    });
    send_and_expect_accepted(
        &runtime_a,
        upsert_command(
            "tcp-upsert-b",
            "tcp-b",
            address_b,
            public_key_b,
            [112u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command(
            "tcp-upsert-a",
            "tcp-a",
            address_a,
            public_key_a,
            [111u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "tcp-connect".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "tcp-b".into(),
                intent: 0,
                communication_class: CommunicationClass::ReliableStream as i32,
            })),
        },
    );
    let connected = poll_until(&runtime_a, Duration::from_secs(25), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "tcp-b"
                    && state.state == PeerConnectionState::Connected as i32
                    && state.route_transport == RouteTransport::Tcp as i32
        )
    });
    assert!(
        connected.is_some(),
        "TCP fallback route never became active"
    );
    let state_a = runtime_a
        .state
        .lock()
        .expect("runtime A state lock")
        .clone()
        .expect("runtime A state");
    let original_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("tcp-b")
            .await
            .expect("TCP Session ID")
    });

    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "tcp-send".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "tcp-b".into(),
                channel_id: "control".into(),
                payload: b"tcp-delivery".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
            })),
        },
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == "tcp-a" && message.payload == b"tcp-delivery"
        )
    })
    .expect("TCP route did not deliver the message");
    let (session_id, message_id) = match received.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "tcp-ack".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "tcp-a".into(),
                    session_id,
                    channel_id: "control".into(),
                    message_id: message_id.clone(),
                },
            )),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                ..
            })) if peer_id == "tcp-b" && acknowledged_id == &message_id
        )
    })
    .is_some());

    runtime_a
        .handle()
        .block_on(state_a.close_path_for_test("tcp-b"));
    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "tcp-b"
                    && state.state == PeerConnectionState::Disconnected as i32
        )
    })
    .is_some());
    // transport-network v2（§35）：连接丢失后不自动重连；业务重新发起 connect()。
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "tcp-reconnect".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "tcp-b".into(),
                intent: 0,
                communication_class: CommunicationClass::ReliableStream as i32,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(25), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "tcp-b"
                    && state.state == PeerConnectionState::Connected as i32
                    && state.route_transport == RouteTransport::Tcp as i32
        )
    })
    .is_some());
    let reconnected_session_id = runtime_a.handle().block_on(async {
        state_a
            .connection_sessions
            .current_session_id("tcp-b")
            .await
            .expect("reconnected TCP Session ID")
    });
    // §18 1:1：新连接 = 新 ConnectionSession = 新 SessionId。
    assert_ne!(original_session_id, reconnected_session_id);
    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

