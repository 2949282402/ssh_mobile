use super::*;

use network_protocol::{network_event, NetworkEvent, NETWORK_PROTOCOL_VERSION};
use sha2::Digest;
use std::sync::atomic::AtomicU16;
use tokio::io::AsyncWriteExt;
use tokio::sync::{mpsc, oneshot};

async fn quic_pair() -> (quinn::Endpoint, quinn::Connection, quinn::Connection) {
    let server = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().unwrap(),
        Arc::new(network_nat::PathManager::new()),
    )
    .unwrap();
    let client = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().unwrap(),
        Arc::new(network_nat::PathManager::new()),
    )
    .unwrap();
    let server_addr = server.endpoint.local_addr().unwrap();
    let server_endpoint = server.endpoint;
    let server_connection = tokio::spawn(async move {
        server_endpoint
            .accept()
            .await
            .expect("incoming file test connection")
            .await
            .expect("file test server connection")
    });
    let client_endpoint = client.endpoint;
    let client_connection = client_endpoint
        .connect(server_addr, "ssh-mobile")
        .unwrap()
        .await
        .unwrap();
    let server_connection = server_connection.await.unwrap();
    (client_endpoint, client_connection, server_connection)
}

fn state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
}

fn manifest(transfer_id: &str) -> network_transfer::FileManifest {
    network_transfer::FileManifest {
        transfer_id: transfer_id.into(),
        file_name: "payload.bin".into(),
        file_size: 4,
        modified_at: 1,
        content_hash: "a".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

async fn ready_stream_lease(state: &Arc<RuntimeState>) -> crate::connect::PathLease {
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(
        crate::connect::PeerId::new("peer-a").expect("peer"),
        Arc::clone(&registry),
    );
    let handle = manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("ready incoming transfer path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));
    registry.acquire(&handle).expect("incoming transfer lease")
}

async fn wait_for_incoming_decision(state: &RuntimeState, transfer_id: &str) {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            if state
                .transfer
                .incoming_decisions
                .read()
                .await
                .contains_key(transfer_id)
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("incoming transfer approval waiter");
}

#[tokio::test]
async fn start_file_send_rejects_invalid_source_and_missing_route_before_dispatch() {
    let state = state();
    let invalid = start_file_send(
        Arc::clone(&state),
        SendFileCommand {
            transfer_id: "bad id".into(),
            peer_id: "peer-a".into(),
            file_path: "file.bin".into(),
        },
    )
    .await
    .expect_err("invalid transfer identity must fail");
    assert_eq!(invalid.code, NetworkErrorCode::InvalidArgument as i32);

    let missing = start_file_send(
        Arc::clone(&state),
        SendFileCommand {
            transfer_id: "transfer-a".into(),
            peer_id: "peer-a".into(),
            file_path: "/path/that/does/not/exist".into(),
        },
    )
    .await
    .expect_err("missing source must fail");
    assert_eq!(missing.code, NetworkErrorCode::IoError as i32);

    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-transfer-operation-test-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let directory_error = start_file_send(
        Arc::clone(&state),
        SendFileCommand {
            transfer_id: "transfer-dir".into(),
            peer_id: "peer-a".into(),
            file_path: root.to_string_lossy().into_owned(),
        },
    )
    .await
    .expect_err("directory cannot be sent as a regular file");
    assert_eq!(
        directory_error.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let source = root.join("source.bin");
    tokio::fs::write(&source, b"data").await.unwrap();
    let no_peer = start_file_send(
        Arc::clone(&state),
        SendFileCommand {
            transfer_id: "transfer-no-peer".into(),
            peer_id: "peer-a".into(),
            file_path: source.to_string_lossy().into_owned(),
        },
    )
    .await
    .expect_err("unregistered peer must fail closed");
    assert_eq!(no_peer.code, NetworkErrorCode::NoRoute as i32);

    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    let _lease = ready_stream_lease(&state).await;
    let no_carrier = start_file_send(
        Arc::clone(&state),
        SendFileCommand {
            transfer_id: "transfer-no-carrier".into(),
            peer_id: "peer-a".into(),
            file_path: source.to_string_lossy().into_owned(),
        },
    )
    .await
    .expect_err("a non-stream path must fail before registering the transfer");
    assert_eq!(no_carrier.code, NetworkErrorCode::NoRoute as i32);
    tokio::fs::remove_dir_all(&root).await.unwrap();
}

#[tokio::test]
async fn business_path_fallback_returns_a_typed_no_route_error() {
    let state = state();
    let error = ensure_business_path(
        &state,
        "peer-a",
        "transfer-fallback",
        CommunicationClass::BulkTransfer,
        CAPABILITY_RELIABLE_STREAM,
    )
    .await
    .expect_err("missing path and runtime inputs must fail closed");
    assert!(
        matches!(
            error,
            CoreNetworkError::Cancelled
                | CoreNetworkError::NoRoute
                | CoreNetworkError::InvalidPeerId
        ),
        "unexpected fallback error: {error:?}"
    );
}

#[tokio::test]
async fn incoming_decision_routes_to_waiter_and_reports_expiry() {
    let state = state();
    let (decision_tx, decision_rx) = oneshot::channel();
    state
        .transfer
        .incoming_decisions
        .write()
        .await
        .insert("transfer-a".into(), decision_tx);
    respond_to_incoming(
        &state,
        RespondIncomingTransferCommand {
            transfer_id: "transfer-a".into(),
            accept: true,
        },
    )
    .await
    .expect("local decision should route");
    assert!(decision_rx.await.unwrap());

    let (expired_tx, expired_rx) = oneshot::channel();
    state
        .transfer
        .incoming_decisions
        .write()
        .await
        .insert("transfer-expired".into(), expired_tx);
    drop(expired_rx);
    let expired = respond_to_incoming(
        &state,
        RespondIncomingTransferCommand {
            transfer_id: "transfer-expired".into(),
            accept: false,
        },
    )
    .await
    .expect_err("closed decision waiter must be reported");
    assert_eq!(expired.code, NetworkErrorCode::Cancelled as i32);

    let unknown = respond_to_incoming(
        &state,
        RespondIncomingTransferCommand {
            transfer_id: "missing".into(),
            accept: false,
        },
    )
    .await
    .expect_err("unknown decision must route to relay and fail without an offer");
    assert_eq!(unknown.code, NetworkErrorCode::InvalidArgument as i32);
}

#[tokio::test]
async fn dispatch_transfer_command_rejects_unknown_and_missing_active_transfers() {
    let state = state();
    let unsupported = dispatch_transfer_command(
        Arc::clone(&state),
        NetworkCommand {
            command_id: "unsupported".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_protocol::network_command::Payload::DisconnectRelay(
                Default::default(),
            )),
        },
    )
    .await
    .expect_err("non-transfer command must be rejected by transfer adapter");
    assert_eq!(unsupported.code, NetworkErrorCode::InvalidArgument as i32);

    let missing = dispatch_transfer_command(
        Arc::clone(&state),
        NetworkCommand {
            command_id: "cancel-missing".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_protocol::network_command::Payload::CancelTransfer(
                network_protocol::CancelTransferCommand {
                    transfer_id: "missing".into(),
                },
            )),
        },
    )
    .await
    .expect_err("cancel must reject a missing transfer");
    assert_eq!(missing.code, NetworkErrorCode::InvalidArgument as i32);
}

#[tokio::test]
async fn progress_without_confirming_offset_emits_for_a_live_transfer() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let manager = state.transfer.manager.clone();
    assert!(
        manager
            .register_outgoing(
                manifest("progress-no-confirm"),
                std::path::PathBuf::from("source.bin"),
                "peer-a".into(),
            )
            .await
    );
    let (progress_tx, progress_rx) = mpsc::channel(1);
    progress_tx.send((2, 4)).await.unwrap();
    drop(progress_tx);
    forward_progress(
        "progress-no-confirm".into(),
        "peer-a".into(),
        progress_rx,
        state.event_tx.clone(),
        manager.clone(),
        false,
    )
    .await;
    assert_eq!(
        manager
            .snapshot("progress-no-confirm")
            .await
            .unwrap()
            .confirmed_offset,
        0
    );
    assert!(matches!(
        event_rx.recv().await.expect("progress event").payload,
        Some(network_event::Payload::PeerTransferProgress(_))
    ));
}

#[tokio::test]
async fn resume_helpers_ignore_invalid_peer_and_missing_session() {
    let state = state();
    resume_transfers_for_peer(Arc::clone(&state), String::new()).await;
    resume_transfers_for_peer(Arc::clone(&state), "peer-a".into()).await;
    resume_relay_transfers(Arc::clone(&state)).await;
}

#[tokio::test]
async fn file_offer_parser_rejects_bad_protocol_lengths_and_utf8() {
    let (endpoint, client, server) = quic_pair().await;
    let (mut send, _) = client.open_bi().await.unwrap();
    send.write_u32(NETWORK_TRANSFER_PROTOCOL_VERSION + 1)
        .await
        .unwrap();
    send.finish().unwrap();
    let (_, mut receive) = server.accept_bi().await.unwrap();
    assert!(read_file_offer_after_magic(&mut receive).await.is_err());

    let (mut send, _) = client.open_bi().await.unwrap();
    send.write_u32(NETWORK_TRANSFER_PROTOCOL_VERSION)
        .await
        .unwrap();
    send.write_u16(0).await.unwrap();
    send.finish().unwrap();
    let (_, mut receive) = server.accept_bi().await.unwrap();
    assert!(read_file_offer_after_magic(&mut receive).await.is_err());

    let (mut send, _) = client.open_bi().await.unwrap();
    send.write_u16(2).await.unwrap();
    send.write_all(&[0xff, 0xff]).await.unwrap();
    send.finish().unwrap();
    let (_, mut receive) = server.accept_bi().await.unwrap();
    assert!(read_bounded_utf8(&mut receive, 8, "transfer ID")
        .await
        .is_err());

    let (mut send, _) = client.open_bi().await.unwrap();
    send.write_u16(9).await.unwrap();
    send.write_all(b"too-long!").await.unwrap();
    send.finish().unwrap();
    let (_, mut receive) = server.accept_bi().await.unwrap();
    assert!(read_bounded_utf8(&mut receive, 8, "file name")
        .await
        .is_err());
    endpoint.close(quinn::VarInt::from_u32(0), b"file parser test complete");
}

#[tokio::test]
async fn file_offer_parser_accepts_a_valid_manifest_after_magic() {
    let (endpoint, client, server) = quic_pair().await;
    let (mut send, _) = client.open_bi().await.unwrap();
    send.write_u32(NETWORK_TRANSFER_PROTOCOL_VERSION)
        .await
        .unwrap();
    send.write_u16(10).await.unwrap();
    send.write_all(b"transfer-a").await.unwrap();
    send.write_u16(8).await.unwrap();
    send.write_all(b"file.bin").await.unwrap();
    send.write_u64(4).await.unwrap();
    send.write_i64(7).await.unwrap();
    send.write_all(&[0xab; 32]).await.unwrap();
    send.finish().unwrap();
    let (_, mut receive) = server.accept_bi().await.unwrap();
    let manifest = read_file_offer_after_magic(&mut receive)
        .await
        .expect("valid file offer");
    assert_eq!(manifest.transfer_id, "transfer-a");
    assert_eq!(manifest.file_name, "file.bin");
    assert_eq!(manifest.file_size, 4);
    assert_eq!(manifest.modified_at, 7);
    assert_eq!(manifest.content_hash, "ab".repeat(32));
    endpoint.close(quinn::VarInt::from_u32(0), b"file parser test complete");
}

#[tokio::test]
async fn incoming_file_offer_rejects_inactive_carriers_and_invalid_identity() {
    let state = state();
    let lease = ready_stream_lease(&state).await;
    state.close_transport_path("peer-a").await;
    assert!(
        !lease.is_active(),
        "closed path must invalidate the incoming lease"
    );
    let (endpoint, client, server) = quic_pair().await;
    let (mut client_send, mut client_receive) = client.open_bi().await.unwrap();
    client_send.write_all(b"x").await.unwrap();
    let (server_send, server_receive) = server.accept_bi().await.unwrap();
    let task = tokio::spawn(handle_incoming_file_after_offer(
        "peer-a".into(),
        server_send,
        server_receive,
        manifest("inactive-transfer"),
        Arc::clone(&state),
        lease,
    ));
    drop(client_send);
    assert_eq!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            network_quic::read_file_decision(&mut client_receive),
        )
        .await
        .expect("inactive decision timeout")
        .expect("inactive decision"),
        None
    );
    task.await.unwrap();
    endpoint.close(quinn::VarInt::from_u32(0), b"inactive offer test complete");

    let state = self::state();
    let lease = ready_stream_lease(&state).await;
    let (endpoint, client, server) = quic_pair().await;
    let (mut client_send, mut client_receive) = client.open_bi().await.unwrap();
    client_send.write_all(b"x").await.unwrap();
    let (server_send, server_receive) = server.accept_bi().await.unwrap();
    let task = tokio::spawn(handle_incoming_file_after_offer(
        String::new(),
        server_send,
        server_receive,
        manifest("invalid-peer-transfer"),
        Arc::clone(&state),
        lease,
    ));
    drop(client_send);
    assert_eq!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            network_quic::read_file_decision(&mut client_receive),
        )
        .await
        .expect("invalid identity decision timeout")
        .expect("invalid identity decision"),
        None
    );
    task.await.unwrap();
    endpoint.close(quinn::VarInt::from_u32(0), b"invalid offer test complete");
}

#[tokio::test]
async fn outgoing_transfer_pauses_on_lost_path_and_fails_on_source_change() {
    let lost_state = state();
    let lease = ready_stream_lease(&lost_state).await;
    lost_state.close_transport_path("peer-a").await;
    assert!(!lease.is_active());
    assert!(
        lost_state
            .transfer
            .manager
            .register_outgoing(
                manifest("lost-outgoing"),
                std::path::PathBuf::from("missing.bin"),
                "peer-a".into(),
            )
            .await
    );
    let (endpoint, client, _server) = quic_pair().await;
    send_file(
        client,
        ResumableTransfer {
            transfer_id: "lost-outgoing".into(),
            peer_id: "peer-a".into(),
            session_id: "session-lost".into(),
            source_path: std::path::PathBuf::from("missing.bin"),
            manifest: manifest("lost-outgoing"),
            offset: 0,
        },
        Arc::clone(&lost_state),
        lease,
    )
    .await;
    assert_eq!(
        lost_state
            .transfer
            .manager
            .snapshot("lost-outgoing")
            .await
            .expect("lost transfer remains resumable")
            .state,
        network_transfer::TransferState::Paused
    );
    endpoint.close(quinn::VarInt::from_u32(0), b"outgoing pause test complete");

    let changed_state = state();
    let changed_lease = ready_stream_lease(&changed_state).await;
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-outgoing-source-change-{}",
        std::process::id()
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    let source = root.join("source.bin");
    tokio::fs::write(&source, b"changed").await.unwrap();
    let transfer_id = "changed-outgoing";
    assert!(
        changed_state
            .transfer
            .manager
            .register_outgoing(manifest(transfer_id), source.clone(), "peer-a".into(),)
            .await
    );
    let (endpoint, client, _server) = quic_pair().await;
    send_file(
        client,
        ResumableTransfer {
            transfer_id: transfer_id.into(),
            peer_id: "peer-a".into(),
            session_id: "session-changed".into(),
            source_path: source,
            manifest: manifest(transfer_id),
            offset: 0,
        },
        Arc::clone(&changed_state),
        changed_lease,
    )
    .await;
    assert!(changed_state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .is_none());
    endpoint.close(quinn::VarInt::from_u32(0), b"source change test complete");
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn incoming_file_offer_rejection_cleans_pending_transfer_state() {
    let state = state();
    let lease = ready_stream_lease(&state).await;
    let (endpoint, client, server) = quic_pair().await;
    let (mut client_send, mut client_receive) = client.open_bi().await.unwrap();
    client_send.write_all(b"x").await.unwrap();
    let (server_send, server_receive) = server.accept_bi().await.unwrap();
    let transfer_id = "rejected-transfer";
    let task = tokio::spawn(handle_incoming_file_after_offer(
        "peer-a".into(),
        server_send,
        server_receive,
        manifest(transfer_id),
        Arc::clone(&state),
        lease,
    ));
    wait_for_incoming_decision(&state, transfer_id).await;
    respond_to_incoming(
        &state,
        RespondIncomingTransferCommand {
            transfer_id: transfer_id.into(),
            accept: false,
        },
    )
    .await
    .expect("reject incoming transfer");
    drop(client_send);
    assert_eq!(
        network_quic::read_file_decision(&mut client_receive)
            .await
            .expect("rejection decision"),
        None
    );
    task.await.unwrap();
    assert!(state.transfer.manager.snapshot(transfer_id).await.is_none());
    endpoint.close(quinn::VarInt::from_u32(0), b"rejection test complete");
}

#[tokio::test]
async fn incoming_file_offer_accepts_stream_and_emits_completion() {
    let state = state();
    let root = std::env::temp_dir().join(format!(
        "ssh-mobile-incoming-transfer-{}-{}",
        std::process::id(),
        "stream"
    ));
    tokio::fs::create_dir_all(&root).await.unwrap();
    *state.lifecycle.receive_directory.write().await = Some(root.clone());
    let payload = b"data";
    let mut accepted_manifest = manifest("accepted-transfer");
    accepted_manifest.content_hash = hex::encode(sha2::Sha256::digest(payload));
    let lease = ready_stream_lease(&state).await;
    let (endpoint, client, server) = quic_pair().await;
    let (mut client_send, mut client_receive) = client.open_bi().await.unwrap();
    client_send.write_all(payload).await.unwrap();
    let (server_send, server_receive) = server.accept_bi().await.unwrap();
    let task = tokio::spawn(handle_incoming_file_after_offer(
        "peer-a".into(),
        server_send,
        server_receive,
        accepted_manifest.clone(),
        Arc::clone(&state),
        lease,
    ));
    wait_for_incoming_decision(&state, &accepted_manifest.transfer_id).await;
    respond_to_incoming(
        &state,
        RespondIncomingTransferCommand {
            transfer_id: accepted_manifest.transfer_id.clone(),
            accept: true,
        },
    )
    .await
    .expect("accept incoming transfer");
    let decision = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        network_quic::read_file_decision(&mut client_receive),
    )
    .await
    .expect("acceptance decision timeout")
    .expect("acceptance decision");
    assert_eq!(decision, Some(0));
    client_send.finish().unwrap();
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        network_quic::read_file_completion(&mut client_receive),
    )
    .await
    .expect("completion acknowledgement timeout")
    .expect("completion acknowledgement");
    tokio::time::timeout(std::time::Duration::from_secs(2), task)
        .await
        .expect("incoming handler timeout")
        .unwrap();
    assert!(state
        .transfer
        .manager
        .snapshot(&accepted_manifest.transfer_id)
        .await
        .is_none());
    assert_eq!(
        tokio::fs::read(root.join(&accepted_manifest.file_name))
            .await
            .unwrap(),
        payload
    );
    tokio::fs::remove_dir_all(root).await.unwrap();
    endpoint.close(quinn::VarInt::from_u32(0), b"accepted offer test complete");
}

#[test]
fn transient_transport_errors_walk_sources_and_keep_validation_errors_terminal() {
    for kind in [
        std::io::ErrorKind::BrokenPipe,
        std::io::ErrorKind::ConnectionAborted,
        std::io::ErrorKind::ConnectionReset,
        std::io::ErrorKind::NotConnected,
        std::io::ErrorKind::UnexpectedEof,
        std::io::ErrorKind::TimedOut,
    ] {
        assert!(is_transient_transport_error(&std::io::Error::from(kind)));
    }
    assert!(!is_transient_transport_error(&std::io::Error::from(
        std::io::ErrorKind::InvalidData,
    )));
}
