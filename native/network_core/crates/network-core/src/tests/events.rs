use super::*;
use network_protocol::network_event;

#[test]
fn command_result_emits_one_correlated_success_terminal() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);

    emit_command_result(
        &event_sender,
        "connect-a".into(),
        Some("peer-a".into()),
        Ok(()),
    );

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

#[test]
fn command_result_maps_stale_and_cancelled_errors_to_cancelled() {
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
        );

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

#[test]
fn command_result_maps_other_errors_to_failed_and_uses_command_scope() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let event_sender = EventSender::from(sender);
    emit_command_result(
        &event_sender,
        "message-a".into(),
        Some("peer-a".into()),
        Err(protocol_error(NetworkErrorCode::NoRoute, "no route")),
    );

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
