use super::*;
use crate::runtime_event_lanes::EventSender;
use network_protocol::network_event;
use network_protocol::{CommandResultState, NetworkErrorCode, PeerConnectionState};

#[tokio::test]
async fn command_result_emits_one_correlated_success_terminal() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);

    emit_command_result(
        &event_sender,
        "connect-a".into(),
        Some("peer-a".into()),
        Ok(()),
    )
    .await
    .expect("terminal result");

    let event = receiver.try_recv().expect("terminal event");
    let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
        panic!("expected CommandResultV2");
    };
    assert_eq!(result.command_id, "connect-a");
    assert_eq!(result.peer_id, "peer-a");
    assert_eq!(result.state, CommandResultState::Succeeded as i32);
    assert!(result.error.is_none());
    assert!(
        receiver.try_recv().is_err(),
        "terminal must be emitted once"
    );
}

#[tokio::test]
async fn command_result_maps_stale_and_cancelled_errors_to_cancelled() {
    for code in [
        NetworkErrorCode::Cancelled,
        NetworkErrorCode::StaleOperation,
    ] {
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let event_sender = EventSender::from(sender);
        emit_command_result(
            &event_sender,
            "connect-a".into(),
            Some("peer-a".into()),
            Err(protocol_error_with_peer(
                code,
                "cancelled",
                "connect",
                "peer-a",
            )),
        )
        .await
        .expect("terminal result");

        let event = receiver.try_recv().expect("terminal event");
        let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
            panic!("expected CommandResultV2");
        };
        assert_eq!(result.state, CommandResultState::Cancelled as i32);
        assert_eq!(result.peer_id, "peer-a");
        assert_eq!(result.error.expect("error").code, code as i32);
        assert!(
            receiver.try_recv().is_err(),
            "terminal must be emitted once"
        );
    }
}

#[tokio::test]
async fn command_result_maps_other_errors_to_failed_and_uses_command_scope() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);
    emit_command_result(
        &event_sender,
        "message-a".into(),
        Some("peer-a".into()),
        Err(protocol_error(NetworkErrorCode::NoRoute, "no route")),
    )
    .await
    .expect("terminal result");

    let event = receiver.try_recv().expect("terminal event");
    let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
        panic!("expected CommandResultV2");
    };
    assert_eq!(result.state, CommandResultState::Failed as i32);
    assert_eq!(result.peer_id, "peer-a");
    assert_eq!(
        result.error.expect("error").code,
        NetworkErrorCode::NoRoute as i32
    );
    assert!(
        receiver.try_recv().is_err(),
        "terminal must be emitted once"
    );
}

#[tokio::test]
async fn oversized_command_result_is_replaced_by_a_bounded_terminal_error() {
    let (event_sender, mut receiver) = crate::runtime_event_lanes::BoundedEventLanes::channel();
    emit_command_result(
        &event_sender,
        "oversized-result".into(),
        Some("peer-a".into()),
        Err(protocol_error(
            NetworkErrorCode::IoError,
            "x".repeat(crate::runtime_event_lanes::MAX_EVENT_BYTES),
        )),
    )
    .await
    .expect("bounded fallback result");

    let event = receiver.recv().await.expect("terminal event");
    let Some(network_event::Payload::CommandResultV2(result)) = event.payload else {
        panic!("expected CommandResultV2");
    };
    assert_eq!(result.command_id, "oversized-result");
    assert_eq!(result.peer_id, "peer-a");
    assert_eq!(result.state, CommandResultState::Failed as i32);
    assert_eq!(
        result.error.expect("bounded error").message,
        "command result exceeded native event limit"
    );
}

#[test]
fn peer_diagnostics_preserves_authoritative_owner_counts() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);
    emit_peer_diagnostics(
        &event_sender,
        network_protocol::PeerDiagnostics {
            peer_id: "peer-a".into(),
            state: PeerConnectionState::Connected as i32,
            e2ee_policy: 1,
            ready_path_count: 3,
            queued_command_count: 5,
            active_stream_count: 7,
            active_transfer_count: 11,
            last_error: None,
        },
    );

    let Some(network_event::Payload::PeerDiagnostics(diagnostics)) =
        receiver.try_recv().expect("diagnostics event").payload
    else {
        panic!("expected PeerDiagnostics");
    };
    assert_eq!(diagnostics.ready_path_count, 3);
    assert_eq!(diagnostics.queued_command_count, 5);
    assert_eq!(diagnostics.active_stream_count, 7);
    assert_eq!(diagnostics.active_transfer_count, 11);
}

#[test]
fn transfer_completed_event_preserves_peer_ownership() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);
    emit_transfer_completed(&event_sender, "peer-a", "tx-1", "/tmp/file.bin");

    let Some(network_event::Payload::TransferCompleted(completed)) =
        receiver.try_recv().expect("completed event").payload
    else {
        panic!("expected TransferCompleted");
    };
    assert_eq!(completed.peer_id, "peer-a");
    assert_eq!(completed.transfer_id, "tx-1");
    assert_eq!(completed.local_path, "/tmp/file.bin");
}

#[test]
fn transfer_progress_events_preserve_peer_ownership() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);

    // Tag 11: TransferProgressEvent
    emit_transfer_progress(&event_sender, "peer-b", "tx-relay-1", 1024, 4096);
    let Some(network_event::Payload::TransferProgress(progress)) =
        receiver.try_recv().expect("progress event").payload
    else {
        panic!("expected TransferProgress");
    };
    assert_eq!(progress.peer_id, "peer-b");
    assert_eq!(progress.transfer_id, "tx-relay-1");
    assert_eq!(progress.bytes_transferred, 1024);
    assert_eq!(progress.total_bytes, 4096);

    // Tag 32: PeerTransferProgressEvent
    emit_transfer_progress_for_peer(&event_sender, "peer-c", "tx-direct-1", 2048, 8192, false);
    let Some(network_event::Payload::PeerTransferProgress(peer_progress)) =
        receiver.try_recv().expect("peer progress event").payload
    else {
        panic!("expected PeerTransferProgress");
    };
    assert_eq!(peer_progress.peer_id, "peer-c");
    assert_eq!(peer_progress.transfer_id, "tx-direct-1");
    assert_eq!(peer_progress.confirmed_offset, 2048);
    assert_eq!(peer_progress.total_bytes, 8192);
    assert!(!peer_progress.paused);
}

#[test]
fn transfer_failed_event_preserves_peer_ownership() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);

    emit_transfer_error(
        &event_sender,
        "tx-err-1",
        NetworkErrorCode::IoError,
        "disk error".into(),
        "receive",
        Some("peer-d"),
    );
    let Some(network_event::Payload::TransferFailed(failed)) =
        receiver.try_recv().expect("failed event").payload
    else {
        panic!("expected TransferFailed");
    };
    assert_eq!(failed.peer_id, "peer-d");
    assert_eq!(failed.transfer_id, "tx-err-1");
    assert_eq!(
        failed.error.expect("error").code,
        NetworkErrorCode::IoError as i32
    );
}
