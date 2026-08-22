use super::*;

use network_protocol::{network_event, NetworkEvent, NETWORK_PROTOCOL_VERSION};
use std::sync::atomic::AtomicU16;
use tokio::sync::{mpsc, oneshot};

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
    tokio::fs::remove_dir_all(&root).await.unwrap();
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
