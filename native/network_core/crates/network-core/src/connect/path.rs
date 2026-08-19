//! Ready-path identity and ownership separation.
//!
//! [`PathHandle`] is a non-owning identity that may be copied into a routing
//! decision. [`PathLease`] is the bounded, owning reservation that keeps one
//! ready path admitted for a caller. Releasing a lease never closes a Session
//! or transport; the path registry remains owned by the peer/runtime owner.

use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};

use crate::connection::{ConnectionProfile, RouteTopology, RouteTransport};
use crate::errors::CoreNetworkError;

use super::peer_supervisor::PeerId;

pub(crate) const MAX_READY_PATHS_PER_PEER: usize = 8;
pub(crate) const MAX_PATH_LEASES: usize = 32;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandle {
    id: u64,
    peer_id: PeerId,
    profile: ConnectionProfile,
    capability_mask: u8,
}

impl PathHandle {
    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub(crate) fn capability_mask(&self) -> u8 {
        self.capability_mask
    }
}

struct PathEntry {
    handle: PathHandle,
    active: AtomicBool,
    leases: AtomicUsize,
}

/// An owning reservation. It is deliberately not `Clone`: each borrower must
/// acquire and release its own lease, while the owner keeps the handle/path.
pub(crate) struct PathLease {
    handle: PathHandle,
    entry: Arc<PathEntry>,
}

impl PathLease {
    pub(crate) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.handle.profile()
    }

    #[cfg(test)]
    fn lease_count(&self) -> usize {
        self.entry.leases.load(Ordering::Acquire)
    }
}

impl Drop for PathLease {
    fn drop(&mut self) {
        self.entry.leases.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Runtime-owned ready path registry.
#[derive(Default)]
pub(crate) struct PathRegistry {
    next_id: AtomicUsize,
    paths: Mutex<HashMap<PeerId, HashMap<u64, Arc<PathEntry>>>>,
}

impl PathRegistry {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicUsize::new(1),
            paths: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn publish_ready(
        &self,
        peer_id: &PeerId,
        profile: ConnectionProfile,
    ) -> Result<PathHandle, CoreNetworkError> {
        let capability_mask = super::profile_capability_mask(profile);
        if capability_mask == 0 {
            return Err(CoreNetworkError::CapabilityUnavailable);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) as u64;
        let handle = PathHandle {
            id,
            peer_id: peer_id.clone(),
            profile,
            capability_mask,
        };
        let entry = Arc::new(PathEntry {
            handle: handle.clone(),
            active: AtomicBool::new(true),
            leases: AtomicUsize::new(0),
        });
        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_paths = paths.entry(peer_id.clone()).or_default();
        if peer_paths.len() >= MAX_READY_PATHS_PER_PEER {
            return Err(CoreNetworkError::ResourceLimit("ready paths"));
        }
        peer_paths.insert(id, entry);
        Ok(handle)
    }

    pub(crate) fn acquire(&self, handle: &PathHandle) -> Result<PathLease, CoreNetworkError> {
        let entry = self
            .paths
            .lock()
            .expect("path registry lock")
            .get(handle.peer_id())
            .and_then(|paths| paths.get(&handle.id()))
            .cloned()
            .filter(|entry| entry.handle == *handle && entry.active.load(Ordering::Acquire))
            .ok_or(CoreNetworkError::StaleAttempt)?;
        reserve_lease(&entry)?;
        Ok(PathLease {
            handle: handle.clone(),
            entry,
        })
    }

    /// Select the best currently ready path that covers the requested
    /// capability mask. Incompatible ready paths are never returned.
    pub(crate) fn select_compatible_ready_path(
        &self,
        peer_id: &PeerId,
        required_capabilities: u8,
    ) -> Result<PathLease, CoreNetworkError> {
        let entry = self
            .paths
            .lock()
            .expect("path registry lock")
            .get(peer_id)
            .and_then(|paths| {
                paths
                    .values()
                    .filter(|entry| {
                        entry.active.load(Ordering::Acquire)
                            && (entry.handle.capability_mask() & required_capabilities)
                                == required_capabilities
                    })
                    .max_by_key(|entry| {
                        (path_preference(entry.handle.profile()), entry.handle.id())
                    })
                    .cloned()
            })
            .ok_or(CoreNetworkError::NoRoute)?;
        reserve_lease(&entry)?;
        Ok(PathLease {
            handle: entry.handle.clone(),
            entry,
        })
    }

    pub(crate) fn revoke(&self, handle: &PathHandle) -> bool {
        let removed = self
            .paths
            .lock()
            .expect("path registry lock")
            .get_mut(handle.peer_id())
            .and_then(|paths| paths.remove(&handle.id()));
        if let Some(entry) = removed {
            entry.active.store(false, Ordering::Release);
            true
        } else {
            false
        }
    }

    pub(crate) fn revoke_peer(&self, peer_id: &PeerId) -> usize {
        let entries = self
            .paths
            .lock()
            .expect("path registry lock")
            .remove(peer_id)
            .map(|paths| paths.into_values().collect::<Vec<_>>())
            .unwrap_or_default();
        let count = entries.len();
        for entry in entries {
            entry.active.store(false, Ordering::Release);
        }
        count
    }
}

fn reserve_lease(entry: &Arc<PathEntry>) -> Result<(), CoreNetworkError> {
    if !entry.active.load(Ordering::Acquire) {
        return Err(CoreNetworkError::StaleAttempt);
    }
    loop {
        let current = entry.leases.load(Ordering::Acquire);
        if current >= MAX_PATH_LEASES {
            return Err(CoreNetworkError::ResourceLimit("path leases"));
        }
        if entry
            .leases
            .compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            if entry.active.load(Ordering::Acquire) {
                return Ok(());
            }
            entry.leases.fetch_sub(1, Ordering::AcqRel);
            return Err(CoreNetworkError::StaleAttempt);
        }
    }
}

fn path_preference(profile: ConnectionProfile) -> u8 {
    match (profile.topology(), profile.transport()) {
        (RouteTopology::Direct, RouteTransport::Quic) => 4,
        (RouteTopology::Direct, RouteTransport::Tcp) => 3,
        (RouteTopology::Direct, RouteTransport::WebSocket) => 2,
        (RouteTopology::Relay, _) => 1,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::{CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_RELIABLE_STREAM};
    use crate::connection::{Route, RouteTransport};

    #[test]
    fn handles_are_non_owning_and_leases_are_released() {
        let registry = PathRegistry::new();
        let peer = PeerId::new("peer-a").expect("peer id");
        let handle = registry
            .publish_ready(
                &peer,
                ConnectionProfile::new(Route::direct(RouteTransport::Tcp)),
            )
            .expect("ready path");
        let lease = registry.acquire(&handle).expect("lease");
        assert_eq!(lease.handle(), &handle);
        assert_eq!(lease.lease_count(), 1);
        drop(lease);
        let lease = registry.acquire(&handle).expect("second lease");
        assert_eq!(lease.lease_count(), 1);
    }

    #[test]
    fn selection_skips_incompatible_ready_paths_and_prefers_direct() {
        let registry = PathRegistry::new();
        let peer = PeerId::new("peer-a").expect("peer id");
        let _message_only = registry
            .publish_ready(
                &peer,
                ConnectionProfile::new(Route::direct(RouteTransport::WebSocket)),
            )
            .expect("message path");
        let direct = registry
            .publish_ready(
                &peer,
                ConnectionProfile::new(Route::direct(RouteTransport::Quic)),
            )
            .expect("quic path");
        let relay = registry
            .publish_ready(
                &peer,
                ConnectionProfile::new(Route::relay(RouteTransport::WebSocket)),
            )
            .expect("relay path");

        let stream = registry
            .select_compatible_ready_path(&peer, CAPABILITY_RELIABLE_STREAM)
            .expect("stream path");
        assert_eq!(stream.handle(), &direct);
        drop(stream);
        let message = registry
            .select_compatible_ready_path(&peer, CAPABILITY_RELIABLE_MESSAGE)
            .expect("message path");
        assert_eq!(message.handle(), &direct);
        assert_ne!(message.handle(), &relay);
    }

    #[test]
    fn revoked_handle_cannot_be_reacquired() {
        let registry = PathRegistry::new();
        let peer = PeerId::new("peer-a").expect("peer id");
        let handle = registry
            .publish_ready(
                &peer,
                ConnectionProfile::new(Route::direct(RouteTransport::Tcp)),
            )
            .expect("ready path");
        assert!(registry.revoke(&handle));
        assert!(matches!(
            registry.acquire(&handle),
            Err(CoreNetworkError::StaleAttempt)
        ));
        assert!(matches!(
            registry.select_compatible_ready_path(&peer, 1),
            Err(CoreNetworkError::NoRoute)
        ));
    }
}
