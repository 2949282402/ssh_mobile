#[tokio::test]
async fn dispatch_command_routes_every_public_payload_to_its_boundary() {
    let state = Arc::new(RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let mut command_number = 0u32;
    let mut dispatch = |payload| {
        command_number += 1;
        let state = Arc::clone(&state);
        let command_id = format!("dispatch-boundary-{command_number}");
        async move {
            dispatch_command(
                NetworkCommand {
                    command_id,
                    protocol_version: NETWORK_PROTOCOL_VERSION,
                    payload: Some(payload),
                },
                state,
            )
            .await
        }
    };

    assert!(dispatch(network_command::Payload::ConfigureRuntime(
        Default::default()
    ))
    .await
    .is_err());
    assert!(
        dispatch(network_command::Payload::UpsertPeer(Default::default()))
            .await
            .is_err()
    );
    assert!(dispatch(network_command::Payload::UpsertPeerV2(
        network_protocol::UpsertPeerV2Command {
            config: Some(network_protocol::PeerConfig {
                peer_id: String::new(),
                e2ee_policy: network_protocol::E2eePolicy::Required as i32,
                ..Default::default()
            }),
        },
    ))
    .await
    .is_err());
    assert!(
        dispatch(network_command::Payload::ConnectPeer(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::SendFile(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::CancelTransfer(Default::default()))
            .await
            .is_err()
    );
    assert!(dispatch(network_command::Payload::RespondIncomingTransfer(
        Default::default(),
    ))
    .await
    .is_err());
    assert!(
        dispatch(network_command::Payload::SendMessage(Default::default()))
            .await
            .is_err()
    );
    assert!(dispatch(network_command::Payload::AcknowledgeMessage(
        Default::default()
    ))
    .await
    .is_err());
    assert!(dispatch(network_command::Payload::StartRealtimeSession(
        Default::default(),
    ))
    .await
    .is_err());
    assert!(dispatch(network_command::Payload::StopRealtimeSession(
        Default::default()
    ))
    .await
    .is_err());
    assert!(dispatch(network_command::Payload::SendRealtimeSignal(
        Default::default(),
    ))
    .await
    .is_err());
    assert!(
        dispatch(network_command::Payload::ConfigureRelay(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::DisconnectPeer(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::RemovePeer(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::SendMessageV2(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::Transfer(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::PeerDiagnostics(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::NetworkEnvironmentChanged(
            Default::default(),
        ))
        .await
        .is_ok()
    );
    assert!(
        dispatch(network_command::Payload::DisconnectRelay(Default::default()))
            .await
            .is_ok()
    );
    assert!(
        dispatch(network_command::Payload::SshStreamOpen(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::SshStreamData(Default::default()))
            .await
            .is_err()
    );
    assert!(
        dispatch(network_command::Payload::SshStreamClose(Default::default()))
            .await
            .is_err()
    );
}
