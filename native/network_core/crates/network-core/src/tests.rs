//! v1 运行时生命周期与传输契约的集成式测试。
// v1 原生运行时、命令接受、传输和清理回归测试。

use super::*;
use network_identity::DeviceIdentity;

use network_protocol::{
    network_command, network_event, AcknowledgeMessageCommand, ChannelMessageEvent,
    CommandResultEvent, ConfigureRuntimeCommand, ConnectPeerCommand, DeliveryAckedEvent,
    DeliveryPolicyCode, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    PeerConnectionState, RespondIncomingTransferCommand, RouteType, SendFileCommand,
    SendMessageCommand, UpsertPeerCommand, NETWORK_PROTOCOL_VERSION,
};
use std::fs;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

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
