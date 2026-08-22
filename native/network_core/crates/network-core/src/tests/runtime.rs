//! RuntimeState/NetworkRuntime boundary tests kept outside the implementation module.

use super::*;
use crate::connect::{
    PeerId, PeerPathManager, CAPABILITY_RELIABLE_STREAM, CAPABILITY_UNRELIABLE_DATAGRAM,
};
use crate::connection::{ConnectionProfile, Route, RouteTransport};
use std::sync::atomic::AtomicU16;
use tokio::sync::mpsc;

#[tokio::test]
async fn runtime_path_projection_is_non_owning() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let peer_id = "projection-peer";
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register session");

    let mut manager = PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    let handle = manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("publish path");
    let projection = manager.projection(&handle).expect("projection");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), Arc::new(Mutex::new(manager)));
    state.path_projections.write().await.insert(
        peer_id.to_string(),
        vec![OwnedPathProjection {
            session_id,
            projection: projection.clone(),
        }],
    );

    assert!(state.path_is_connected(peer_id).await);
    state.peer_path_managers.write().await.remove(peer_id);
    assert!(
        !projection.is_alive(),
        "projection must not own the carrier"
    );
}

#[tokio::test]
async fn stale_session_failure_does_not_close_replacement_path() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let peer_id = "stale-session-peer";
    let old_session = SessionId::new();
    let replacement_session = SessionId::new();

    state
        .connection_sessions
        .register_pending_session(peer_id, old_session)
        .await
        .expect("register old session");
    // Model the replacement admission winning before the stale
    // coordinator reports its failure.  Retiring the old admission alone
    // must not tear down the physical path.
    assert!(
        state
            .connection_sessions
            .retire_session(peer_id, old_session)
            .await
    );
    state
        .connection_sessions
        .register_pending_session(peer_id, replacement_session)
        .await
        .expect("register replacement session");

    let mut manager = PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("publish old path");
    manager
        .ensure_direct_probe(1, CAPABILITY_UNRELIABLE_DATAGRAM, Duration::from_secs(1))
        .expect("arm replacement probe");
    let replacement_handle = manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Quic)))
        .expect("publish replacement path");
    let replacement_projection = manager
        .projection(&replacement_handle)
        .expect("replacement projection");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), Arc::new(Mutex::new(manager)));
    state.path_projections.write().await.insert(
        peer_id.to_string(),
        vec![OwnedPathProjection {
            session_id: replacement_session,
            projection: replacement_projection,
        }],
    );

    assert!(state.path_is_connected(peer_id).await);
    state.fail_session(peer_id, old_session).await;

    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(replacement_session)
    );
    assert_eq!(
        state.path_profile(peer_id).await,
        Some(ConnectionProfile::new(Route::direct(RouteTransport::Quic)))
    );
    assert!(state.path_is_connected(peer_id).await);

    state.close_transport_path(peer_id).await;
}

#[tokio::test]
async fn authenticated_session_rejects_an_incompatible_connected_path() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let peer_id = "capability-peer";
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register session");
    state
        .connection_sessions
        .admit_authenticated_session(peer_id, Some(session_id), "remote-binding")
        .await
        .expect("admit session");
    state
        .connection_sessions
        .finalize_authenticated_session(peer_id, session_id, "remote-binding")
        .await
        .expect("finalize session");

    let mut manager = PeerPathManager::new(
        PeerId::new(peer_id).expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("publish TCP path");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.to_string(), Arc::new(Mutex::new(manager)));

    assert_eq!(
        state
            .begin_connect(peer_id, crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM)
            .await,
        ConnectDecision::CapabilityMismatch(session_id)
    );
    assert_eq!(
        state
            .begin_connect(peer_id, crate::connect::CAPABILITY_RELIABLE_STREAM)
            .await,
        ConnectDecision::AlreadyConnected(session_id)
    );
}

fn control_event() -> NetworkEvent {
    NetworkEvent {
        payload: Some(network_event::Payload::PeerState(
            network_protocol::PeerStateChangedEvent::default(),
        )),
        ..Default::default()
    }
}

fn data_event() -> NetworkEvent {
    NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            network_protocol::ChannelMessageEvent {
                payload: vec![1, 2, 3],
                ..Default::default()
            },
        )),
        ..Default::default()
    }
}

#[tokio::test]
async fn bounded_event_lanes_release_bytes_and_prefer_data_after_control_burst() {
    let (sender, mut receiver) = bounded_event_channel();
    let control = control_event();
    let data = data_event();

    for _ in 0..MAX_CONSECUTIVE_CONTROL_EVENTS {
        sender.send(control.clone()).expect("control event");
    }
    sender.send(data.clone()).expect("data event");
    assert_eq!(
        receiver.control_queued_bytes.load(Ordering::Acquire),
        control.encoded_len() * MAX_CONSECUTIVE_CONTROL_EVENTS
    );
    assert_eq!(
        receiver.data_queued_bytes.load(Ordering::Acquire),
        data.encoded_len()
    );

    for _ in 0..MAX_CONSECUTIVE_CONTROL_EVENTS {
        assert!(matches!(
            receiver.try_recv().and_then(|event| event.payload),
            Some(network_event::Payload::PeerState(_))
        ));
    }
    assert!(matches!(
        receiver.try_recv().and_then(|event| event.payload),
        Some(network_event::Payload::ChannelMessage(_))
    ));
    assert_eq!(receiver.control_queued_bytes.load(Ordering::Acquire), 0);
    assert_eq!(receiver.data_queued_bytes.load(Ordering::Acquire), 0);

    let oversized = NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            network_protocol::ChannelMessageEvent {
                payload: vec![0; MAX_EVENT_BYTES],
                ..Default::default()
            },
        )),
        ..Default::default()
    };
    assert!(sender.send(oversized).is_err());
    drop(sender);
    assert!(receiver.recv().await.is_none());
}

#[tokio::test]
async fn event_receiver_handles_each_closed_lane_without_unreachable_states() {
    let (control_sender, control_receiver) = mpsc::channel(2);
    let (data_sender, data_receiver) = mpsc::channel(2);
    let control_bytes = Arc::new(AtomicUsize::new(0));
    let data_bytes = Arc::new(AtomicUsize::new(0));
    let mut receiver = EventReceiver {
        control_receiver,
        data_receiver,
        control_queued_bytes: control_bytes,
        data_queued_bytes: data_bytes,
        consecutive_control: 0,
        control_closed: false,
        data_closed: false,
    };
    drop(control_sender);
    data_sender.send(data_event()).await.expect("data event");
    assert!(matches!(
        receiver.recv().await.and_then(|event| event.payload),
        Some(network_event::Payload::ChannelMessage(_))
    ));
    drop(data_sender);
    assert!(receiver.recv().await.is_none());
}

#[tokio::test]
async fn runtime_path_lease_lookup_is_exact_and_rejects_stale_or_missing_routes() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    assert!(matches!(
        state
            .acquire_path_lease("missing-peer", CAPABILITY_UNRELIABLE_DATAGRAM)
            .await,
        Err(CoreNetworkError::NoRoute)
    ));

    let peer_id = "generic-runtime-peer";
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register session");
    let route = crate::connection::test_blocking_generic_route();
    let route_id = route.handle.id();
    state
        .attach_test_generic_route(peer_id, session_id, route.handle.clone())
        .await
        .expect("publish generic route");

    assert!(state.has_ready_direct_path(peer_id).await);
    assert!(
        !state
            .has_ready_direct_path_for_capability(peer_id, CAPABILITY_UNRELIABLE_DATAGRAM)
            .await
    );
    assert!(
        state
            .has_ready_direct_path_for_capability(peer_id, CAPABILITY_RELIABLE_STREAM)
            .await
    );
    assert!(!state.has_ready_relay_path(peer_id).await);
    assert_eq!(state.path_route(peer_id).await, None);
    assert!(state.path_is_connected(peer_id).await);
    assert!(
        state
            .path_supports_capability(peer_id, CAPABILITY_RELIABLE_STREAM)
            .await
    );
    let lease = state
        .acquire_path_lease_for_generic_route(peer_id, route_id, CAPABILITY_RELIABLE_STREAM)
        .await
        .expect("exact generic carrier lease");
    let carrier_id = match lease.stream_carrier() {
        Some(crate::connect::StreamCarrier::GenericTest(handle)) => Some(handle.id()),
        _ => None,
    };
    assert_eq!(carrier_id, Some(route_id));
    assert!(state
        .acquire_path_lease_for_generic_route(peer_id, route_id + 1, CAPABILITY_RELIABLE_STREAM)
        .await
        .is_err());
    lease.release();

    state.close_transport_path(peer_id).await;
    state.cancel_session_tasks(peer_id, session_id).await;
    let _ = route.release.send(());
    route.worker.abort();
}

#[tokio::test]
async fn failing_an_exact_session_closes_its_owned_direct_projection() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let peer_id = "runtime-fail-session-peer";
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register session");
    let route = crate::connection::test_blocking_generic_route();
    state
        .attach_test_generic_route(peer_id, session_id, route.handle.clone())
        .await
        .expect("publish direct projection");
    assert!(state.path_is_connected(peer_id).await);

    state.fail_session(peer_id, session_id).await;

    assert!(state
        .connection_sessions
        .current_session_id(peer_id)
        .await
        .is_none());
    assert!(!state.path_is_connected(peer_id).await);
    assert!(state.peer_path_managers.read().await.get(peer_id).is_none());
    let _ = route.release.send(());
    route.worker.abort();
}

#[tokio::test]
async fn path_admission_retry_only_allows_the_current_unbound_session() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    assert!(state.path_admission_can_retry("peer-a", None).await);
    assert!(
        !state
            .path_admission_can_retry("peer-a", Some(SessionId::new()))
            .await
    );

    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending session");
    assert!(
        state
            .path_admission_can_retry("peer-a", Some(session_id))
            .await
    );
    state
        .connection_sessions
        .admit_authenticated_session("peer-a", Some(session_id), "remote-binding")
        .await
        .expect("admit session");
    assert!(
        !state
            .path_admission_can_retry("peer-a", Some(session_id))
            .await
    );
}

#[tokio::test]
async fn direct_recovery_probe_helpers_are_bounded_and_owner_scoped() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));

    state.reset_direct_recovery("peer-a");
    assert!(state.next_direct_recovery_delay("peer-a").is_none());
    assert!(
        !state
            .arm_direct_probe(
                "missing-peer",
                crate::connect::IntentGeneration::INITIAL,
                Duration::from_secs(1),
                CAPABILITY_RELIABLE_STREAM,
            )
            .await
    );

    let manager = PeerPathManager::new(
        PeerId::new("peer-a").expect("peer id"),
        Arc::clone(&state.ready_paths),
    );
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".into(), Arc::new(Mutex::new(manager)));
    assert!(
        state
            .arm_direct_probe(
                "peer-a",
                crate::connect::IntentGeneration::INITIAL,
                Duration::from_secs(1),
                CAPABILITY_RELIABLE_STREAM,
            )
            .await
    );
    assert!(
        !state
            .arm_direct_probe(
                "peer-a",
                crate::connect::IntentGeneration::INITIAL,
                Duration::from_secs(1),
                CAPABILITY_RELIABLE_STREAM,
            )
            .await
    );
    state
        .finish_direct_probe("peer-a", crate::connect::IntentGeneration::INITIAL)
        .await;
    state
        .finish_direct_probe("missing-peer", crate::connect::IntentGeneration::INITIAL)
        .await;
}

#[tokio::test]
async fn stale_session_retirement_is_idempotent_and_path_wait_is_bounded() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let session_id = SessionId::new();
    state
        .connection_sessions
        .register_pending_session("peer-a", session_id)
        .await
        .expect("pending session");

    assert!(
        state
            .retire_session_without_transport("peer-a", session_id)
            .await
    );
    assert!(
        !state
            .retire_session_without_transport("peer-a", session_id)
            .await
    );
    tokio::time::timeout(Duration::from_secs(1), state.wait_for_path_change())
        .await
        .expect("path wait must remain bounded");
}

#[tokio::test]
async fn relay_data_path_lease_requires_the_current_client_identity() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
    let peer_id = "relay-lease-peer";
    let session_id = match state
        .begin_connect(peer_id, crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    let data = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid Relay data client"),
    );
    assert!(
        state
            .mark_relay_route_connected(peer_id, session_id, Some(Arc::clone(&data)))
            .await
    );

    let lease = state
        .acquire_path_lease_for_relay_data(peer_id, &data, CAPABILITY_RELIABLE_STREAM)
        .await
        .expect("current Relay data client should be leaseable");
    assert!(lease
        .relay_data()
        .is_some_and(|current| Arc::ptr_eq(&current, &data)));
    assert!(state.path_is_current_relay_data(peer_id, &data).await);

    let stale = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid stale Relay data client"),
    );
    assert!(state
        .acquire_path_lease_for_relay_data(peer_id, &stale, CAPABILITY_RELIABLE_STREAM)
        .await
        .is_err());
    assert!(!state.path_is_current_relay_data(peer_id, &stale).await);
    lease.release();
    state.close_transport_path(peer_id).await;
}

#[test]
fn runtime_lifecycle_rejects_commands_before_start_and_stops_idempotently() {
    let runtime = NetworkRuntime::new().expect("runtime");
    assert!(matches!(
        runtime.send_command(NetworkCommand::default()),
        Err(NetworkError::RuntimeNotRunning)
    ));
    runtime.start().expect("start runtime");
    assert!(matches!(
        runtime.start(),
        Err(NetworkError::RuntimeNotRunning)
    ));
    assert!(runtime
        .send_command(NetworkCommand {
            command_id: "runtime-test".into(),
            protocol_version: 2,
            payload: None,
        })
        .is_ok());
    runtime.emit_event(control_event());
    assert!(runtime.poll_event(0).is_some());
    // The command worker may publish a typed protocol error for the
    // intentionally empty command payload; the polling boundary itself
    // must remain non-panicking regardless of that asynchronous event.
    let _ = runtime.poll_event(1);
    runtime.stop().expect("stop runtime");
    assert!(runtime.stop().is_ok());

    let never_started = NetworkRuntime::new().expect("runtime");
    assert!(never_started.stop().is_ok());
    assert!(never_started.stop().is_ok());
}

#[test]
fn dropping_a_running_runtime_releases_its_supervised_state() {
    let runtime = NetworkRuntime::new().expect("runtime");
    runtime.start().expect("start runtime");
    drop(runtime);
}
