use super::*;

#[test]
fn command_result_ledger_claims_each_id_once() {
    let ledger = CommandResultLedger::new();
    assert_eq!(ledger.claim("command-1"), Ok(true));
    assert_eq!(ledger.claim("command-1"), Ok(false));
    assert_eq!(ledger.claim("command-2"), Ok(true));
}

#[test]
fn connect_cancellation_requires_generation_invalidation() {
    let supervisor = PeerSupervisor::new(PeerId::new("peer-a").expect("valid peer"));
    let intent = supervisor
        .begin_connect("connect-a", CommunicationClass::ReliableMessage)
        .expect("connect intent");
    let generation = intent.generation;
    intent.detach_completion();

    // PeerSupervisor uses Cancelled for an unsuccessful attempt as well
    // as an explicit disconnect. The unchanged generation distinguishes
    // the former so commands can report Failed rather than Cancelled.
    assert!(!connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::Cancelled
    ));

    supervisor.disconnect();
    assert!(connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::Cancelled
    ));
    assert!(connect_completion_was_cancelled(
        &supervisor,
        generation,
        &CoreNetworkError::SupervisorStopping
    ));
}

#[tokio::test]
async fn environment_change_refreshes_discovery_revision() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    crate::discovery::begin_epoch(&state).await;

    dispatch_command(
        NetworkCommand {
            command_id: "environment-change".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::NetworkEnvironmentChanged(
                network_protocol::NetworkEnvironmentChangedCommand {
                    generation: 7,
                    has_connectivity: false,
                    is_foreground: true,
                    is_metered: false,
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect("environment change");

    assert_eq!(
        state
            .local_discovery
            .read()
            .await
            .as_ref()
            .expect("discovery manager")
            .revision(),
        2
    );
    assert!(matches!(
        receiver.try_recv().expect("environment event").payload,
        Some(network_protocol::network_event::Payload::NetworkEnvironmentChanged(event))
            if event.generation == 7 && !event.has_connectivity
    ));
}

#[tokio::test]
async fn remove_peer_evicts_configuration_and_supervisor() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state
        .trusted_peer_keys
        .write()
        .await
        .insert("peer-a".into(), [1; 32]);
    state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");

    remove_peer_v2(&state, "peer-a".into())
        .await
        .expect("remove peer");

    assert!(!state.peers.read().await.contains_key("peer-a"));
    assert!(!state.trusted_peer_keys.read().await.contains_key("peer-a"));
    assert_eq!(state.peer_supervisors.len(), 0);
}

#[tokio::test]
async fn diagnostics_reads_live_supervisor_and_path_manager() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [1; 32],
            e2e_public_key: [2; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut path_manager =
        crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    path_manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("ready path");
    state.peer_path_managers.write().await.insert(
        "peer-a".into(),
        Arc::new(std::sync::Mutex::new(path_manager)),
    );

    emit_peer_diagnostics(&state, "peer-a".into())
        .await
        .expect("diagnostics");
    let Some(network_protocol::network_event::Payload::PeerDiagnostics(diagnostics)) =
        receiver.try_recv().expect("diagnostics event").payload
    else {
        panic!("expected PeerDiagnostics");
    };
    assert_eq!(
        diagnostics.state,
        network_protocol::PeerState::Online as i32
    );
    assert_eq!(diagnostics.ready_path_count, 1);
    assert_eq!(
        diagnostics.e2ee_policy,
        network_protocol::E2eePolicy::Required as i32
    );
}

#[test]
fn command_peer_scope_mapping_covers_peer_and_runtime_commands() {
    let peer = "peer-a".to_string();
    let config = network_protocol::PeerConfig {
        peer_id: peer.clone(),
        ..Default::default()
    };
    let payloads = vec![
        network_command::Payload::ConnectPeer(network_protocol::ConnectPeerCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SendFile(network_protocol::SendFileCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::ConfigureRuntime(Default::default()),
        network_command::Payload::UpsertPeer(network_protocol::UpsertPeerCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::RespondIncomingTransfer(Default::default()),
        network_command::Payload::ConfigureRelay(Default::default()),
        network_command::Payload::DisconnectPeer(network_protocol::DisconnectPeerCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::DisconnectRelay(Default::default()),
        network_command::Payload::StartRealtimeSession(
            network_protocol::StartRealtimeSessionCommand {
                peer_id: peer.clone(),
                ..Default::default()
            },
        ),
        network_command::Payload::StopRealtimeSession(Default::default()),
        network_command::Payload::SendRealtimeSignal(network_protocol::SendRealtimeSignalCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::UpsertPeerV2(network_protocol::UpsertPeerV2Command {
            config: Some(config),
        }),
        network_command::Payload::RemovePeer(network_protocol::RemovePeerCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::SendMessageV2(network_protocol::SendMessageV2Command {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::Transfer(network_protocol::TransferCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::PeerDiagnostics(network_protocol::PeerDiagnosticsCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::NetworkEnvironmentChanged(Default::default()),
        network_command::Payload::CancelTransfer(Default::default()),
        network_command::Payload::SendMessage(network_protocol::SendMessageCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::AcknowledgeMessage(network_protocol::AcknowledgeMessageCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamOpen(network_protocol::SshStreamOpenCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamData(network_protocol::SshStreamDataCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamClose(network_protocol::SshStreamCloseCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
    ];
    for payload in payloads {
        let expected = match &payload {
            network_command::Payload::ConfigureRuntime(_)
            | network_command::Payload::RespondIncomingTransfer(_)
            | network_command::Payload::ConfigureRelay(_)
            | network_command::Payload::DisconnectRelay(_)
            | network_command::Payload::StopRealtimeSession(_)
            | network_command::Payload::NetworkEnvironmentChanged(_)
            | network_command::Payload::CancelTransfer(_) => None,
            network_command::Payload::UpsertPeerV2(command) => {
                Some(peer.clone()).filter(|_| command.config.is_some())
            }
            _ => Some(peer.clone()),
        };
        assert_eq!(
            command_peer_id(&NetworkCommand {
                command_id: "scope".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(payload),
            }),
            expected
        );
    }
    assert_eq!(command_peer_id(&NetworkCommand::default()), None);
}

#[test]
fn public_error_mapping_and_wire_class_defaults_are_stable() {
    let cases = [
        (CoreNetworkError::MailboxFull, NetworkErrorCode::IoError),
        (
            CoreNetworkError::ResourceLimit("ledger"),
            NetworkErrorCode::IoError,
        ),
        (
            CoreNetworkError::SupervisorStopping,
            NetworkErrorCode::Cancelled,
        ),
        (CoreNetworkError::Cancelled, NetworkErrorCode::Cancelled),
        (CoreNetworkError::NoRoute, NetworkErrorCode::NoRoute),
        (
            CoreNetworkError::InvalidPeerId,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            CoreNetworkError::InvalidCommandId,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            CoreNetworkError::DuplicateCommand,
            NetworkErrorCode::InvalidArgument,
        ),
        (CoreNetworkError::StaleAttempt, NetworkErrorCode::Cancelled),
        (CoreNetworkError::StaleIntent, NetworkErrorCode::Cancelled),
        (
            CoreNetworkError::CapabilityUnavailable,
            NetworkErrorCode::NoRoute,
        ),
    ];
    for (error, code) in cases {
        assert_eq!(core_error("peer-a", "test", error).code, code as i32);
    }
    assert_eq!(
        decode_communication_class(0),
        CommunicationClass::ReliableMessage
    );
    assert_eq!(
        decode_communication_class(99),
        CommunicationClass::ReliableMessage
    );
    assert_eq!(
        decode_communication_class(CommunicationClass::BulkTransfer as i32),
        CommunicationClass::BulkTransfer
    );
    assert!(validate_e2ee_policy(network_protocol::E2eePolicy::Required as i32).is_ok());
    assert!(validate_e2ee_policy(99).is_err());
}

#[tokio::test]
async fn command_envelope_and_route_validation_fail_closed() {
    let state = Arc::new(RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let invalid_version = dispatch_command(
        NetworkCommand {
            command_id: "version".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION - 1,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("old protocol version must be rejected");
    assert_eq!(
        invalid_version.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let empty_id = dispatch_command(
        NetworkCommand {
            command_id: String::new(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("empty command id must be rejected");
    assert_eq!(empty_id.code, NetworkErrorCode::InvalidArgument as i32);

    let no_payload = dispatch_command(
        NetworkCommand {
            command_id: "payload".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("missing command payload must be rejected");
    assert!(no_payload.message.contains("payload"));

    let transfer = dispatch_command(
        NetworkCommand {
            command_id: "transfer".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::Transfer(
                network_protocol::TransferCommand {
                    peer_id: String::new(),
                    transfer_id: String::new(),
                    ..Default::default()
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("transfer identity must be required");
    assert_eq!(transfer.code, NetworkErrorCode::InvalidArgument as i32);

    let peer_v2 = dispatch_command(
        NetworkCommand {
            command_id: "peer-v2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeerV2(
                network_protocol::UpsertPeerV2Command { config: None },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("peer config must be present");
    assert_eq!(peer_v2.code, NetworkErrorCode::InvalidArgument as i32);

    let bad_remove = remove_peer_v2(&state, String::new())
        .await
        .expect_err("empty peer id must be rejected");
    assert_eq!(bad_remove.code, NetworkErrorCode::InvalidArgument as i32);
    let bad_diagnostics = emit_peer_diagnostics(&state, String::new())
        .await
        .expect_err("empty diagnostics peer id must be rejected");
    assert_eq!(
        bad_diagnostics.code,
        NetworkErrorCode::InvalidArgument as i32
    );
}

#[tokio::test]
async fn relay_command_validation_checks_runtime_identity_and_credentials() {
    let state = Arc::new(RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let missing_identity = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand::default(),
    )
    .await
    .expect_err("Relay requires configured runtime identity");
    assert_eq!(
        missing_identity.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let bad_seed = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 31],
        },
    )
    .await
    .expect_err("Relay seed length must be exact");
    assert_eq!(bad_seed.code, NetworkErrorCode::InvalidArgument as i32);

    let bad_url = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "  ".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("Relay URL and credential are required");
    assert_eq!(bad_url.code, NetworkErrorCode::InvalidArgument as i32);
}
