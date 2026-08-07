//! v1 运行时生命周期与传输契约的集成式测试。
// v1 原生运行时、命令接受、传输和清理回归测试。

use super::*;
use network_identity::DeviceIdentity;

use network_protocol::{
    network_command, network_event, CommandResultEvent, ConfigureRuntimeCommand,
    ConnectPeerCommand, NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    PeerConnectionState, RespondIncomingTransferCommand, RouteType, SendFileCommand,
    UpsertPeerCommand, NETWORK_PROTOCOL_VERSION,
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

/// 验证直连 QUIC 认证和审批门控文件传输。
#[test]
fn two_runtimes_authenticate_and_transfer_a_verified_file() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let address_a = available_loopback_address();
    let address_b = available_loopback_address();
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
    fs::write(&source_path, b"verified native QUIC payload").expect("source file");

    send_and_expect_accepted(
        &runtime_a,
        NetworkCommand {
            command_id: "configure-a".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConfigureRuntime(
                ConfigureRuntimeCommand {
                    device_id: "device-a".into(),
                    identity_private_key: identity_seed_a.to_vec(),
                    e2e_private_key: vec![31u8; 32],
                    listen_address: address_a.to_string(),
                    receive_directory: receive_a.to_string_lossy().to_string(),
                },
            )),
        },
    );
    send_and_expect_accepted(
        &runtime_b,
        NetworkCommand {
            command_id: "configure-b".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConfigureRuntime(
                ConfigureRuntimeCommand {
                    device_id: "device-b".into(),
                    identity_private_key: identity_seed_b.to_vec(),
                    e2e_private_key: vec![32u8; 32],
                    listen_address: address_b.to_string(),
                    receive_directory: receive_b.to_string_lossy().to_string(),
                },
            )),
        },
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command("peer-b", "device-b", address_b, public_key_b),
    );
    send_and_expect_accepted(
        &runtime_b,
        upsert_command("peer-a", "device-a", address_a, public_key_a),
    );
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

    const TRANSFER_ID: &str = "transfer-native-1";
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
        b"verified native QUIC payload"
    );
    fs::remove_dir_all(test_root).ok();
}

/// 为当前 v1 线协议契约创建对端 upsert 命令。
fn upsert_command(
    command_id: &str,
    peer_id: &str,
    endpoint: SocketAddr,
    public_key: [u8; 32],
) -> NetworkCommand {
    NetworkCommand {
        command_id: command_id.into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::UpsertPeer(UpsertPeerCommand {
            peer_id: peer_id.into(),
            endpoint_address: endpoint.to_string(),
            identity_public_key: public_key.to_vec(),
            e2e_public_key: vec![0u8; 32],
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
    .expect("command result");
    assert!(
        matches!(
            result.payload,
            Some(network_event::Payload::CommandResult(CommandResultEvent {
                accepted: true,
                ..
            }))
        ),
        "command {command_id} was rejected"
    );
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

/// 为隔离运行时测试分配未使用的 loopback UDP 地址。
fn available_loopback_address() -> SocketAddr {
    std::net::UdpSocket::bind("127.0.0.1:0")
        .expect("bind temporary socket")
        .local_addr()
        .expect("temporary socket address")
}
