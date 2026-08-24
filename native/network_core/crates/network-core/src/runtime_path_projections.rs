//! Session-scoped, non-owning projections of peer-owned transport paths.

use crate::connect::{PathHandle, PathProjection};
use crate::connection::RouteTopology;
use crate::session::SessionId;
use std::collections::HashMap;
use tokio::sync::RwLock;

/// A path projection never retains an independent carrier owner.
struct OwnedPathProjection {
    session_id: SessionId,
    projection: PathProjection,
}

#[derive(Default)]
pub(crate) struct SessionPathHandles {
    pub(crate) direct: Option<PathHandle>,
    pub(crate) relay: Option<PathHandle>,
}

/// Owns session bindings and stale guards for non-owning path projections.
///
/// `PeerPathManager` remains the only carrier owner. This store centralizes
/// topology replacement and exact-handle cleanup so Runtime orchestration
/// cannot mutate the projection map inconsistently.
#[derive(Default)]
pub(crate) struct RuntimePathProjectionStore {
    entries: RwLock<HashMap<String, Vec<OwnedPathProjection>>>,
}

impl RuntimePathProjectionStore {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) async fn replace_topology(
        &self,
        peer_id: &str,
        session_id: SessionId,
        projection: PathProjection,
    ) {
        let topology = projection.handle().profile().topology();
        let mut paths = self.entries.write().await;
        let entries = paths.entry(peer_id.to_string()).or_default();
        entries.retain(|entry| entry.projection.handle().profile().topology() != topology);
        entries.push(OwnedPathProjection {
            session_id,
            projection,
        });
    }

    pub(crate) async fn has_alive(&self, peer_id: &str, session_id: SessionId) -> bool {
        self.entries
            .read()
            .await
            .get(peer_id)
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry.session_id == session_id && entry.projection.is_alive())
            })
    }

    pub(crate) async fn handles_for_session(
        &self,
        peer_id: &str,
        session_id: SessionId,
    ) -> SessionPathHandles {
        let paths = self.entries.read().await;
        let Some(entries) = paths.get(peer_id) else {
            return SessionPathHandles::default();
        };
        let find = |topology| {
            entries
                .iter()
                .find(|entry| {
                    entry.session_id == session_id
                        && entry.projection.handle().profile().topology() == topology
                })
                .map(|entry| entry.projection.handle().clone())
        };
        SessionPathHandles {
            direct: find(RouteTopology::Direct),
            relay: find(RouteTopology::Relay),
        }
    }

    pub(crate) async fn remove_closed_for_session(
        &self,
        peer_id: &str,
        session_id: SessionId,
        direct_handle: Option<&PathHandle>,
        relay_handle: Option<&PathHandle>,
    ) {
        let mut paths = self.entries.write().await;
        let Some(entries) = paths.get_mut(peer_id) else {
            return;
        };
        entries.retain(|entry| {
            if entry.session_id != session_id {
                return true;
            }
            let handle = entry.projection.handle();
            !direct_handle.is_some_and(|expected| {
                handle.profile().topology() == RouteTopology::Direct && handle == expected
            }) && !relay_handle.is_some_and(|expected| {
                handle.profile().topology() == RouteTopology::Relay && handle == expected
            })
        });
        if entries.is_empty() {
            paths.remove(peer_id);
        }
    }

    /// Remove only the projection for the path identity that was actually
    /// closed. A replacement of the same topology may already have been
    /// published while asynchronous cleanup was waiting for this lock.
    pub(crate) async fn remove_handle(&self, peer_id: &str, expected: &PathHandle) {
        let mut paths = self.entries.write().await;
        if let Some(entries) = paths.get_mut(peer_id) {
            entries.retain(|entry| entry.projection.handle() != expected);
            if entries.is_empty() {
                paths.remove(peer_id);
            }
        }
    }

    pub(crate) async fn remove_peer(&self, peer_id: &str) -> Option<PathHandle> {
        self.entries
            .write()
            .await
            .remove(peer_id)
            .and_then(|entries| {
                entries
                    .first()
                    .map(|entry| entry.projection.handle().clone())
            })
    }
}

#[cfg(test)]
#[path = "tests/runtime_path_projections.rs"]
mod tests;
