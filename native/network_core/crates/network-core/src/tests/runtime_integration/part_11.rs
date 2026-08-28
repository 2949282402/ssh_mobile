/// With QUIC closed and the test TCP fallback gate disabled, the shared
/// listener admits the binary WebSocket path. Delivery and application ACKs
/// use the same Session capability dispatch as TCP.
#[test]
fn websocket_fallback_authenticates_delivery_and_ack() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-websocket-fallback-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [121u8; 32];
    let identity_seed_b = [122u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("ws-a".into(), identity_seed_a, [131u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("ws-b".into(), identity_seed_b, [132u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "ws-a",
        identity_seed_a,
        [131u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "ws-b",
        identity_seed_b,
        [132u8; 32],
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
            .close(quinn::VarInt::from_u32(0), b"WebSocket fallback test");
        state_b
            .lifecycle
            .tcp_fallback_enabled
            .store(false, std::sync::atomic::Ordering::Release);
    });
    send_and_expect_accepted(
        &runtime_a,
        upsert_command("ws-upsert-b", "ws-b", address_b, public_key_b, [132u8; 32]),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command("ws-upsert-a", "ws-a", address_a, public_key_a, [131u8; 32]),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "ws-connect".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "ws-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(25), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "ws-b"
                    && state.state == PeerConnectionState::Connected as i32
                    && state.route_transport == RouteTransport::WebSocket as i32
        )
    })
    .is_some());
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "ws-send".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SendMessage(SendMessageCommand {
                peer_id: "ws-b".into(),
                channel_id: "control".into(),
                payload: b"websocket-delivery".to_vec(),
                policy: DeliveryPolicyCode::AckedDeduplicated as i32,
            })),
        },
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == "ws-a" && message.payload == b"websocket-delivery"
        )
    })
    .expect("WebSocket route did not deliver the message");
    let (session_id, message_id) = match received.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "ws-ack".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "ws-a".into(),
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
            })) if peer_id == "ws-b" && acknowledged_id == &message_id
        )
    })
    .is_some());
    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

// ---------------------------------------------------------------------------
// ReliableStream byte-stream carrier (§17) integration tests
// ---------------------------------------------------------------------------

/// Peer/endpoint/key material shared by the ReliableStream integration tests.
struct StreamTestPeers {
    device_a: String,
    device_b: String,
    address_a: SocketAddr,
    address_b: SocketAddr,
    public_key_a: [u8; 32],
    public_key_b: [u8; 32],
    seed_a: [u8; 32],
    seed_b: [u8; 32],
}

/// Connects two runtimes and waits for a peer state whose route transport
/// matches `transport`.
fn connect_runtimes_for_stream_test(
    runtime_a: &NetworkRuntime,
    runtime_b: &NetworkRuntime,
    peers: &StreamTestPeers,
    transport: RouteTransport,
) {
    send_and_expect_accepted(
        runtime_a,
        upsert_command(
            &format!("{}-upsert-b", peers.device_a),
            &peers.device_b,
            peers.address_b,
            peers.public_key_b,
            peers.seed_b,
        ),
    );
    send_and_expect_accepted(
        runtime_b,
        upsert_command(
            &format!("{}-upsert-a", peers.device_b),
            &peers.device_a,
            peers.address_a,
            peers.public_key_a,
            peers.seed_a,
        ),
    );
    send_and_expect_accepted(
        runtime_a,
        NetworkCommand {
            command_id: format!("{}-connect-{}", peers.device_a, peers.device_b),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: peers.device_b.clone(),
                intent: 0,
                communication_class: CommunicationClass::ReliableStream as i32,
            })),
        },
    );
    let connected = poll_until(runtime_a, Duration::from_secs(25), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == peers.device_b
                    && state.state == PeerConnectionState::Connected as i32
                    && state.route_transport == transport as i32
        )
    });
    assert!(
        connected.is_some(),
        "connection to {} never reached {transport:?}",
        peers.device_b
    );
    assert!(
        wait_for_session_connected(runtime_a, &peers.device_b, Duration::from_secs(5)),
        "connection event for {} was emitted before the Session became connected",
        peers.device_b
    );
    assert!(
        wait_for_session_connected(runtime_b, &peers.device_a, Duration::from_secs(5)),
        "responder Session for {} was not connected before the stream test continued",
        peers.device_a
    );
}

/// Disables a runtime's QUIC endpoint so the connectivity attempt falls back to TCP.
fn force_tcp_fallback(runtime: &NetworkRuntime) {
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");
    runtime.handle().block_on(async {
        state
            .lifecycle
            .endpoint
            .read()
            .await
            .as_ref()
            .expect("endpoint")
            .close(quinn::VarInt::from_u32(0), b"TCP fallback test");
    });
}

fn ssh_open_command(
    opener_device_id: &str,
    peer_id: &str,
    stream_id: u16,
    service: &str,
) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-open-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamOpen(
            SshStreamOpenCommand {
                peer_id: peer_id.into(),
                handle: Some(StreamHandle {
                    opener_device_id: opener_device_id.into(),
                    stream_id: stream_id as u32,
                }),
                service: service.into(),
            },
        )),
    }
}

fn ssh_data_command(
    opener_device_id: &str,
    peer_id: &str,
    stream_id: u16,
    data: &[u8],
) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-data-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: peer_id.into(),
                handle: Some(StreamHandle {
                    opener_device_id: opener_device_id.into(),
                    stream_id: stream_id as u32,
                }),
                data: data.to_vec(),
            },
        )),
    }
}

fn ssh_close_command(opener_device_id: &str, peer_id: &str, stream_id: u16) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-close-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamClose(
            SshStreamCloseCommand {
                peer_id: peer_id.into(),
                handle: Some(StreamHandle {
                    opener_device_id: opener_device_id.into(),
                    stream_id: stream_id as u32,
                }),
            },
        )),
    }
}

fn stream_handle_matches(
    handle: Option<&StreamHandle>,
    opener_device_id: &str,
    stream_id: u16,
) -> bool {
    handle.is_some_and(|handle| {
        handle.opener_device_id == opener_device_id && handle.stream_id == stream_id as u32
    })
}

