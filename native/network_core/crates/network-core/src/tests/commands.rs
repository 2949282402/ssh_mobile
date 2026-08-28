use super::*;

use sha2::Digest;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::oneshot;

use crate::stream::{ReliableStreamManager, StreamConsumer, StreamOpener};

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

#[test]
fn command_result_ledger_claims_each_id_once() {
    let ledger = CommandResultLedger::new();
    assert_eq!(ledger.claim("command-1"), Ok(true));
    assert_eq!(ledger.claim("command-1"), Ok(false));
    ledger.complete("command-1");
    assert_eq!(ledger.claim("command-1"), Ok(false));
    assert_eq!(ledger.claim("command-2"), Ok(true));
}

#[test]
fn command_result_ledger_evicts_only_old_completed_ids() {
    let ledger = CommandResultLedger::new();
    for index in 0..=MAX_COMPLETED_COMMANDS {
        let command_id = format!("completed-{index}");
        assert_eq!(ledger.claim(&command_id), Ok(true));
        ledger.complete(&command_id);
    }

    assert_eq!(ledger.claim("completed-0"), Ok(true));
    assert_eq!(
        ledger.claim(&format!("completed-{MAX_COMPLETED_COMMANDS}")),
        Ok(false)
    );
}

#[tokio::test]
async fn command_worker_emits_a_terminal_error_for_duplicate_envelopes() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let (command_tx, command_rx) = tokio::sync::mpsc::channel(2);
    let worker = tokio::spawn(run_command_worker(command_rx, Arc::clone(&state)));

    for _ in 0..2 {
        command_tx
            .send(NetworkCommand {
                command_id: "duplicate-envelope".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .await
            .expect("command worker is alive");
    }
    drop(command_tx);
    worker.await.expect("command worker joins");

    let mut results = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        if let Some(network_protocol::network_event::Payload::CommandResultV2(result)) =
            event.payload
        {
            results.push(result);
        }
    }
    assert_eq!(results.len(), 2);
    assert!(results
        .iter()
        .all(|result| result.command_id == "duplicate-envelope"));
    assert!(results.iter().any(|result| {
        result
            .error
            .as_ref()
            .is_some_and(|error| error.message.contains("already been completed"))
    }));
}

#[tokio::test]
async fn command_worker_continues_beyond_completed_history_capacity() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let (command_tx, command_rx) = tokio::sync::mpsc::channel(8);
    let worker = tokio::spawn(run_command_worker(command_rx, Arc::clone(&state)));

    const COMMAND_COUNT: usize = 5000;
    for index in 0..COMMAND_COUNT {
        command_tx
            .send(NetworkCommand {
                command_id: format!("ledger-bound-{index}"),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .await
            .expect("command worker is alive");
    }
    drop(command_tx);
    worker.await.expect("command worker joins");

    let mut results = 0usize;
    while let Ok(event) = event_rx.try_recv() {
        let Some(network_protocol::network_event::Payload::CommandResultV2(result)) = event.payload
        else {
            continue;
        };
        results += 1;
        assert!(!result.error.as_ref().is_some_and(|error| {
            error.message.contains("command result ledger")
                || error.message.contains("pending command results")
        }));
    }
    assert_eq!(results, COMMAND_COUNT);
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
async fn connect_command_rejects_missing_runtime_and_unknown_peer_before_attempt() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let not_configured = start_connect_peer(
        Arc::clone(&state),
        "connect-unconfigured".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    )
    .await
    .expect_err("connect must require runtime identity and endpoint");
    assert_eq!(
        not_configured.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("endpoint");
    *state.lifecycle.endpoint.write().await = Some(endpoint.endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let unknown_peer = start_connect_peer(
        state,
        "connect-unknown-peer".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    )
    .await
    .expect_err("connect must require a configured peer");
    assert_eq!(unknown_peer.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn connect_command_maps_unsuccessful_attempt_cancellation_to_io_error() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("endpoint");
    *state.lifecycle.endpoint.write().await = Some(endpoint.endpoint);
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    state.peers.write().await.insert(
        "peer-a".into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [3; 32],
            e2e_public_key: [4; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    let supervisor = state
        .peer_supervisors
        .get_or_create_with_configured("peer-a", true)
        .expect("supervisor");

    let connect = tokio::spawn(start_connect_peer(
        Arc::clone(&state),
        "connect-cancelled".into(),
        "peer-a".into(),
        CommunicationClass::ReliableMessage,
    ));
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.task_supervisor.active_count() > 0 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("connect command should start a supervised task");
    state.task_supervisor.cancel_root();
    supervisor.stop();

    let error = tokio::time::timeout(Duration::from_secs(1), connect)
        .await
        .expect("cancelled connect should complete")
        .expect("connect task should join")
        .expect_err("cancelled connect must return an error");
    state.task_supervisor.shutdown().await;
    assert_eq!(error.code, NetworkErrorCode::IoError as i32);
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
async fn environment_change_retires_an_unmaintained_direct_owner() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
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
        .get_or_create_with_configured("peer-a", false)
        .expect("supervisor");
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 7,
            has_connectivity: false,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert_eq!(supervisor.state(), PeerState::Offline);
}

#[tokio::test]
async fn environment_change_preserves_relay_and_retires_only_direct_path() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
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
        .peer_supervisors
        .get_or_create_with_configured("peer-a", false)
        .expect("supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    manager
        .publish_ready_with_route(crate::connect::ActiveRoute::relay(None))
        .expect("relay path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 8,
            has_connectivity: false,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert!(state.has_ready_relay_path("peer-a").await);
}

#[tokio::test]
async fn environment_change_restarts_a_maintained_direct_supervisor() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
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
    let intent = supervisor
        .begin_connect("maintenance-seed", CommunicationClass::ReliableMessage)
        .expect("maintenance intent");
    intent.detach_completion();
    supervisor.admit_inbound(true).expect("online supervisor");

    let peer = PeerId::new("peer-a").expect("valid peer");
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&state.ready_paths));
    manager
        .publish_ready(
            crate::connection::ConnectionProfile::for_route(
                network_protocol::RouteType::QuicDirect,
            )
            .expect("direct profile"),
        )
        .expect("direct path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(std::sync::Mutex::new(manager)));

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 9,
            has_connectivity: true,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("maintained environment transition");

    assert!(!state.has_ready_direct_path("peer-a").await);
    assert!(supervisor.maintain_connection());
    assert!(matches!(
        supervisor.state(),
        PeerState::Offline | PeerState::Connecting
    ));
    state.task_supervisor.cancel_root();
    supervisor.stop();
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn environment_change_starts_relay_backed_direct_recovery() {
    let (sender, _receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        sender,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
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
    let intent = supervisor
        .begin_connect("maintenance-seed", CommunicationClass::ReliableMessage)
        .expect("maintenance intent");
    intent.detach_completion();
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending session");
    assert!(
        state
            .mark_relay_route_connected("peer-a", session_id, None)
            .await
    );

    handle_network_environment_changed(
        &state,
        &network_protocol::NetworkEnvironmentChangedCommand {
            generation: 10,
            has_connectivity: true,
            is_foreground: true,
            is_metered: false,
        },
    )
    .await
    .expect("relay-backed environment transition");

    let probe_started = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            let started = state
                .peer_path_managers
                .read()
                .await
                .get("peer-a")
                .is_some_and(|manager| {
                    manager
                        .lock()
                        .expect("peer path manager lock")
                        .direct_probe()
                        .is_some()
                });
            if started {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .is_ok();
    state.task_supervisor.cancel_root();
    supervisor.stop();
    state.task_supervisor.shutdown().await;
    assert!(probe_started, "environment change must arm a Direct probe");
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

    assert!(
        state
            .transfer
            .manager
            .register_outgoing(
                manifest("outgoing-transfer"),
                PathBuf::from("/tmp/outgoing-transfer.bin"),
                "peer-a".into(),
            )
            .await
    );
    state.relay.pending_incoming.write().await.insert(
        "pending-transfer".into(),
        crate::relay::PendingRelayIncoming {
            transfer_id: "pending-transfer".into(),
            session_id: "pending-session".into(),
            sender_id: "peer-a".into(),
            manifest: manifest("pending-transfer"),
            manifest_hash: "a".repeat(64),
            crypto_session_id: "crypto-session".into(),
        },
    );
    state.relay.active_incoming.lock().await.insert(
        "active-transfer".into(),
        crate::relay::ActiveRelayIncoming {
            offer: crate::relay::PendingRelayIncoming {
                transfer_id: "active-transfer".into(),
                session_id: "active-session".into(),
                sender_id: "peer-a".into(),
                manifest: manifest("active-transfer"),
                manifest_hash: "a".repeat(64),
                crypto_session_id: "crypto-session".into(),
            },
            file: None,
            temporary_path: PathBuf::from("/tmp/active-transfer.part"),
            final_path: PathBuf::from("/tmp/active-transfer.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: sha2::Sha256::new(),
            already_completed: false,
        },
    );
    let stream_manager = ReliableStreamManager::new(state.event_tx.clone());
    stream_manager
        .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
        .await
        .expect("stream owned by the peer");
    state
        .reliable_streams
        .write()
        .await
        .insert("peer-a".into(), stream_manager);
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending peer session");
    let (acceptance_tx, _acceptance_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("outgoing-transfer".into(), acceptance_tx);
    let (completion_tx, _completion_rx) = oneshot::channel();
    state
        .relay
        .completions
        .write()
        .await
        .insert("outgoing-transfer".into(), completion_tx);

    remove_peer_v2(&state, "peer-a".into())
        .await
        .expect("remove peer");

    assert!(!state.peers.read().await.contains_key("peer-a"));
    assert!(!state.trusted_peer_keys.read().await.contains_key("peer-a"));
    assert!(!state
        .peer_supervisors
        .remove_if_evictable("peer-a")
        .expect("removed peer supervisor lookup"));
    assert!(state
        .transfer
        .manager
        .snapshot("outgoing-transfer")
        .await
        .is_none());
    assert!(state.relay.pending_incoming.read().await.is_empty());
    assert!(state.relay.active_incoming.lock().await.is_empty());
    assert!(state.relay.acceptances.read().await.is_empty());
    assert!(state.relay.completions.read().await.is_empty());
    assert!(state.reliable_streams.read().await.get("peer-a").is_none());
    assert!(state
        .connection_sessions
        .current_session_id("peer-a")
        .await
        .is_none());
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
    let stream_manager = ReliableStreamManager::new(state.event_tx.clone());
    stream_manager
        .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
        .await
        .expect("stream owned by the peer");
    state
        .reliable_streams
        .write()
        .await
        .insert("peer-a".into(), stream_manager);
    assert!(
        state
            .transfer
            .manager
            .register_outgoing(
                manifest("diagnostic-transfer"),
                PathBuf::from("/tmp/diagnostic-transfer.bin"),
                "peer-a".into(),
            )
            .await
    );
    let (acceptance_tx, _acceptance_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("diagnostic-transfer".into(), acceptance_tx);
    let (completion_tx, _completion_rx) = oneshot::channel();
    state
        .relay
        .completions
        .write()
        .await
        .insert("diagnostic-transfer".into(), completion_tx);

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
    assert_eq!(diagnostics.active_stream_count, 1);
    assert_eq!(diagnostics.active_transfer_count, 1);
    assert_eq!(
        diagnostics.e2ee_policy,
        network_protocol::E2eePolicy::Required as i32
    );
}

#[tokio::test]
async fn diagnostics_for_unconfigured_peer_reports_offline_defaults() {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let state = RuntimeState::new(sender, Arc::new(std::sync::atomic::AtomicU16::new(0)));

    emit_peer_diagnostics(&state, "unconfigured-peer".into())
        .await
        .expect("diagnostics for an unknown peer");
    let Some(network_protocol::network_event::Payload::PeerDiagnostics(diagnostics)) =
        receiver.try_recv().expect("diagnostics event").payload
    else {
        panic!("expected PeerDiagnostics");
    };
    assert_eq!(diagnostics.peer_id, "unconfigured-peer");
    assert_eq!(
        diagnostics.state,
        network_protocol::PeerState::Offline as i32
    );
    assert_eq!(
        diagnostics.e2ee_policy,
        network_protocol::E2eePolicy::Required as i32
    );
    assert_eq!(diagnostics.ready_path_count, 0);
    assert_eq!(diagnostics.queued_command_count, 0);
    assert_eq!(diagnostics.active_stream_count, 0);
    assert_eq!(diagnostics.active_transfer_count, 0);
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
                command.config.as_ref().map(|_| peer.clone())
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

    let oversized_id = dispatch_command(
        NetworkCommand {
            command_id: "x".repeat(129),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("oversized command id must be rejected");
    assert_eq!(oversized_id.code, NetworkErrorCode::InvalidArgument as i32);

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

    let valid_transfer = dispatch_command(
        NetworkCommand {
            command_id: "valid-transfer".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::Transfer(
                network_protocol::TransferCommand {
                    peer_id: "peer-a".into(),
                    transfer_id: "transfer-a".into(),
                    file_path: "/path/that/does/not/exist".into(),
                    ..Default::default()
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("valid transfer identity still validates its source");
    assert_eq!(valid_transfer.code, NetworkErrorCode::IoError as i32);

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

    let unknown_policy = dispatch_command(
        NetworkCommand {
            command_id: "unknown-policy".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeerV2(
                network_protocol::UpsertPeerV2Command {
                    config: Some(network_protocol::PeerConfig {
                        peer_id: "peer-a".into(),
                        e2ee_policy: 99,
                        ..Default::default()
                    }),
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("unknown E2EE policy must be rejected");
    assert_eq!(
        unknown_policy.code,
        NetworkErrorCode::InvalidArgument as i32
    );

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

    state.task_supervisor.shutdown().await;
    let stopping = start_configure_relay(
        state,
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("Relay configure must reject a stopping runtime");
    assert_eq!(stopping.code, NetworkErrorCode::Cancelled as i32);
}

#[tokio::test]
async fn relay_command_reports_async_control_connect_failure() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));

    start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect("valid Relay command should queue its async task");

    let mut saw_connecting = false;
    let mut saw_failed = false;
    let mut saw_connected = false;
    tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(event) = event_rx.recv().await {
            let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
                event.payload
            else {
                continue;
            };
            match network_protocol::RelayConnectionState::try_from(change.state) {
                Ok(network_protocol::RelayConnectionState::Connecting) => saw_connecting = true,
                Ok(network_protocol::RelayConnectionState::Failed) => {
                    saw_failed = true;
                    break;
                }
                Ok(network_protocol::RelayConnectionState::Connected) => saw_connected = true,
                _ => {}
            }
        }
    })
    .await
    .expect("Relay failure event should arrive");
    state.task_supervisor.shutdown().await;
    assert!(saw_connecting);
    assert!(saw_failed);
    assert!(!saw_connected, "failed Relay setup must not emit Connected");
}

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
