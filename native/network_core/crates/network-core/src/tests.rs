//! v1 运行时生命周期与传输契约的集成式测试。
// v1 原生运行时、命令接受、传输和清理回归测试。

use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use futures_util::{SinkExt, StreamExt};
use network_identity::DeviceIdentity;
use network_relay::{RelayClient, RelayEvent};
use network_transfer::{FileManifest, NETWORK_TRANSFER_PROTOCOL_VERSION};

use network_protocol::{
    network_command, network_event, AcknowledgeMessageCommand, ChannelMessageEvent,
    CommandResultEvent, ConfigureRuntimeCommand, ConnectPeerCommand, DeliveryAckedEvent,
    DeliveryPolicyCode, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    PeerConnectionState, RespondIncomingTransferCommand, RouteTransport, RouteType,
    SendFileCommand, SendMessageCommand, UpsertPeerCommand, NETWORK_PROTOCOL_VERSION,
};
use std::collections::HashMap;
use std::fs;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::{accept_async, tungstenite::Message};

#[test]
fn session_root_source_requires_noise_transport_secret_export() {
    let source = include_str!("crypto_handshake.rs");
    assert!(!source.contains("fn derive_session_root("));
    assert!(!source.contains("noise-xx-aes256gcm-v2\";"));
    assert!(source.contains("fn derive_application_root("));
    assert!(source.contains("OsRng.fill_bytes(root_seed.as_mut())"));
    assert!(source.contains("decrypt_root_seed_exchange"));
    assert!(source.contains("into_transport_mode()"));
}

#[tokio::test]
async fn relay_e2ee_uses_real_session_id() {
    let attempt = run_relay_e2ee_handshake(false, false).await;

    assert_eq!(attempt.token.len(), crate::session::SESSION_ID_BYTES * 2);
    assert!(attempt
        .token
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
    assert_ne!(attempt.token, "0000000000000001");
    assert_eq!(attempt.observed_payloads.len(), 6);
    assert!(attempt
        .observed_payloads
        .iter()
        .all(|frame| frame.contains(&format!("\"session_id\":\"{}\"", attempt.token))));
    assert!(attempt
        .observed_payloads
        .iter()
        .all(|frame| !frame.contains("SMKR")));
}

#[tokio::test]
async fn relay_e2ee_completes_with_real_session_token() {
    let attempt = run_relay_e2ee_handshake(false, false).await;
    let (initiator_root, responder_root) = attempt.roots.expect("completed roots");

    assert_eq!(initiator_root, responder_root);
    assert!(attempt.connected);
    assert!(!attempt.root_seed_rejected);
    assert!(!attempt.missing_accept_rejected);
}

#[tokio::test]
async fn relay_e2ee_rejects_tampered_root_seed() {
    let attempt = run_relay_e2ee_handshake(true, false).await;

    assert!(attempt.root_seed_rejected);
    assert!(attempt.roots.is_none());
    assert!(!attempt.connected);
}

#[tokio::test]
async fn relay_e2ee_does_not_connect_without_accept() {
    let attempt = run_relay_e2ee_handshake(false, true).await;

    assert!(attempt.missing_accept_rejected);
    assert!(attempt.roots.is_none());
    assert!(!attempt.connected);
}

struct RelayE2eeAttempt {
    token: String,
    connected: bool,
    roots: Option<([u8; 32], [u8; 32])>,
    root_seed_rejected: bool,
    missing_accept_rejected: bool,
    observed_payloads: Vec<String>,
}

/// Drives the six opaque Relay controls through the production RelayClient.
/// `tamper_root_seed` mutates the encrypted Noise transport frame after the
/// Relay forwards it; `omit_accept` stops before the initiator can obtain
/// application material or mark the Session connected.
async fn run_relay_e2ee_handshake(tamper_root_seed: bool, omit_accept: bool) -> RelayE2eeAttempt {
    let server = FakeRelayServer::start().await;
    let server_address = server.address;
    let mut initiator_relay = RelayClient::new(
        format!("http://{server_address}"),
        "relay-initiator".into(),
        "test-credential-a".into(),
        [11u8; 32],
    )
    .expect("create test initiator RelayClient");
    let mut responder_relay = RelayClient::new(
        format!("http://{server_address}"),
        "relay-responder".into(),
        "test-credential-b".into(),
        [12u8; 32],
    )
    .expect("create test responder RelayClient");
    initiator_relay
        .connect()
        .await
        .expect("connect initiator RelayClient");
    responder_relay
        .connect()
        .await
        .expect("connect responder RelayClient");
    let mut initiator_events = initiator_relay
        .take_events()
        .expect("take initiator Relay events");
    let mut responder_events = responder_relay
        .take_events()
        .expect("take responder Relay events");

    let session_manager = crate::session::SessionManager::new();
    let session_id = match session_manager.begin_connect("relay-responder").await {
        crate::session::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let token = session_id.wire_key();
    let initiator_identity = Arc::new(DeviceIdentity::generate("relay-initiator".into()));
    let responder_identity = Arc::new(DeviceIdentity::generate("relay-responder".into()));

    let (mut initiator, hello) = crate::crypto_handshake::RelayInitiatorHandshake::start(
        Arc::clone(&initiator_identity),
        &token,
    )
    .expect("start Relay Noise handshake");
    send_relay_crypto_step(
        &initiator_relay,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_HELLO,
        &hello,
    )
    .await;
    let hello_at_responder = receive_relay_crypto_step(
        &mut responder_events,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_HELLO,
    )
    .await;
    let (responder, response) = crate::crypto_handshake::RelayResponderHandshake::accept_hello(
        Arc::clone(&responder_identity),
        &hello_at_responder,
    )
    .expect("accept Relay Noise hello");
    send_relay_crypto_step(
        &responder_relay,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        &response,
    )
    .await;
    let response_at_initiator = receive_relay_crypto_step(
        &mut initiator_events,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
    )
    .await;
    let final_message = initiator
        .accept_response(
            &response_at_initiator,
            &responder_identity.device_id,
            responder_identity.public_identity_key().to_bytes(),
        )
        .expect("accept Relay Noise response");
    send_relay_crypto_step(
        &initiator_relay,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_FINAL,
        &final_message,
    )
    .await;
    let final_at_responder = receive_relay_crypto_step(
        &mut responder_events,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_FINAL,
    )
    .await;
    let trusted_peer_keys = RwLock::new(HashMap::from([(
        initiator_identity.device_id.clone(),
        initiator_identity.public_identity_key().to_bytes(),
    )]));
    let (peer_id, confirmer, mut encrypted_seed) = responder
        .accept_final(&final_at_responder, &trusted_peer_keys, |_, binding| {
            let binding = binding.to_string();
            async move { Ok((binding, ())) }
        })
        .await
        .expect("accept Relay Noise final");
    assert_eq!(peer_id, initiator_identity.device_id);
    if tamper_root_seed {
        encrypted_seed[0] ^= 0x40;
    }
    send_relay_crypto_step(
        &responder_relay,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
        &encrypted_seed,
    )
    .await;
    let seed_at_initiator = receive_relay_crypto_step(
        &mut initiator_events,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
    )
    .await;
    let confirmation = match initiator.accept_root_seed(&seed_at_initiator) {
        Ok(value) => value,
        Err(_) => {
            return RelayE2eeAttempt {
                token,
                connected: session_manager.is_connected("relay-responder").await,
                roots: None,
                root_seed_rejected: true,
                missing_accept_rejected: false,
                observed_payloads: server.observed_payloads(),
            };
        }
    };
    let (confirmation, encrypted_confirm) = confirmation
        .confirm(token.clone())
        .expect("confirm Relay root with local Session binding");
    send_relay_crypto_step(
        &initiator_relay,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
        &encrypted_confirm,
    )
    .await;
    let confirm_at_responder = receive_relay_crypto_step(
        &mut responder_events,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
    )
    .await;
    let (peer_id, encrypted_accept, responder_material, _) = confirmer
        .accept_root_confirm(&confirm_at_responder)
        .expect("accept Relay root confirmation");
    assert_eq!(peer_id, initiator_identity.device_id);
    if omit_accept {
        let missing_accept_rejected = confirmation.accept(&[]).is_err();
        return RelayE2eeAttempt {
            token,
            connected: session_manager.is_connected("relay-responder").await,
            roots: None,
            root_seed_rejected: false,
            missing_accept_rejected,
            observed_payloads: server.observed_payloads(),
        };
    }
    send_relay_crypto_step(
        &responder_relay,
        &token,
        "relay-initiator",
        crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
        &encrypted_accept,
    )
    .await;
    let accept_at_initiator = receive_relay_crypto_step(
        &mut initiator_events,
        &token,
        "relay-responder",
        crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
    )
    .await;
    let initiator_material = confirmation
        .accept(&accept_at_initiator)
        .expect("accept Relay application root");
    assert!(
        session_manager
            .mark_relay_route_connected("relay-responder", session_id, RouteType::Relay, None)
            .await
    );
    RelayE2eeAttempt {
        token,
        connected: session_manager.is_connected("relay-responder").await,
        roots: Some((initiator_material.root_key, responder_material.root_key)),
        root_seed_rejected: false,
        missing_accept_rejected: false,
        observed_payloads: server.observed_payloads(),
    }
}

async fn send_relay_crypto_step(
    client: &RelayClient,
    token: &str,
    target_id: &str,
    step: u8,
    payload: &[u8],
) {
    let frame = crate::crypto_handshake::encode_relay_frame(step, payload)
        .expect("encode Relay crypto frame");
    client
        .send_crypto_handshake(token, target_id, &frame)
        .await
        .expect("send Relay crypto frame");
}

async fn receive_relay_crypto_step(
    events: &mut mpsc::Receiver<RelayEvent>,
    token: &str,
    expected_sender: &str,
    expected_step: u8,
) -> Vec<u8> {
    let event = tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .expect("Relay crypto event timed out")
        .expect("Relay crypto event stream ended");
    let RelayEvent::Control {
        kind,
        session_id,
        peer_id,
        payload: Some(payload),
    } = event
    else {
        panic!("unexpected Relay crypto event");
    };
    assert_eq!(kind, "crypto_handshake");
    assert_eq!(session_id, token);
    assert_eq!(peer_id.as_deref(), Some(expected_sender));
    let frame = URL_SAFE_NO_PAD
        .decode(payload)
        .expect("decode opaque Relay crypto payload");
    let (step, payload) =
        crate::crypto_handshake::decode_relay_frame(&frame).expect("decode Relay crypto frame");
    assert_eq!(step, expected_step);
    payload.to_vec()
}

struct FakeRelayServer {
    address: SocketAddr,
    observed: Arc<Mutex<Vec<String>>>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl FakeRelayServer {
    async fn start() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind fake Relay listener");
        let address = listener.local_addr().expect("fake Relay address");
        let observed = Arc::new(Mutex::new(Vec::new()));
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(run_fake_relay(listener, Arc::clone(&observed), shutdown_rx));
        Self {
            address,
            observed,
            shutdown: Some(shutdown),
            task: Some(task),
        }
    }

    fn observed_payloads(&self) -> Vec<String> {
        self.observed
            .lock()
            .expect("fake Relay observations")
            .clone()
    }
}

impl Drop for FakeRelayServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

async fn run_fake_relay(
    listener: TcpListener,
    observed: Arc<Mutex<Vec<String>>>,
    mut shutdown: oneshot::Receiver<()>,
) {
    let (incoming_tx, mut incoming_rx) = mpsc::channel::<(String, Message)>(32);
    let mut outbound = HashMap::<String, mpsc::Sender<Message>>::new();
    for device_id in ["relay-initiator", "relay-responder"] {
        let (stream, _) = tokio::select! {
            result = listener.accept() => match result {
                Ok(value) => value,
                Err(_) => return,
            },
            _ = &mut shutdown => return,
        };
        let socket = match accept_async(stream).await {
            Ok(socket) => socket,
            Err(_) => return,
        };
        let (mut writer, reader) = socket.split();
        let ready = serde_json::json!({
            "type": "ready",
            "device_id": device_id,
            "protocol_version": 1,
        });
        if writer
            .send(Message::Text(ready.to_string().into()))
            .await
            .is_err()
        {
            return;
        }
        let (outbound_tx, mut outbound_rx) = mpsc::channel::<Message>(32);
        std::mem::drop(tokio::spawn(async move {
            while let Some(message) = outbound_rx.recv().await {
                if writer.send(message).await.is_err() {
                    break;
                }
            }
        }));
        let incoming_tx = incoming_tx.clone();
        let sender_id = device_id.to_string();
        std::mem::drop(tokio::spawn(async move {
            let mut reader = reader;
            while let Some(result) = reader.next().await {
                let Ok(message) = result else {
                    break;
                };
                if incoming_tx
                    .send((sender_id.clone(), message))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        }));
        outbound.insert(device_id.to_string(), outbound_tx);
    }
    drop(incoming_tx);

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            incoming = incoming_rx.recv() => {
                let Some((sender_id, Message::Text(text))) = incoming else {
                    break;
                };
                let Ok(mut value) = serde_json::from_str::<serde_json::Value>(text.as_ref()) else {
                    continue;
                };
                if value.get("type").and_then(serde_json::Value::as_str) == Some("heartbeat") {
                    if let Some(target) = outbound.get(&sender_id) {
                        let _ = target
                            .send(Message::Text(
                                serde_json::json!({"type": "heartbeat_ack"})
                                    .to_string()
                                    .into(),
                            ))
                            .await;
                    }
                    continue;
                }
                let Some(target_id) = value
                    .get("target_id")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string)
                else {
                    continue;
                };
                observed
                    .lock()
                    .expect("fake Relay observations")
                    .push(text.to_string());
                value["sender_id"] = serde_json::Value::String(sender_id);
                let Ok(forwarded) = serde_json::to_string(&value) else {
                    continue;
                };
                if let Some(target) = outbound.get(&target_id) {
                    let _ = target
                        .send(Message::Text(forwarded.into()))
                        .await;
                }
            }
            else => break,
        }
    }
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
        let session_key = session_id.wire_key();
        let first = crate::delivery::MessageId::from_bytes([90; 16]);
        let buffered = crate::delivery::MessageId::from_bytes([91; 16]);
        assert_eq!(
            state
                .delivery
                .begin_incoming(&session_key, "control", first, 1, Instant::now())
                .await,
            crate::delivery::DedupDecision::New
        );
        assert_eq!(
            state
                .delivery
                .accept_ordered(crate::delivery::OrderedMessage {
                    peer_id: "delivery-peer".into(),
                    session_id: session_key.clone(),
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
                .begin_incoming(&session_key, "control", buffered, 1, Instant::now())
                .await,
            crate::delivery::DedupDecision::New
        );
        assert_eq!(
            state
                .delivery
                .accept_ordered(crate::delivery::OrderedMessage {
                    peer_id: "delivery-peer".into(),
                    session_id: session_key.clone(),
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
            .expire_incoming(&session_key, Instant::now() + Duration::from_secs(11))
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
    let route_metrics = poll_until(&runtime_a, Duration::from_secs(5), |event| {
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
    let offer = poll_until(&runtime_b, Duration::from_secs(10), |event| {
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
    let completed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
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

/// 验证未 ACK 的消息在底层 Connection 断开后沿同一逻辑 Session 重放，
/// 且接收端 dedup 不会再次把同一个 MessageId 交给应用。
#[test]
fn delivery_recovery_replays_same_message_across_reconnected_connection() {
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
    let first_message = poll_until(&runtime_b, Duration::from_secs(5), |event| {
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

    runtime_a.close_peer_connection_for_test("delivery-b");
    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "delivery-b"
                    && state.state == PeerConnectionState::Disconnected as i32
        )
    })
    .is_some());

    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "delivery-b"
                    && state.state == PeerConnectionState::Connected as i32
        )
    })
    .is_some());

    // 不在第一次事件后 ACK；Connection #2 重放的重复 DataMessage 仍处于
    // InFlight，所以接收端既不重新发布事件，也不能自动 ACK。
    let unexpected_ack = poll_until(&runtime_a, Duration::from_millis(700), |event| {
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

    // 重放只能更新 DeliveryManager 内部的 epoch；应用事件不携带旧 epoch，
    // 应用 ACK 也不需要保存它。显式 ACK 必须使用当前恢复周期的 epoch。
    let duplicate = poll_until(&runtime_b, Duration::from_millis(500), |event| {
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
    let recovered_ack = poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                message_id: acknowledged_id,
                recovery_epoch,
                ..
            })) if peer_id == "delivery-b"
                && acknowledged_id == &message_id
                && *recovery_epoch >= 2
        )
    });
    assert!(
        recovered_ack.is_some(),
        "explicit ACK did not use the latest recovery epoch"
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
    let explicit_message = poll_until(&runtime_b, Duration::from_secs(5), |event| {
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
    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
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
    let orphaned_manifest = FileManifest {
        transfer_id: orphaned_transfer_id.into(),
        file_name: "restart-payload.bin".into(),
        file_size: 1,
        modified_at: 0,
        content_hash: "00".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    runtime_b.handle().block_on(async {
        assert!(
            state_b
                .transfers
                .register_outgoing(
                    orphaned_manifest,
                    test_root.join("restart-payload.bin"),
                    "restart-a".into(),
                    old_b_session_id.wire_key(),
                )
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
            .is_none()
    }));
    assert!(poll_until(&runtime_b, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::TransferFailed(transfer))
                if transfer.transfer_id == orphaned_transfer_id
        )
    })
    .is_some());

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
#[test]
fn tcp_fallback_authenticates_delivery_and_keeps_session_id() {
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
    runtime_a.handle().block_on(route.close());
    assert!(poll_until(&runtime_a, Duration::from_secs(5), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "tcp-b"
                    && state.state == PeerConnectionState::Disconnected as i32
        )
    })
    .is_some());
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
    assert_eq!(original_session_id, reconnected_session_id);
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

/// A pending Delivery item is kept under the logical Session while the
/// authenticated route changes from TCP to a newly available QUIC endpoint.
/// The old carrier is closed only after the atomic Session swap.
#[test]
fn tcp_to_quic_migration_preserves_pending_delivery_and_session_id() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_tcp = NetworkRuntime::new().expect("TCP peer runtime");
    runtime_a.start().expect("start runtime A");
    runtime_tcp.start().expect("start TCP peer runtime");
    let test_root = std::env::temp_dir().join(format!(
        "ssh-mobile-route-migration-{}",
        rand::random::<u64>()
    ));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [141u8; 32];
    let identity_seed_peer = [142u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("migration-a".into(), identity_seed_a, [151u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_peer =
        DeviceIdentity::from_private_keys("migration-peer".into(), identity_seed_peer, [152u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "migration-a",
        identity_seed_a,
        [151u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_tcp = configure_runtime_for_test(
        &runtime_tcp,
        "migration-peer",
        identity_seed_peer,
        [152u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-tcp"),
    );
    let tcp_state = runtime_tcp
        .state
        .lock()
        .expect("TCP peer state lock")
        .clone()
        .expect("TCP peer state");
    runtime_tcp.handle().block_on(async {
        tcp_state
            .endpoint
            .read()
            .await
            .as_ref()
            .expect("TCP peer endpoint")
            .close(quinn::VarInt::from_u32(0), b"migration TCP phase");
    });
    send_and_expect_accepted(
        &runtime_a,
        upsert_command(
            "migration-upsert-peer-tcp",
            "migration-peer",
            address_tcp,
            public_key_peer,
            [152u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_tcp,
        upsert_command(
            "migration-tcp-upsert-a",
            "migration-a",
            address_a,
            public_key_a,
            [151u8; 32],
        ),
    );
    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "migration-connect".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "migration-peer".into(),
                intent: 0,
            })),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(25), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::PeerState(state))
                if state.peer_id == "migration-peer"
                    && state.state == PeerConnectionState::Connected as i32
                    && state.route_transport == RouteTransport::Tcp as i32
        )
    })
    .is_some());
    let state_a = runtime_a
        .state
        .lock()
        .expect("runtime A state lock")
        .clone()
        .expect("runtime A state");
    let (session_id, old_route) = runtime_a.handle().block_on(async {
        let session_id = state_a
            .sessions
            .current_session_id("migration-peer")
            .await
            .expect("migration Session ID");
        let route = state_a
            .sessions
            .current_active_route("migration-peer")
            .await
            .expect("TCP active route");
        (session_id, route)
    });
    let old_accept_task = *tcp_state.accept_task.lock().expect("TCP accept task lock");
    runtime_tcp.handle().block_on(async {
        let old_endpoint = tcp_state.endpoint.write().await.take();
        if let Some(old_endpoint) = old_endpoint {
            old_endpoint.close(quinn::VarInt::from_u32(0), b"migration TCP phase ended");
        }
        if let Some(task_id) = old_accept_task {
            tcp_state.task_supervisor.cancel_task(task_id).await;
        }
    });
    let replacement_socket = std::net::UdpSocket::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .expect("bind replacement QUIC endpoint for route migration");
    replacement_socket
        .set_nonblocking(true)
        .expect("configure migration QUIC socket");
    let replacement_endpoint = runtime_tcp.handle().block_on(async {
        network_quic::QuicEndpointManager::from_bound_socket(
            replacement_socket,
            Arc::new(network_nat::PathManager::new()),
        )
        .expect("create replacement QUIC endpoint")
        .endpoint
    });
    let replacement_address = replacement_endpoint
        .local_addr()
        .expect("read replacement QUIC endpoint address");
    let replacement_accept_task = runtime_tcp.handle().block_on(async {
        *tcp_state.endpoint.write().await = Some(replacement_endpoint.clone());
        tcp_state
            .task_supervisor
            .spawn_runtime(
                "migration-quic-accept",
                crate::peer::accept_connections(
                    replacement_endpoint.clone(),
                    Arc::clone(&tcp_state),
                ),
            )
            .expect("spawn replacement QUIC accept task")
    });
    *tcp_state
        .accept_task
        .lock()
        .expect("replacement accept task lock") = Some(replacement_accept_task);
    let original_context = state_a
        .crypto
        .get("migration-peer", &session_id.wire_key())
        .expect("original Session crypto context");
    let original_epoch = original_context
        .lock()
        .expect("original Session crypto lock")
        .current_epoch();
    runtime_a
        .handle()
        .block_on(state_a.delivery.enqueue_with_crypto(
            &session_id.wire_key(),
            "control",
            b"pending-before-quic".to_vec(),
            crate::delivery::DeliveryPolicy::AckedDeduplicated,
            crate::crypto::CryptoMode::None,
            Default::default(),
        ))
        .expect("queue pending migration Delivery");
    runtime_a.handle().block_on(async {
        state_a
            .peers
            .write()
            .await
            .get_mut("migration-peer")
            .expect("migration peer config")
            .endpoint = Some(replacement_address);
    });
    let identity = runtime_a.handle().block_on(async {
        state_a
            .identity
            .read()
            .await
            .clone()
            .expect("migration identity")
    });
    let endpoint = runtime_a.handle().block_on(async {
        state_a
            .endpoint
            .read()
            .await
            .clone()
            .expect("migration QUIC endpoint")
    });
    let (replacement, crypto, admission) = runtime_a
        .handle()
        .block_on(crate::peer::connect_direct_with_crypto(
            endpoint,
            replacement_address,
            identity,
            public_key_peer,
            "migration-peer".into(),
            "migration-attempt".into(),
            Duration::from_secs(5),
            &session_id.wire_key(),
            Arc::clone(&state_a),
            session_id,
        ))
        .expect("authenticated QUIC replacement");
    runtime_a.handle().block_on(async {
        state_a
            .install_crypto_material(
                "migration-peer",
                &session_id.wire_key(),
                &crypto,
                admission.decision,
            )
            .expect("install replacement E2EE context");
    });
    let replacement_context = state_a
        .crypto
        .get("migration-peer", &session_id.wire_key())
        .expect("replacement route Session crypto context");
    assert!(std::sync::Arc::ptr_eq(
        &original_context,
        &replacement_context
    ));
    assert_eq!(
        replacement_context
            .lock()
            .expect("replacement Session crypto lock")
            .current_epoch(),
        original_epoch
    );
    let replacement_receiver = replacement.clone();
    let previous = runtime_a
        .handle()
        .block_on(async {
            if state_a
                .sessions
                .current_active_route("migration-peer")
                .await
                .is_some()
            {
                state_a
                    .sessions
                    .replace_active_route_if_current(
                        "migration-peer",
                        session_id,
                        &old_route,
                        crate::session::ActiveRoute::quic(replacement, RouteType::QuicDirect),
                    )
                    .await
                    .map(Some)
            } else {
                Some(
                    state_a
                        .sessions
                        .attach_connection_for_session(
                            "migration-peer",
                            Some(session_id),
                            replacement,
                            RouteType::QuicDirect,
                            true,
                        )
                        .await
                        .expect("attach route after old callback"),
                )
            }
        })
        .expect("atomic TCP to QUIC route swap");
    if let Some(previous) = previous {
        runtime_a.handle().block_on(previous.close());
    }
    runtime_a.handle().block_on(async {
        crate::peer::spawn_session_receivers(
            state_a.clone(),
            "migration-peer".into(),
            replacement_receiver,
            session_id,
        );
    });
    runtime_a.handle().block_on(crate::channel::recover_session(
        state_a.clone(),
        "migration-peer".into(),
        session_id,
    ));
    let received = poll_until(&runtime_tcp, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::ChannelMessage(message))
                if message.peer_id == "migration-a"
                    && message.payload == b"pending-before-quic"
        )
    })
    .expect("pending Delivery was not recovered on QUIC");
    let (remote_session_id, message_id) = match received.payload {
        Some(network_event::Payload::ChannelMessage(message)) => {
            (message.session_id, message.message_id)
        }
        _ => unreachable!("predicate already checked the event"),
    };
    send_and_expect_accepted(
        &runtime_tcp,
        NetworkCommand {
            command_id: "migration-ack".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::AcknowledgeMessage(
                AcknowledgeMessageCommand {
                    peer_id: "migration-a".into(),
                    session_id: remote_session_id,
                    channel_id: "control".into(),
                    message_id,
                },
            )),
        },
    );
    assert!(poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id,
                ..
            })) if peer_id == "migration-peer"
        )
    })
    .is_some());
    let (same_session, transport) = runtime_a.handle().block_on(async {
        let profile = state_a
            .sessions
            .current_profile("migration-peer")
            .await
            .expect("migrated profile");
        (
            state_a
                .sessions
                .current_session_id("migration-peer")
                .await
                .expect("migrated Session ID"),
            profile.transport(),
        )
    });
    assert_eq!(same_session, session_id);
    assert_eq!(transport, crate::connection::RouteTransport::Quic);
    runtime_a.stop().expect("stop runtime A");
    runtime_tcp.stop().expect("stop TCP peer runtime");
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
fn send_and_expect_accepted(runtime: &NetworkRuntime, command: NetworkCommand) {
    let command_id = command.command_id.clone();
    runtime.send_command(command).expect("queue command");
    let result = poll_until(runtime, Duration::from_secs(10), |event| {
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
