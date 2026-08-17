//! 运行时生命周期、传输契约与 reservation 数据面的集成式测试。

use super::*;
use futures_util::{SinkExt, StreamExt};
use network_identity::DeviceIdentity;
use network_protocol::{
    network_command, network_event, AcknowledgeMessageCommand, ChannelMessageEvent,
    CommandResultEvent, CommunicationClass, ConfigureRuntimeCommand, ConnectPeerCommand,
    DeliveryAckedEvent, DeliveryPolicyCode, NetworkCommand, NetworkError as ProtocolError,
    NetworkErrorCode, PeerConnectionState, RespondIncomingTransferCommand, RouteTransport,
    RouteType, SendFileCommand, SendMessageCommand, SshStreamCloseCommand, SshStreamDataCommand,
    SshStreamOpenCommand, UpsertPeerCommand, NETWORK_PROTOCOL_VERSION,
};
use network_relay::v2::proto::*;
use network_relay::v2::{DataEvent, RelayDataClient};
use network_transfer::build_file_manifest;
use std::collections::HashMap;
use std::fs;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::{accept_hdr_async, tungstenite::Message};

/// 构造一个合法的 /v2/relay/{32-hex} 数据面地址（测试用 loopback）。
fn v2_relay_data_endpoint(address: SocketAddr, reservation_id: &str) -> String {
    format!("ws://{address}/v2/relay/{reservation_id}")
}

/// Fake Relay v2 数据面：/v2/relay/{reservation_id}。
///
/// 校验首帧 RelayDataConnect（reservation_id + local_token），把同一 reservation 的
/// 两个端点链接起来；对端未链接时把 Payload/Ack 缓冲到 reservation，链接后冲刷。
struct FakeRelayV2Server {
    address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl FakeRelayV2Server {
    async fn start(reservations: HashMap<String, (Vec<u8>, Vec<u8>)>) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind fake Relay v2 listener");
        let address = listener.local_addr().expect("fake Relay v2 address");
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(run_fake_relay_v2(listener, shutdown_rx, reservations));
        Self {
            address,
            shutdown: Some(shutdown),
            task: Some(task),
        }
    }
}

impl Drop for FakeRelayV2Server {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// reservation_id → (initiator_token, responder_token) + 已注册端点/缓冲。
struct RelayV2DataRegistry {
    reservations: HashMap<String, (Vec<u8>, Vec<u8>)>,
    /// reservation_id → 已注册端点 (conn_id, outbound)。
    endpoints: HashMap<String, Vec<(u64, mpsc::Sender<Message>)>>,
    /// reservation_id → 对端未链接时缓冲的帧。
    buffered: HashMap<String, Vec<Message>>,
    next_conn_id: u64,
}

impl RelayV2DataRegistry {
    fn new(reservations: HashMap<String, (Vec<u8>, Vec<u8>)>) -> Self {
        Self {
            reservations,
            endpoints: HashMap::new(),
            buffered: HashMap::new(),
            next_conn_id: 0,
        }
    }

    fn register(&mut self, reservation_id: &str, outbound: mpsc::Sender<Message>) -> u64 {
        let conn_id = self.next_conn_id;
        self.next_conn_id += 1;
        let endpoints = self
            .endpoints
            .entry(reservation_id.to_string())
            .or_default();
        // 对端已注册：把缓冲的帧冲刷给新端点。
        if let Some(buffered) = self.buffered.remove(reservation_id) {
            for message in buffered {
                let _ = outbound.try_send(message);
            }
        }
        endpoints.push((conn_id, outbound));
        conn_id
    }

    /// 把一帧从 `from_id` 转发给同一 reservation 的对端；对端未链接则缓冲。
    async fn forward(&mut self, reservation_id: &str, from_id: u64, frame: Message) {
        let endpoints = self.endpoints.get(reservation_id);
        let target = endpoints.and_then(|endpoints| {
            endpoints
                .iter()
                .find(|(id, _)| *id != from_id)
                .map(|(_, sender)| sender.clone())
        });
        match target {
            Some(target) => {
                let _ = target.send(frame).await;
            }
            None => {
                self.buffered
                    .entry(reservation_id.to_string())
                    .or_default()
                    .push(frame);
            }
        }
    }
}

#[allow(clippy::result_large_err)]
async fn run_fake_relay_v2(
    listener: TcpListener,
    mut shutdown: oneshot::Receiver<()>,
    reservations: HashMap<String, (Vec<u8>, Vec<u8>)>,
) {
    let registry = Arc::new(tokio::sync::Mutex::new(RelayV2DataRegistry::new(
        reservations,
    )));
    let mut handles = Vec::new();
    loop {
        let (stream, _) = tokio::select! {
            result = listener.accept() => match result {
                Ok(value) => value,
                Err(_) => break,
            },
            _ = &mut shutdown => break,
        };
        let path_holder = Arc::new(Mutex::new(None::<String>));
        let path_capture = Arc::clone(&path_holder);
        let socket = match accept_hdr_async(
            stream,
            move |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                  response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                *path_capture.lock().expect("fake relay path lock") =
                    Some(request.uri().path().to_string());
                Ok(response)
            },
        )
        .await
        {
            Ok(socket) => socket,
            Err(_) => continue,
        };
        let path = path_holder
            .lock()
            .expect("fake relay path lock")
            .take()
            .unwrap_or_default();
        if let Some(reservation_id) = path.strip_prefix("/v2/relay/") {
            let registry = Arc::clone(&registry);
            let handle = tokio::spawn(run_data_connection(
                registry,
                reservation_id.to_string(),
                socket,
            ));
            handles.push(handle);
        } else {
            drop(socket);
        }
    }
    drop(shutdown);
    for handle in handles {
        handle.abort();
    }
}

async fn run_data_connection(
    registry: Arc<tokio::sync::Mutex<RelayV2DataRegistry>>,
    reservation_id: String,
    socket: tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
) {
    let (writer, mut reader) = socket.split();
    // 阶段一：等待并校验首帧 RelayDataConnect，取得 writer 任务与 conn_id。
    let Some(Ok(message)) = reader.next().await else {
        return;
    };
    let Message::Binary(frame) = message else {
        return;
    };
    let Ok(frame) = decode_data_frame(&frame) else {
        return;
    };
    let Some(relay_data_frame::Kind::Connect(connect)) = frame.kind else {
        return;
    };
    let tokens = {
        let guard = registry.lock().await;
        guard.reservations.get(&reservation_id).cloned()
    };
    let Some((initiator_token, responder_token)) = tokens else {
        return;
    };
    if connect.reservation_id != reservation_id
        || (connect.local_token != initiator_token && connect.local_token != responder_token)
    {
        return;
    }
    let (tx, mut rx) = mpsc::channel::<Message>(64);
    let mut writer_for_task = writer;
    let writer_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if writer_for_task.send(message).await.is_err() {
                break;
            }
        }
    });
    let conn_id = registry.lock().await.register(&reservation_id, tx);
    let writer_task = Some(writer_task);
    // 阶段二：转发 Payload/Ack/Close 到对端。
    while let Some(result) = reader.next().await {
        let Ok(message) = result else {
            break;
        };
        let Message::Binary(frame) = message else {
            continue;
        };
        let Ok(frame) = decode_data_frame(&frame) else {
            continue;
        };
        match frame.kind {
            Some(relay_data_frame::Kind::Payload(_)) | Some(relay_data_frame::Kind::Ack(_)) => {
                let encoded = encode_data_frame(&frame).expect("encode data frame");
                registry
                    .lock()
                    .await
                    .forward(&reservation_id, conn_id, Message::Binary(encoded.into()))
                    .await;
            }
            Some(relay_data_frame::Kind::Close(_)) => {
                let encoded = encode_data_frame(&frame).expect("encode data frame");
                registry
                    .lock()
                    .await
                    .forward(&reservation_id, conn_id, Message::Binary(encoded.into()))
                    .await;
                break;
            }
            _ => {}
        }
    }
    if let Some(task) = writer_task {
        task.abort();
    }
}

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
        client_a
            .connect_reservation()
            .await
            .expect("connect A reservation");
        client_b
            .connect_reservation()
            .await
            .expect("connect B reservation");
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
        *state.relay_config.write().await = Some(crate::relay::RelayReconnectConfig {
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
        let data_b = crate::relay::connect_initiator_relay_data(&state, "peer-b", reserve_b)
            .await
            .expect("connect peer-b reservation");
        let data_c = crate::relay::connect_initiator_relay_data(&state, "peer-c", reserve_c)
            .await
            .expect("connect peer-c reservation");

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
        assert_eq!(
            state.relay_data.read().await.len(),
            2,
            "two reservations must coexist"
        );

        // 关闭 peer-b 只影响 peer-b 自身，peer-c 的连接必须保持可用。
        data_b.request_disconnect().await;
        assert!(!data_b.is_usable().await, "peer-b data connection closed");
        assert!(
            data_c.is_usable().await,
            "closing peer-b must not tear down peer-c"
        );
        assert!(
            state.relay_data.read().await.get("peer-c").is_some(),
            "peer-c data connection must stay registered"
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
        Some(network_event::Payload::CommandResult(CommandResultEvent {
            accepted: false,
            error: Some(ProtocolError { code, .. }),
            ..
        })) if code == NetworkErrorCode::InvalidArgument as i32
    ));
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
        let session_id = match state.sessions.begin_connect("delivery-peer").await {
            crate::session::ConnectDecision::Started(session_id) => session_id,
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
                    active_route,
                    ..
                }
            )) if peer_id == "device-b"
                && *state == PeerConnectionState::Connected as i32
                && *active_route == RouteType::QuicDirect as i32
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

/// §40 Recovery：文件传输中断（TransferOperation = PAUSED，§19）→ ConnectionSession
/// 销毁 → 重新建连（新 ConnectionSession + 新 Noise root）→ `ResumeTransfer(transfer_id)`
/// 与对端协商 confirmed_offset（checkpoint）→ 从 checkpoint 继续，最终完成。
///
/// 传输状态按 transfer_id + peer_id 保存在 TransferManager，不依赖 SessionId；新连接
/// 建立后由 orchestrator 触发 `resume_transfers_for_peer` 领取暂停传输并在新连接上恢复。
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
                        && state.active_route == RouteType::QuicDirect as i32
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
            .sessions
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
                .transfers
                .register_outgoing(manifest, source_path.clone(), "resume-b".into())
                .await
        );
        assert!(state_a.transfers.mark_transferring(TRANSFER_ID).await);
        assert!(
            state_a
                .transfers
                .update_progress(TRANSFER_ID, CONFIRMED_OFFSET)
                .await
        );
        assert!(state_a.transfers.pause_for_network(TRANSFER_ID).await);
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
        crate::connect::orchestrator::close_session_and_registry(
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

    // 重新建连（新 ConnectionSession）→ orchestrator 触发 ResumeTransfer(transfer_id)。
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
                        && state.active_route == RouteType::QuicDirect as i32
            )
        })
        .is_some(),
        "fresh connection never reached connected state"
    );
    let new_session_id = runtime_a.handle().block_on(async {
        state_a
            .sessions
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
                crypto_mode: 0,
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
                crypto_mode: 1,
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
                crypto_mode: 0,
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
            .sessions
            .current_session_id("reconnect-b")
            .await
            .expect("A Session ID")
    });

    // 关闭 A→B 的当前 route：transport 丢失，A 侧 Session 被销毁；pending 保留。
    let route = runtime_a.handle().block_on(async {
        state_a
            .sessions
            .current_active_route("reconnect-b")
            .await
            .expect("active A route")
    });
    runtime_a.handle().block_on(route.close_for_test());
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
            .sessions
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
            .sessions
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
                .transfers
                .register_outgoing(orphaned_manifest, orphaned_source_path, "restart-a".into())
                .await
        );
        assert!(
            state_b
                .transfers
                .mark_transferring(orphaned_transfer_id)
                .await
        );
        assert!(
            state_b
                .transfers
                .pause_for_network(orphaned_transfer_id)
                .await
        );
    });
    // 在 Peer 业务作用域下 enqueue 一条未 ACK 的 pending 消息（§20）：peer
    // restart 后 ReplaceWithNew 不得清理它；新连接通过 Peer 作用域以同一个
    // MessageId 恢复重发。
    let old_pending = runtime_b
        .handle()
        .block_on(state_b.delivery.enqueue_with_crypto(
            "restart-a",
            "control",
            b"old-session-pending".to_vec(),
            crate::delivery::DeliveryPolicy::AckedDeduplicated,
            crate::crypto::CryptoMode::E2ee,
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
            .sessions
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
            .sessions
            .current_remote_session_binding("restart-a")
            .await
    });
    let state_a2 = runtime_a2
        .state
        .lock()
        .expect("runtime A2 state lock")
        .clone()
        .expect("runtime A2 state");
    let current_a2_session_id = runtime_a2
        .handle()
        .block_on(async { state_a2.sessions.current_session_id("restart-b").await });
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
            .transfers
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
                crypto_mode: 0,
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
                communication_class: 0,
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
            .sessions
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
                crypto_mode: 0,
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

    let route = runtime_a.handle().block_on(async {
        state_a
            .sessions
            .current_active_route("tcp-b")
            .await
            .expect("active TCP route")
    });
    runtime_a.handle().block_on(route.close_for_test());
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
                communication_class: 0,
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
            .sessions
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
            .endpoint
            .read()
            .await
            .as_ref()
            .expect("B endpoint")
            .close(quinn::VarInt::from_u32(0), b"WebSocket fallback test");
        state_b
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
                crypto_mode: 0,
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
}

/// Disables a runtime's QUIC endpoint so the orchestrator falls back to TCP.
fn force_tcp_fallback(runtime: &NetworkRuntime) {
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");
    runtime.handle().block_on(async {
        state
            .endpoint
            .read()
            .await
            .as_ref()
            .expect("endpoint")
            .close(quinn::VarInt::from_u32(0), b"TCP fallback test");
    });
}

fn ssh_open_command(peer_id: &str, stream_id: u16, service: &str) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-open-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamOpen(
            SshStreamOpenCommand {
                peer_id: peer_id.into(),
                stream_id: stream_id as u32,
                service: service.into(),
            },
        )),
    }
}

fn ssh_data_command(peer_id: &str, stream_id: u16, data: &[u8]) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-data-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: peer_id.into(),
                stream_id: stream_id as u32,
                data: data.to_vec(),
            },
        )),
    }
}

fn ssh_close_command(peer_id: &str, stream_id: u16) -> NetworkCommand {
    NetworkCommand {
        command_id: format!("ssh-close-{stream_id}"),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamClose(
            SshStreamCloseCommand {
                peer_id: peer_id.into(),
                stream_id: stream_id as u32,
            },
        )),
    }
}

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
    send_and_expect_accepted(&runtime_a, ssh_open_command("stream-b", STREAM_ID, "test"));

    // A -> B data (QUIC bidi stream bytes).
    send_and_expect_accepted(&runtime_a, ssh_data_command("stream-b", STREAM_ID, b"ping"));
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-a" && recv.stream_id == STREAM_ID as u32 && recv.data == b"ping"
        )
    });
    assert!(received.is_some(), "stream-b never received ping");

    // B -> A data (the QUIC send half is registered on the responder side).
    send_and_expect_accepted(&runtime_b, ssh_data_command("stream-a", STREAM_ID, b"pong"));
    let echo = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-b" && recv.stream_id == STREAM_ID as u32 && recv.data == b"pong"
        )
    });
    assert!(echo.is_some(), "stream-a never received pong");

    // Teardown: A closes -> B sees SshStreamClosed.
    send_and_expect_accepted(&runtime_a, ssh_close_command("stream-b", STREAM_ID));
    let closed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamClosed(closed))
                if closed.peer_id == "stream-a" && closed.stream_id == STREAM_ID as u32
        )
    });
    assert!(closed.is_some(), "stream-b never saw the stream close");

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
        ssh_open_command("stream-tcp-b", STREAM_ID, "test"),
    );
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-tcp-b", STREAM_ID, b"stream-bytes"),
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
                crypto_mode: 0,
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
                    && recv.stream_id == STREAM_ID as u32
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
        ssh_open_command("stream-fail-b", STREAM_ID, "test"),
    );
    // Establish the stream on B before tearing down (deterministic: the QUIC
    // open and close could otherwise be coalesced before B's accept loop runs).
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-fail-b", STREAM_ID, b"hello"),
    );
    let received = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.stream_id == STREAM_ID as u32 && recv.data == b"hello"
        )
    });
    assert!(received.is_some(), "stream was not established on B");

    // Tear down from both sides.
    send_and_expect_accepted(&runtime_a, ssh_close_command("stream-fail-b", STREAM_ID));
    let closed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamClosed(closed))
                if closed.stream_id == STREAM_ID as u32
        )
    });
    assert!(closed.is_some(), "B never saw the stream close");
    send_and_expect_accepted(&runtime_b, ssh_close_command("stream-fail-a", STREAM_ID));

    // Sending on a closed stream must be a clean command rejection.
    let late = NetworkCommand {
        command_id: "ssh-data-after-close".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: "stream-fail-b".into(),
                stream_id: STREAM_ID as u32,
                data: b"late".to_vec(),
            },
        )),
    };
    runtime_a.send_command(late).expect("queue late data");
    let rejected = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::CommandResult(result))
                if result.command_id == "ssh-data-after-close" && !result.accepted
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

/// Peer SSH Server Service (design §21 option B): a stream whose service hint
/// is `ssh` is bridged by the peer's native runtime to a local TCP socket.
/// Tested against a local echo server instead of a real sshd.
#[test]
fn ssh_gateway_bridges_stream_to_a_local_tcp_echo_server() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-stream-gw-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [61u8; 32];
    let identity_seed_b = [62u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("stream-gw-a".into(), identity_seed_a, [71u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("stream-gw-b".into(), identity_seed_b, [72u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "stream-gw-a",
        identity_seed_a,
        [71u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "stream-gw-b",
        identity_seed_b,
        [72u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    connect_runtimes_for_stream_test(
        &runtime_a,
        &runtime_b,
        &StreamTestPeers {
            device_a: "stream-gw-a".into(),
            device_b: "stream-gw-b".into(),
            address_a,
            address_b,
            public_key_a,
            public_key_b,
            seed_a: [71u8; 32],
            seed_b: [72u8; 32],
        },
        RouteTransport::Quic,
    );

    // Local TCP echo server on runtime B's worker threads; the peer gateway
    // bridges to it. Tested against an echo server instead of a real sshd.
    let (echo_port, echo_task) = runtime_b.handle().block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind echo server");
        let port = listener.local_addr().expect("echo address").port();
        let task = tokio::spawn(async move {
            loop {
                let (socket, _) = match listener.accept().await {
                    Ok(connection) => connection,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let (mut read_half, mut write_half) = socket.into_split();
                    let _ = tokio::io::copy(&mut read_half, &mut write_half).await;
                });
            }
        });
        (port, task)
    });

    // Point the peer's SSH gateway at the echo server.
    let state_b = runtime_b
        .state
        .lock()
        .expect("runtime B state lock")
        .clone()
        .expect("runtime B state");
    runtime_b.handle().block_on(async {
        state_b
            .stream_gateway_port
            .store(echo_port, std::sync::atomic::Ordering::Release);
    });

    const STREAM_ID: u16 = 4;
    send_and_expect_accepted(
        &runtime_a,
        ssh_open_command("stream-gw-b", STREAM_ID, crate::stream::STREAM_SERVICE_SSH),
    );

    // The bridge pumps A -> gateway -> echo server -> gateway -> A.
    let payload = b"bridge-round-trip";
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-gw-b", STREAM_ID, payload),
    );
    let echoed = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-gw-b"
                    && recv.stream_id == STREAM_ID as u32
                    && recv.data == payload
        )
    });
    assert!(
        echoed.is_some(),
        "echoed bytes never returned to the initiator"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    echo_task.abort();
    fs::remove_dir_all(test_root).ok();
}

fn configure_runtime_for_test(
    runtime: &NetworkRuntime,
    device_id: &str,
    identity_seed: [u8; 32],
    e2e_seed: [u8; 32],
    address: SocketAddr,
    receive_directory: std::path::PathBuf,
) -> SocketAddr {
    send_and_expect_accepted(
        runtime,
        NetworkCommand {
            command_id: format!("configure-{device_id}"),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConfigureRuntime(
                ConfigureRuntimeCommand {
                    device_id: device_id.into(),
                    identity_private_key: identity_seed.to_vec(),
                    e2e_private_key: e2e_seed.to_vec(),
                    listen_address: address.to_string(),
                    receive_directory: receive_directory.to_string_lossy().to_string(),
                },
            )),
        },
    );
    let port = runtime
        .bound_local_port()
        .expect("runtime bound an actual UDP port");
    SocketAddr::new(address.ip(), port)
}

/// 为当前 v1 线协议契约创建对端 upsert 命令。
fn upsert_command(
    command_id: &str,
    peer_id: &str,
    endpoint: SocketAddr,
    public_key: [u8; 32],
    e2e_private_key: [u8; 32],
) -> NetworkCommand {
    let e2e_public_key =
        DeviceIdentity::from_private_keys(peer_id.to_string(), [1u8; 32], e2e_private_key)
            .public_e2e_key()
            .to_bytes();
    NetworkCommand {
        command_id: command_id.into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::UpsertPeer(UpsertPeerCommand {
            peer_id: peer_id.into(),
            endpoint_address: endpoint.to_string(),
            identity_public_key: public_key.to_vec(),
            e2e_public_key: e2e_public_key.to_vec(),
        })),
    }
}

/// 将命令入队，并只等待其内部接受结果。
///
/// 每个 NetworkRuntime 启动一个多线程 tokio worker。全套测试并行执行真实
/// QUIC/UDP/TCP/WebSocket 网络 I/O 时可能重度超订 CPU，命令结果在加载下的
/// 真实延迟可远超 10s；用 30s 作为命令结果截止期，避免加载下偶发误报。
fn send_and_expect_accepted(runtime: &NetworkRuntime, command: NetworkCommand) {
    let command_id = command.command_id.clone();
    runtime.send_command(command).expect("queue command");
    let result = poll_until(runtime, Duration::from_secs(30), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::CommandResult(result))
                if result.command_id == command_id
        )
    })
    .unwrap_or_else(|| panic!("command {command_id} timed out waiting for command result"));
    match result.payload {
        Some(network_event::Payload::CommandResult(CommandResultEvent {
            accepted: true, ..
        })) => {}
        Some(network_event::Payload::CommandResult(CommandResultEvent {
            error: Some(error),
            ..
        })) => panic!(
            "command {command_id} rejected: code={} message={} operation={} peer_id={}",
            error.code, error.message, error.operation, error.peer_id
        ),
        other => panic!("command {command_id} returned unexpected result: {other:?}"),
    }
}

/// 轮询原生事件，直到匹配谓词或超时。
fn poll_until(
    runtime: &NetworkRuntime,
    timeout: Duration,
    predicate: impl Fn(&network_protocol::NetworkEvent) -> bool,
) -> Option<network_protocol::NetworkEvent> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(event) = runtime.poll_event(100) {
            if predicate(&event) {
                return Some(event);
            }
        }
    }
    None
}

fn wait_for_session_connected(runtime: &NetworkRuntime, peer_id: &str, timeout: Duration) -> bool {
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if runtime
            .handle()
            .block_on(state.sessions.is_connected(peer_id))
        {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}
