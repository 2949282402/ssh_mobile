use super::*;
use crate::connect::{CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_RELIABLE_STREAM};
use crate::connection::{Route, RouteTransport};

fn test_peer() -> PeerId {
    PeerId::new("peer-a").expect("peer id")
}

fn profile(topology: PathKind, transport: RouteTransport) -> ConnectionProfile {
    let route = match topology {
        PathKind::Direct => Route::direct(transport),
        PathKind::Relay => Route::relay(transport),
    };
    ConnectionProfile::new(route)
}

fn recording_carrier(closes: &Arc<Mutex<Vec<PathCloseReason>>>) -> Box<dyn PathCarrier> {
    let closes = Arc::clone(closes);
    callback_path_carrier(move |reason| {
        closes.lock().expect("close log lock").push(reason);
    })
}

#[test]
fn physical_path_is_sole_carrier_owner() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let copied_handle = handle.clone();
    let lease = registry.acquire(&copied_handle).expect("path lease");

    assert_eq!(lease.handle(), &handle);
    assert_eq!(lease.lease_count(), 1);
    assert!(lease.path.has_carrier());
    assert!(registry.acquire(&handle).is_ok());

    manager.normal_drain();
    assert!(lease.is_active(), "normal drain waits for existing leases");
    assert!(closes.lock().expect("close log lock").is_empty());
    assert!(matches!(
        registry.acquire(&handle),
        Err(CoreNetworkError::StaleAttempt)
    ));

    lease.release();
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[test]
fn path_projection_is_non_owning_and_upgrades_only_to_a_lease() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let projection = manager.projection(&handle).expect("path projection");

    assert_eq!(projection.handle(), &handle);
    assert!(projection.is_alive());
    let lease = projection.acquire().expect("lease from projection");
    manager.normal_drain();
    assert!(
        projection.is_alive(),
        "active lease keeps the carrier alive"
    );
    drop(lease);
    assert!(
        !projection.is_alive(),
        "weak projection cannot keep the path alive"
    );
    assert!(matches!(
        projection.acquire(),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[tokio::test]
async fn path_lease_exposes_owner_io_without_a_route_owner_clone() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_route(ActiveRoute::relay(None))
        .expect("relay path");
    let projection = manager.projection(&handle).expect("path projection");
    let lease = projection.acquire().expect("path lease");

    assert!(lease.connection().is_none());
    assert!(matches!(
        lease.stream_carrier(),
        Some(StreamCarrier::Relay(None))
    ));
    assert!(lease.relay_data().is_none());
    assert!(lease
        .send_channel_frame("", GenericFrameKind::DataMessage, b"payload")
        .await
        .is_err());
}

#[test]
fn direct_and_relay_can_coexist() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let relay = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay path");
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Quic))
        .expect("direct path");

    assert_eq!(manager.direct_state(), DirectPathState::Ready);
    assert_eq!(manager.relay_state(), RelayPathState::Ready);
    assert_eq!(manager.direct_ready(), std::slice::from_ref(&direct));
    assert_eq!(manager.relay_ready(), Some(&relay));
    assert_eq!(
        manager.select(CAPABILITY_RELIABLE_MESSAGE),
        Some(PathSelection::Direct)
    );

    let (selection, direct_lease) = manager
        .acquire(CAPABILITY_RELIABLE_STREAM)
        .expect("direct stream lease");
    assert_eq!(selection, PathSelection::Direct);
    assert_eq!(direct_lease.handle(), &direct);
    drop(direct_lease);
    assert!(registry.acquire(&relay).is_ok());
}

#[test]
fn ready_direct_and_probe_can_coexist() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::WebSocket))
        .expect("direct path");

    manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("direct probe");
    assert_eq!(manager.direct_state(), DirectPathState::Ready);
    assert!(manager.direct_probe().is_some());
    assert_eq!(
        manager.select(CAPABILITY_RELIABLE_MESSAGE),
        Some(PathSelection::Direct)
    );

    let (selection, lease) = manager
        .acquire(CAPABILITY_RELIABLE_MESSAGE)
        .expect("ready direct remains usable during probe");
    assert_eq!(selection, PathSelection::Direct);
    assert_eq!(lease.handle(), &direct);
    drop(lease);
    assert!(manager.finish_direct_probe(7));
    assert_eq!(manager.direct_state(), DirectPathState::Ready);
}

#[test]
fn normal_retire_waits_for_active_lease() {
    let registry = Arc::new(PathRegistry::new());
    let direct_closes = Arc::new(Mutex::new(Vec::new()));
    let relay_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&direct_closes),
        )
        .expect("direct path");
    let relay = manager
        .publish_ready_with_carrier(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&relay_closes),
        )
        .expect("relay path");
    let direct_lease = registry.acquire(&direct).expect("direct lease");

    manager.normal_drain();
    assert_eq!(manager.direct_state(), DirectPathState::None);
    assert_eq!(manager.relay_state(), RelayPathState::None);
    assert!(direct_lease.is_active());
    assert!(direct_closes.lock().expect("close log lock").is_empty());
    assert_eq!(
        relay_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
    assert!(matches!(
        registry.acquire(&relay),
        Err(CoreNetworkError::StaleAttempt)
    ));

    drop(direct_lease);
    assert_eq!(
        direct_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[test]
fn hard_close_revokes_active_lease() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let lease = registry.acquire(&handle).expect("lease");

    manager.security_failure();
    assert!(!lease.is_active());
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::SecurityFailure]
    );
    assert!(matches!(
        registry.acquire(&handle),
        Err(CoreNetworkError::StaleAttempt)
    ));
    drop(lease);

    let second_closes = Arc::new(Mutex::new(Vec::new()));
    let mut second_manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let second = second_manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&second_closes),
        )
        .expect("second direct path");
    let second_lease = registry.acquire(&second).expect("second lease");
    second_manager.hard_close();
    assert!(!second_lease.is_active());
    assert_eq!(
        second_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );

    let drained_closes = Arc::new(Mutex::new(Vec::new()));
    let mut drained_manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let drained = drained_manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&drained_closes),
        )
        .expect("draining path");
    let drained_lease = registry.acquire(&drained).expect("draining lease");
    drained_manager.normal_drain();
    assert!(drained_lease.is_active());
    drained_manager.hard_close();
    assert!(!drained_lease.is_active());
    assert_eq!(
        drained_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );
}

#[test]
fn ephemeral_paths_retire_after_sixty_seconds_without_sleeping() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let now = Instant::now();
    let handle = manager
        .publish_ready_with_carrier_at(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
            now - super::super::EPHEMERAL_PATH_IDLE_TIMEOUT - Duration::from_secs(1),
        )
        .expect("ephemeral direct path");

    assert!(manager.ephemeral_idle(now));
    assert_eq!(manager.retire_ephemeral(now), 1);
    assert!(matches!(
        registry.acquire(&handle),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[test]
fn registry_peer_revoke_hard_closes_manager_owned_paths() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&closes),
        )
        .expect("relay path");
    let lease = registry.acquire(&handle).expect("lease");

    assert_eq!(registry.revoke_peer(&test_peer()), 1);
    assert!(!lease.is_active());
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );
    assert_eq!(manager.relay_state(), RelayPathState::None);
}

#[test]
fn registry_selection_skips_incompatible_paths_and_prefers_direct() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct_message = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::WebSocket))
        .expect("message-only path");
    let relay = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay stream fallback");

    let relay_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_STREAM)
        .expect("relay stream path");
    assert_eq!(relay_lease.handle(), &relay);
    assert_ne!(relay_lease.handle(), &direct_message);
    drop(relay_lease);

    manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("stream demand");
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Quic))
        .expect("quic path");
    let direct_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_STREAM)
        .expect("direct stream path");
    assert_eq!(direct_lease.handle(), &direct);
    assert_eq!(direct_lease.profile().transport(), RouteTransport::Quic);
    drop(direct_lease);

    let message_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_MESSAGE)
        .expect("direct message path");
    assert_eq!(message_lease.profile().topology(), RouteTopology::Direct);
    drop(message_lease);
}

#[test]
fn equivalent_late_direct_loses() {
    let registry = Arc::new(PathRegistry::new());
    let first_closes = Arc::new(Mutex::new(Vec::new()));
    let late_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let first = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&first_closes),
        )
        .expect("first direct path");

    let result = manager.publish_ready_with_carrier(
        profile(PathKind::Direct, RouteTransport::Tcp),
        recording_carrier(&late_closes),
    );

    assert_eq!(result, Err(CoreNetworkError::StaleAttempt));
    assert_eq!(manager.direct_ready(), std::slice::from_ref(&first));
    assert!(first_closes.lock().expect("first close log").is_empty());
    assert_eq!(
        late_closes.lock().expect("late close log").as_slice(),
        &[PathCloseReason::HardClose]
    );
    assert!(registry.acquire(&first).is_ok());
}

#[test]
fn weaker_late_direct_loses() {
    let registry = Arc::new(PathRegistry::new());
    let first_closes = Arc::new(Mutex::new(Vec::new()));
    let late_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let first = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&first_closes),
        )
        .expect("first direct stream path");

    let result = manager.publish_ready_with_carrier(
        profile(PathKind::Direct, RouteTransport::WebSocket),
        recording_carrier(&late_closes),
    );

    assert_eq!(result, Err(CoreNetworkError::StaleAttempt));
    assert_eq!(manager.direct_ready(), std::slice::from_ref(&first));
    assert!(first_closes.lock().expect("first close log").is_empty());
    assert_eq!(
        late_closes.lock().expect("late close log").as_slice(),
        &[PathCloseReason::HardClose]
    );
}

#[test]
fn needed_strict_superset_can_promote() {
    let registry = Arc::new(PathRegistry::new());
    let old_closes = Arc::new(Mutex::new(Vec::new()));
    let new_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let old = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::WebSocket),
            recording_carrier(&old_closes),
        )
        .expect("message-only direct path");
    manager
        .ensure_direct_probe(8, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("stream demand");

    let promoted = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&new_closes),
        )
        .expect("needed stream-capable direct path");

    assert_ne!(promoted, old);
    assert_eq!(manager.direct_ready(), std::slice::from_ref(&promoted));
    assert!(manager.direct_probe().is_none());
    assert_eq!(
        old_closes.lock().expect("old close log").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
    assert!(new_closes.lock().expect("new close log").is_empty());
    assert!(matches!(
        registry.acquire(&old),
        Err(CoreNetworkError::StaleAttempt)
    ));
}
