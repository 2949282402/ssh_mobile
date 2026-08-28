/// QUIC bidi direct path (§17): open/send/recv/close round-trip over a real
/// QUIC bidirectional stream (no re-framing).
#[test]
fn reliable_stream_round_trips_bytes_over_quic_bidi() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-stream-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [201u8; 32];
    let identity_seed_b = [202u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("stream-a".into(), identity_seed_a, [211u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("stream-b".into(), identity_seed_b, [212u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "stream-a",
        identity_seed_a,
        [211u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "stream-b",
        identity_seed_b,
        [212u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    connect_runtimes_for_stream_test(
        &runtime_a,
        &runtime_b,
        &StreamTestPeers {
            device_a: "stream-a".into(),
            device_b: "stream-b".into(),
            address_a,
            address_b,
            public_key_a,
            public_key_b,
            seed_a: [211u8; 32],
            seed_b: [212u8; 32],
        },
        RouteTransport::Quic,
    );

    const STREAM_ID: u16 = 1;
    send_and_expect_accepted(
        &runtime_a,
        ssh_open_command("stream-a", "stream-b", STREAM_ID, "test"),
    );
    send_and_expect_accepted(
        &runtime_b,
        ssh_open_command("stream-b", "stream-a", STREAM_ID, "test"),
    );

    // A -> B data (QUIC bidi stream bytes).
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-a", "stream-b", STREAM_ID, b"ping"),
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-a" && stream_handle_matches(recv.handle.as_ref(), "stream-a", STREAM_ID) && recv.data == b"ping"
        )
    });
    assert!(received.is_some(), "stream-b never received ping");

    // B -> A data (the QUIC send half is registered on the responder side).
    send_and_expect_accepted(
        &runtime_b,
        ssh_data_command("stream-b", "stream-a", STREAM_ID, b"pong"),
    );
    let echo = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-b" && stream_handle_matches(recv.handle.as_ref(), "stream-b", STREAM_ID) && recv.data == b"pong"
        )
    });
    assert!(echo.is_some(), "stream-a never received pong");

    // Teardown: A closes -> B sees SshStreamClosed.
    send_and_expect_accepted(
        &runtime_a,
        ssh_close_command("stream-a", "stream-b", STREAM_ID),
    );
    let closed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamClosed(closed))
                if closed.peer_id == "stream-a" && stream_handle_matches(closed.handle.as_ref(), "stream-a", STREAM_ID)
        )
    });
    assert!(closed.is_some(), "stream-b never saw the stream close");

    send_and_expect_accepted(
        &runtime_b,
        ssh_close_command("stream-b", "stream-a", STREAM_ID),
    );
    let reverse_closed = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamClosed(closed))
                if closed.peer_id == "stream-b"
                    && stream_handle_matches(closed.handle.as_ref(), "stream-b", STREAM_ID)
        )
    });
    assert!(
        reverse_closed.is_some(),
        "stream-a never saw the reverse stream close"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

/// Generic-route carrier (§17): StreamBytes frames interleave with DataMessage
/// frames on the same framed TCP route.
#[test]
fn stream_bytes_interleave_with_data_message_on_generic_route() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-stream-tcp-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [221u8; 32];
    let identity_seed_b = [222u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("stream-tcp-a".into(), identity_seed_a, [231u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("stream-tcp-b".into(), identity_seed_b, [232u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "stream-tcp-a",
        identity_seed_a,
        [231u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "stream-tcp-b",
        identity_seed_b,
        [232u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    force_tcp_fallback(&runtime_b);
    connect_runtimes_for_stream_test(
        &runtime_a,
        &runtime_b,
        &StreamTestPeers {
            device_a: "stream-tcp-a".into(),
            device_b: "stream-tcp-b".into(),
            address_a,
            address_b,
            public_key_a,
            public_key_b,
            seed_a: [231u8; 32],
            seed_b: [232u8; 32],
        },
        RouteTransport::Tcp,
    );

    const STREAM_ID: u16 = 2;
    send_and_expect_accepted(
        &runtime_a,
        ssh_open_command("stream-tcp-a", "stream-tcp-b", STREAM_ID, "test"),
    );
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-tcp-a", "stream-tcp-b", STREAM_ID, b"stream-bytes"),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "tcp-stream-message".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "stream-tcp-b".into(),
                channel_id: "control".into(),
                payload: b"message-bytes".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
            })),
        },
    );

    // Both a StreamBytes frame and a DataMessage frame survive on the same
    // framed carrier, delivered to their independent handlers.
    let stream = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-tcp-a"
                    && stream_handle_matches(recv.handle.as_ref(), "stream-tcp-a", STREAM_ID)
                    && recv.data == b"stream-bytes"
        )
    });
    assert!(
        stream.is_some(),
        "generic route never delivered stream bytes"
    );
    let message = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == "stream-tcp-a" && message.payload == b"message-bytes"
        )
    });
    assert!(
        message.is_some(),
        "generic route never delivered the DataMessage"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

/// Failure scenario: sending on a closed stream resolves to a clean command
/// rejection (no teardown, no panic).
#[test]
fn ssh_stream_data_after_close_is_rejected_cleanly() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-stream-fail-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [241u8; 32];
    let identity_seed_b = [242u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("stream-fail-a".into(), identity_seed_a, [251u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("stream-fail-b".into(), identity_seed_b, [252u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "stream-fail-a",
        identity_seed_a,
        [251u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "stream-fail-b",
        identity_seed_b,
        [252u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    connect_runtimes_for_stream_test(
        &runtime_a,
        &runtime_b,
        &StreamTestPeers {
            device_a: "stream-fail-a".into(),
            device_b: "stream-fail-b".into(),
            address_a,
            address_b,
            public_key_a,
            public_key_b,
            seed_a: [251u8; 32],
            seed_b: [252u8; 32],
        },
        RouteTransport::Quic,
    );

    const STREAM_ID: u16 = 3;
    send_and_expect_accepted(
        &runtime_a,
        ssh_open_command("stream-fail-a", "stream-fail-b", STREAM_ID, "test"),
    );
    // Establish the stream on B before tearing down (deterministic: the QUIC
    // open and close could otherwise be coalesced before B's accept loop runs).
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-fail-a", "stream-fail-b", STREAM_ID, b"hello"),
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if stream_handle_matches(recv.handle.as_ref(), "stream-fail-a", STREAM_ID) && recv.data == b"hello"
        )
    });
    assert!(received.is_some(), "stream was not established on B");

    // Tear down from both sides.
    send_and_expect_accepted(
        &runtime_a,
        ssh_close_command("stream-fail-a", "stream-fail-b", STREAM_ID),
    );
    let closed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamClosed(closed))
                if stream_handle_matches(closed.handle.as_ref(), "stream-fail-a", STREAM_ID)
        )
    });
    assert!(closed.is_some(), "B never saw the stream close");
    send_and_expect_accepted(
        &runtime_b,
        ssh_close_command("stream-fail-a", "stream-fail-a", STREAM_ID),
    );

    // Sending on a closed stream must be a clean command rejection.
    let late = NetworkCommand {
        command_id: "ssh-data-after-close".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: "stream-fail-b".into(),
                handle: Some(StreamHandle {
                    opener_device_id: "stream-fail-a".into(),
                    stream_id: STREAM_ID as u32,
                }),
                data: b"late".to_vec(),
            },
        )),
    };
    runtime_a.send_command(late).expect("queue late data");
    let rejected = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::CommandResultV2(result))
                if result.command_id == "ssh-data-after-close"
                    && result.state == CommandResultState::Failed as i32
        )
    });
    assert!(
        rejected.is_some(),
        "late stream data was not rejected cleanly"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

