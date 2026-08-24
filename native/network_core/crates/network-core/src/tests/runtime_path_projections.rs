//! Runtime path-projection store tests kept outside the production module.

use super::*;
use crate::connect::{ActiveRoute, PathRegistry, PeerId, PeerPathManager};
use crate::connection::{ConnectionProfile, Route, RouteTransport};
use std::sync::Arc;

#[tokio::test]
async fn owns_topology_replacement_and_exact_session_cleanup() {
    let peer_id = "projection-store-peer";
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(PeerId::new(peer_id).expect("peer id"), registry);
    let direct_handle = manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("direct path");
    let direct_projection = manager
        .projection(&direct_handle)
        .expect("direct projection");
    let relay_handle = manager
        .publish_ready_with_route(ActiveRoute::relay(None))
        .expect("relay path");
    let relay_projection = manager.projection(&relay_handle).expect("relay projection");

    let first_session = SessionId::new();
    let replacement_session = SessionId::new();
    let store = RuntimePathProjectionStore::new();
    assert!(store
        .handles_for_session("missing-peer", first_session)
        .await
        .direct
        .is_none());

    store
        .replace_topology(peer_id, first_session, direct_projection.clone())
        .await;
    assert!(store.has_alive(peer_id, first_session).await);

    // The same topology is a single slot even when a newer session wins.
    store
        .replace_topology(peer_id, replacement_session, direct_projection)
        .await;
    assert!(!store.has_alive(peer_id, first_session).await);
    store
        .replace_topology(peer_id, first_session, relay_projection)
        .await;

    let replacement = store
        .handles_for_session(peer_id, replacement_session)
        .await;
    assert_eq!(replacement.direct.as_ref(), Some(&direct_handle));
    assert!(replacement.relay.is_none());
    let first = store.handles_for_session(peer_id, first_session).await;
    assert_eq!(first.relay.as_ref(), Some(&relay_handle));

    // A handle from the wrong topology cannot remove the current projection.
    store
        .remove_closed_for_session(peer_id, replacement_session, Some(&relay_handle), None)
        .await;
    assert!(store.has_alive(peer_id, replacement_session).await);
    store
        .remove_closed_for_session(peer_id, replacement_session, Some(&direct_handle), None)
        .await;
    assert!(!store.has_alive(peer_id, replacement_session).await);
    assert!(store.has_alive(peer_id, first_session).await);

    store.remove_topology(peer_id, RouteTopology::Relay).await;
    assert!(!store.has_alive(peer_id, first_session).await);
    assert!(store.remove_peer(peer_id).await.is_none());
}

#[tokio::test]
async fn remove_peer_returns_the_first_projection_handle() {
    let peer_id = "projection-remove-peer";
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(PeerId::new(peer_id).expect("peer id"), registry);
    let handle = manager
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("direct path");
    let projection = manager.projection(&handle).expect("projection");
    let store = RuntimePathProjectionStore::new();
    store
        .replace_topology(peer_id, SessionId::new(), projection)
        .await;

    assert_eq!(store.remove_peer(peer_id).await.as_ref(), Some(&handle));
}
