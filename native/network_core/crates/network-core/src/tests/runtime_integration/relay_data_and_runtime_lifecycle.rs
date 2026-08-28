/// §25/§31：Relay v2 reservation 数据面集成测试。两个 `RelayDataClient` 分别连接
/// `/v2/relay/{reservation_id}`，A 发送一个不透明信封，B 通过 `recv()` 收到同一
/// 负载（服务器不解密）。这验证 reservation 数据面（connect_reservation →
/// send/recv/close）与 fake relay 的链接/缓冲行为。
#[test]
fn relay_data_clients_forward_envelopes_over_reservation() {
    let reservation_id = hex::encode(rand::random::<[u8; 16]>());
    let initiator_token: [u8; 32] = rand::random();
    let responder_token: [u8; 32] = rand::random();
    let mut reservations = HashMap::new();
    reservations.insert(
        reservation_id.clone(),
        (initiator_token.to_vec(), responder_token.to_vec()),
    );
    // relay_rt 必须存活到测试结束，否则 fake relay 的后台任务被中止。
    let relay_rt = tokio::runtime::Runtime::new().expect("relay test runtime");
    let relay_server = relay_rt.block_on(FakeRelayV2Server::start(reservations));
    let endpoint = v2_relay_data_endpoint(relay_server.address, &reservation_id);

    let rt = tokio::runtime::Runtime::new().expect("data test runtime");
    rt.block_on(async {
        let mut client_a = RelayDataClient::new(
            endpoint.clone(),
            reservation_id.clone(),
            initiator_token.to_vec(),
            "credential".into(),
            [11u8; 32],
        )
        .expect("client A");
        let mut client_b = RelayDataClient::new(
            endpoint.clone(),
            reservation_id.clone(),
            responder_token.to_vec(),
            "credential".into(),
            [12u8; 32],
        )
        .expect("client B");
        let (result_a, result_b) = tokio::join!(
            client_a.connect_reservation(),
            client_b.connect_reservation()
        );
        result_a.expect("connect A reservation");
        result_b.expect("connect B reservation");
        let mut events_b = client_b.take_events().expect("B events");

        // A 发送一个不透明信封，B 应原样收到（服务器不解密）。
        let opaque_payload = vec![0xAu8, 0xBu8, 0xCu8, 0xDu8];
        client_a
            .send(1, &opaque_payload)
            .await
            .expect("A sends payload");
        let received = tokio::time::timeout(Duration::from_secs(5), events_b.recv())
            .await
            .expect("B received payload")
            .expect("B event stream ended");
        match received {
            DataEvent::Payload {
                encrypted_payload, ..
            } => {
                assert_eq!(encrypted_payload, opaque_payload);
            }
            other => panic!("expected Payload, got {other:?}"),
        }

        // B 回一条流控 Ack；随后双向关闭。
        client_b.send_ack(1).await.expect("B sends ack");
        client_a.close().await.expect("close A data client");
    });
    drop(relay_server);
}

/// 回归 #2：两条不同 reservation 的 relay 数据连接必须共存；连接 peer-c 不得切断
/// peer-b 的活跃连接，关闭 peer-b 只影响其自身（旧实现把单 slot `.replace` 并
/// `request_disconnect`，连接新对端会切断另一对端的在途传输）。
#[test]
fn relay_data_reservations_for_two_peers_coexist_and_close_independently() {
    let res_b = hex::encode(rand::random::<[u8; 16]>());
    let token_b: [u8; 32] = rand::random();
    let res_c = hex::encode(rand::random::<[u8; 16]>());
    let token_c: [u8; 32] = rand::random();
    let mut reservations = HashMap::new();
    reservations.insert(res_b.clone(), (token_b.to_vec(), vec![0u8; 32]));
    reservations.insert(res_c.clone(), (token_c.to_vec(), vec![0u8; 32]));
    let relay_rt = tokio::runtime::Runtime::new().expect("relay test runtime");
    let relay_server = relay_rt.block_on(FakeRelayV2Server::start(reservations));

    let rt = tokio::runtime::Runtime::new().expect("data test runtime");
    rt.block_on(async {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(crate::runtime::RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay.config.write().await = Some(crate::relay::RelayReconnectConfig {
            relay_url: "wss://relay.example.test/v2/control".into(),
            credential: "credential".into(),
            signing_seed: [11u8; 32],
        });
        let reserve_b = RelayReserveResponse {
            request_id: 1,
            attempt_id: "attempt-b".into(),
            reservation_id: res_b.clone(),
            relay_data_endpoint: v2_relay_data_endpoint(relay_server.address, &res_b),
            expires_at_ms: 0,
            local_token: token_b.to_vec(),
        };
        let reserve_c = RelayReserveResponse {
            request_id: 2,
            attempt_id: "attempt-c".into(),
            reservation_id: res_c.clone(),
            relay_data_endpoint: v2_relay_data_endpoint(relay_server.address, &res_c),
            expires_at_ms: 0,
            local_token: token_c.to_vec(),
        };
        let mut responder_b = RelayDataClient::new(
            reserve_b.relay_data_endpoint.clone(),
            reserve_b.reservation_id.clone(),
            vec![0u8; 32],
            "credential".into(),
            [12u8; 32],
        )
        .expect("responder B client");
        let mut responder_c = RelayDataClient::new(
            reserve_c.relay_data_endpoint.clone(),
            reserve_c.reservation_id.clone(),
            vec![0u8; 32],
            "credential".into(),
            [13u8; 32],
        )
        .expect("responder C client");
        let (responder_b_result, data_b_result) = tokio::join!(
            responder_b.connect_reservation(),
            crate::relay::connect_initiator_relay_data(&state, "peer-b", reserve_b)
        );
        responder_b_result.expect("connect responder B reservation");
        let data_b = data_b_result.expect("connect peer-b reservation");
        let (responder_c_result, data_c_result) = tokio::join!(
            responder_c.connect_reservation(),
            crate::relay::connect_initiator_relay_data(&state, "peer-c", reserve_c)
        );
        responder_c_result.expect("connect responder C reservation");
        let data_c = data_c_result.expect("connect peer-c reservation");

        // 关键回归：连接 peer-c 之后 peer-b 的数据面连接必须仍然存活（旧单 slot
        // 实现会在连接 C 时 .replace 并 request_disconnect，切断 peer-b 在途传输）。
        assert!(
            data_b.is_usable().await,
            "connecting peer-c must not sever peer-b's relay data connection"
        );
        assert!(
            data_c.is_usable().await,
            "peer-c data connection must be live"
        );
        // Data clients are staged by the connection attempt and become
        // RuntimeState-owned only after Relay E2EE admission publishes a path.
        // The two reservations must still coexist while staged.

        // 关闭 peer-b 只影响 peer-b 自身，peer-c 的连接必须保持可用。
        data_b.request_disconnect().await;
        assert!(!data_b.is_usable().await, "peer-b data connection closed");
        assert!(
            data_c.is_usable().await,
            "closing peer-b must not tear down peer-c"
        );
        assert!(
            data_c.is_usable().await,
            "peer-c data connection must stay live"
        );
    });
    drop(relay_server);
}

/// 验证格式错误的命令载荷会以类型化结果拒绝。
#[test]
fn missing_payload_is_invalid_instead_of_a_fake_no_route() {
    let runtime = NetworkRuntime::new().expect("runtime");
    runtime.start().expect("start runtime");
    runtime
        .send_command(NetworkCommand {
            command_id: "command-1".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        })
        .expect("send command");

    let event = runtime.poll_event(1000).expect("command result");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::CommandResultV2(network_protocol::CommandResult {
            state,
            error: Some(ProtocolError { code, .. }),
            ..
        })) if state == CommandResultState::Failed as i32
            && code == NetworkErrorCode::InvalidArgument as i32
    ));
    assert!(
        runtime.poll_event(50).is_none(),
        "a command must emit exactly one terminal result"
    );
}

/// A repeated envelope ID is rejected by the worker, but it still receives a
/// correlated terminal result instead of disappearing silently.
#[test]
fn duplicate_command_id_retains_terminal_correlation() {
    let runtime = NetworkRuntime::new().expect("runtime");
    runtime.start().expect("start runtime");
    for _ in 0..2 {
        runtime
            .send_command(NetworkCommand {
                command_id: "duplicate-command".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .expect("send command");
    }

    let first = runtime.poll_event(1000).expect("first command result");
    let second = runtime.poll_event(1000).expect("duplicate command result");
    for event in [first, second] {
        let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
            panic!("expected CommandResultV2");
        };
        assert_eq!(result.command_id, "duplicate-command");
        assert_eq!(result.state, CommandResultState::Failed as i32);
        assert!(result.error.is_some());
    }
    assert!(runtime.poll_event(50).is_none(), "no third terminal result");
}

/// 通过 Runtime owner 验证：processed dedup TTL 到期不会清理仍等待应用
/// ACK 的消息；显式 disconnect 则会释放 active receive 与 ordered buffer。
#[test]
fn runtime_delivery_active_state_survives_ttl_and_closes_with_session() {
    let runtime = NetworkRuntime::new().expect("runtime");
    runtime.start().expect("start runtime");
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");

    runtime.handle().block_on(async {
        let session_id = match state
            .begin_connect(
                "delivery-peer",
                crate::connect::DEFAULT_CONNECTION_CAPABILITY,
            )
            .await
        {
            crate::runtime::ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected session decision: {decision:?}"),
        };
        let first = crate::delivery::MessageId::from_bytes([90; 16]);
        let buffered = crate::delivery::MessageId::from_bytes([91; 16]);
        // §20：投递状态按 Peer 业务作用域 key，不使用每连接的 SessionId。
        assert_eq!(
            state
                .delivery
                .begin_incoming("delivery-peer", "control", first, 1, Instant::now())
                .await,
            crate::delivery::DedupDecision::New
        );
        assert_eq!(
            state
                .delivery
                .accept_ordered(crate::delivery::OrderedMessage {
                    peer_id: "delivery-peer".into(),
                    session_id: session_id.wire_key(),
                    channel_id: "control".into(),
                    message_id: first,
                    sequence: 0,
                    policy: crate::delivery::DeliveryPolicy::SessionBoundOrdered,
                    payload: vec![0],
                })
                .await,
            crate::delivery::OrderedInsertResult::Ready
        );
        assert_eq!(
            state
                .delivery
                .begin_incoming("delivery-peer", "control", buffered, 1, Instant::now())
                .await,
            crate::delivery::DedupDecision::New
        );
        assert_eq!(
            state
                .delivery
                .accept_ordered(crate::delivery::OrderedMessage {
                    peer_id: "delivery-peer".into(),
                    session_id: session_id.wire_key(),
                    channel_id: "control".into(),
                    message_id: buffered,
                    sequence: 1,
                    policy: crate::delivery::DeliveryPolicy::SessionBoundOrdered,
                    payload: vec![1],
                })
                .await,
            crate::delivery::OrderedInsertResult::Buffered
        );
        assert_eq!(state.delivery.incoming_state_counts().await, (2, 0, 1));
        let expired = state
            .delivery
            .expire_incoming("delivery-peer", Instant::now() + Duration::from_secs(11))
            .await;
        assert!(expired.is_empty());
        assert_eq!(state.delivery.incoming_state_counts().await, (2, 0, 1));

        crate::peer::disconnect_peer(&state, "delivery-peer".into())
            .await
            .expect("disconnect peer");
        assert_eq!(state.delivery.incoming_state_counts().await, (0, 0, 0));
    });
    runtime.stop().expect("stop runtime");
}

/// 验证 stop 会关闭 QUIC endpoint 并等待 accept task，旧端口可以立即被
/// 新建的 native runtime 重新绑定，不依赖 sleep 或固定端口重试。
#[test]
fn stop_waits_for_accept_task_before_rebinding_loopback_port() {
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-runtime-rebind-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");

    let first = NetworkRuntime::new().expect("first runtime");
    first.start().expect("start first runtime");
    configure_runtime_for_test(
        &first,
        "rebind-first",
        [61u8; 32],
        [71u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-first"),
    );
    let port = first
        .bound_local_port()
        .expect("first runtime bound an ephemeral port");
    first.stop().expect("stop first runtime");
    drop(first);

    let second = NetworkRuntime::new().expect("second runtime");
    second.start().expect("start second runtime");
    configure_runtime_for_test(
        &second,
        "rebind-second",
        [62u8; 32],
        [72u8; 32],
        SocketAddr::from(([127, 0, 0, 1], port)),
        test_root.join("receive-second"),
    );
    assert_eq!(second.bound_local_port(), Some(port));
    second.stop().expect("stop second runtime");

    fs::remove_dir_all(test_root).expect("remove test root");
}

/// 连续创建、启动、停止并销毁 runtime；下一轮直接要求复用上一轮真实端口，
/// 以覆盖同一进程中的 listener 清理竞态。
#[test]
fn repeated_runtime_lifecycle_reuses_bound_port_without_retry() {
    const ITERATIONS: usize = 100;
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-runtime-stress-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");
    let mut previous_port = None;

    for iteration in 0..ITERATIONS {
        let requested_address = previous_port.map_or_else(
            || SocketAddr::from(([127, 0, 0, 1], 0)),
            |port| SocketAddr::from(([127, 0, 0, 1], port)),
        );
        let runtime = NetworkRuntime::new().expect("stress runtime");
        runtime.start().expect("start stress runtime");
        let address = configure_runtime_for_test(
            &runtime,
            &format!("stress-{iteration}"),
            [80u8 + iteration as u8; 32],
            [100u8 + iteration as u8; 32],
            requested_address,
            test_root.join(format!("receive-{iteration}")),
        );
        if let Some(previous_port) = previous_port {
            assert_eq!(
                address.port(),
                previous_port,
                "iteration {iteration} did not reuse the previous bound port"
            );
        }
        previous_port = Some(address.port());
        runtime.stop().expect("stop stress runtime");
        drop(runtime);
    }

    fs::remove_dir_all(test_root).expect("remove stress test root");
}
