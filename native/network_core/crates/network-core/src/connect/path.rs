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
use std::time::{Duration, Instant};

use crate::connection::{ConnectionProfile, RouteTopology, RouteTransport};
use crate::errors::CoreNetworkError;

use super::peer_supervisor::PeerId;

pub(crate) const MAX_READY_PATHS_PER_PEER: usize = 8;
pub(crate) const MAX_PATH_LEASES: usize = 32;

/// The two path topologies owned by one peer supervisor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathKind {
    Direct,
    Relay,
}

/// A bounded Direct probe can coexist with an already Ready Direct path.
/// Candidate execution remains in `ConnectivityAttempt`; this value is only
/// the peer-owned lifecycle/selection record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DirectProbe {
    pub(crate) generation: u64,
    pub(crate) required_capabilities: u8,
    pub(crate) deadline: Instant,
}

impl DirectProbe {
    fn extend(&mut self, required_capabilities: u8, deadline: Instant) {
        self.required_capabilities |= required_capabilities;
        self.deadline = self.deadline.max(deadline);
    }

    pub(crate) fn is_expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }
}

/// Result of selecting a path. A caller still has to acquire a `PathLease`;
/// the enum never owns a path or transport.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathSelection {
    Direct,
    Relay,
}

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
    accepting: AtomicBool,
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

    /// Hard-close and normal drain both revoke future acquisition. Existing
    /// borrowers can observe the revocation and unwind without the lease
    /// pretending to keep a dead path usable.
    pub(crate) fn is_active(&self) -> bool {
        self.entry.active.load(Ordering::Acquire)
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
            accepting: AtomicBool::new(true),
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
            .filter(|entry| {
                entry.handle == *handle
                    && entry.active.load(Ordering::Acquire)
                    && entry.accepting.load(Ordering::Acquire)
            })
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
                            && entry.accepting.load(Ordering::Acquire)
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
            entry.accepting.store(false, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// Normal retirement: stop new leases while retaining the entry until the
    /// owner performs final cleanup. Existing leases are allowed to drain.
    pub(crate) fn drain(&self, handle: &PathHandle) -> bool {
        let entry = self
            .paths
            .lock()
            .expect("path registry lock")
            .get(handle.peer_id())
            .and_then(|paths| paths.get(&handle.id()))
            .cloned()
            .filter(|entry| entry.handle == *handle);
        if let Some(entry) = entry {
            entry.accepting.store(false, Ordering::Release);
            true
        } else {
            false
        }
    }

    pub(crate) fn lease_count(&self, handle: &PathHandle) -> Option<usize> {
        self.paths
            .lock()
            .expect("path registry lock")
            .get(handle.peer_id())
            .and_then(|paths| paths.get(&handle.id()))
            .filter(|entry| entry.handle == *handle)
            .map(|entry| entry.leases.load(Ordering::Acquire))
    }

    fn is_acquirable(&self, handle: &PathHandle) -> bool {
        self.paths
            .lock()
            .expect("path registry lock")
            .get(handle.peer_id())
            .and_then(|paths| paths.get(&handle.id()))
            .is_some_and(|entry| {
                entry.handle == *handle
                    && entry.active.load(Ordering::Acquire)
                    && entry.accepting.load(Ordering::Acquire)
            })
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
            entry.accepting.store(false, Ordering::Release);
        }
        count
    }
}

/// Per-peer path truth. It deliberately has no mutable global `active_path`:
/// Direct Ready, Direct Probe, and Relay Ready are independent states and a
/// selection is made only when a business request asks for a capability.
pub(crate) struct PeerPathManager {
    peer_id: PeerId,
    registry: Arc<PathRegistry>,
    direct_ready: Vec<PathHandle>,
    relay_ready: Option<PathHandle>,
    direct_probe: Option<DirectProbe>,
    draining: bool,
    hard_closed: bool,
    last_activity: Instant,
}

impl PeerPathManager {
    pub(crate) fn new(peer_id: PeerId, registry: Arc<PathRegistry>) -> Self {
        Self {
            peer_id,
            registry,
            direct_ready: Vec::new(),
            relay_ready: None,
            direct_probe: None,
            draining: false,
            hard_closed: false,
            last_activity: Instant::now(),
        }
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn direct_ready(&self) -> &[PathHandle] {
        &self.direct_ready
    }

    pub(crate) fn relay_ready(&self) -> Option<&PathHandle> {
        self.relay_ready.as_ref()
    }

    pub(crate) fn direct_probe(&self) -> Option<&DirectProbe> {
        self.direct_probe.as_ref()
    }

    pub(crate) fn publish_ready(
        &mut self,
        profile: ConnectionProfile,
    ) -> Result<PathHandle, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }
        let handle = self.registry.publish_ready(&self.peer_id, profile)?;
        self.last_activity = Instant::now();
        match profile.topology() {
            RouteTopology::Direct => self.direct_ready.push(handle.clone()),
            RouteTopology::Relay => self.relay_ready = Some(handle.clone()),
        }
        Ok(handle)
    }

    /// Start or extend one Direct probe. A stronger request extends the
    /// current demand rather than creating another physical establishment.
    pub(crate) fn ensure_direct_probe(
        &mut self,
        generation: u64,
        required_capabilities: u8,
        budget: Duration,
    ) -> Result<&DirectProbe, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }
        let deadline = Instant::now() + budget;
        self.last_activity = Instant::now();
        match self.direct_probe.as_mut() {
            Some(probe) => {
                if probe.generation != generation {
                    return Err(CoreNetworkError::StaleAttempt);
                }
                probe.extend(required_capabilities, deadline);
            }
            None => {
                self.direct_probe = Some(DirectProbe {
                    generation,
                    required_capabilities,
                    deadline,
                });
            }
        }
        Ok(self.direct_probe.as_ref().expect("probe just installed"))
    }

    pub(crate) fn finish_direct_probe(&mut self, generation: u64) -> bool {
        if self
            .direct_probe
            .as_ref()
            .is_some_and(|probe| probe.generation == generation)
        {
            self.direct_probe = None;
            true
        } else {
            false
        }
    }

    /// Select Direct immediately when compatible. If it is unavailable, an
    /// already Ready Relay is immediately usable while Direct recovery may
    /// continue in `direct_probe`.
    pub(crate) fn select(&self, required_capabilities: u8) -> Option<PathSelection> {
        if self.direct_ready.iter().any(|handle| {
            handle.capability_mask() & required_capabilities == required_capabilities
                && self.registry.is_acquirable(handle)
        }) {
            return Some(PathSelection::Direct);
        }
        self.relay_ready.as_ref().and_then(|handle| {
            (handle.capability_mask() & required_capabilities == required_capabilities
                && self.registry.is_acquirable(handle))
            .then_some(PathSelection::Relay)
        })
    }

    pub(crate) fn acquire(
        &self,
        required_capabilities: u8,
    ) -> Result<(PathSelection, PathLease), CoreNetworkError> {
        match self.select(required_capabilities) {
            Some(PathSelection::Direct) => {
                let handle = self
                    .direct_ready
                    .iter()
                    .find(|handle| {
                        handle.capability_mask() & required_capabilities == required_capabilities
                            && self.registry.is_acquirable(handle)
                    })
                    .ok_or(CoreNetworkError::NoRoute)?;
                Ok((PathSelection::Direct, self.registry.acquire(handle)?))
            }
            Some(PathSelection::Relay) => {
                let handle = self.relay_ready.as_ref().expect("relay selection handle");
                Ok((PathSelection::Relay, self.registry.acquire(handle)?))
            }
            None => Err(CoreNetworkError::NoRoute),
        }
    }

    pub(crate) fn normal_drain(&mut self) {
        self.draining = true;
        for handle in self.direct_ready.iter().chain(self.relay_ready.iter()) {
            self.registry.drain(handle);
        }
    }

    pub(crate) fn record_activity(&mut self) {
        self.last_activity = Instant::now();
    }

    pub(crate) fn hard_close(&mut self) {
        self.hard_closed = true;
        self.draining = true;
        for handle in self.direct_ready.drain(..) {
            self.registry.revoke(&handle);
        }
        if let Some(handle) = self.relay_ready.take() {
            self.registry.revoke(&handle);
        }
        self.direct_probe = None;
    }

    pub(crate) fn ephemeral_idle(&self, now: Instant) -> bool {
        !self.draining
            && !self.hard_closed
            && self.direct_probe.is_none()
            && self
                .direct_ready
                .iter()
                .chain(self.relay_ready.iter())
                .all(|handle| self.registry.lease_count(handle) == Some(0))
            && self
                .direct_probe
                .as_ref()
                .is_none_or(|probe| probe.is_expired(now))
            && now.saturating_duration_since(self.last_activity)
                >= super::EPHEMERAL_PATH_IDLE_TIMEOUT
    }
}

fn reserve_lease(entry: &Arc<PathEntry>) -> Result<(), CoreNetworkError> {
    if !entry.active.load(Ordering::Acquire) || !entry.accepting.load(Ordering::Acquire) {
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
            if entry.active.load(Ordering::Acquire) && entry.accepting.load(Ordering::Acquire) {
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

    #[test]
    fn peer_path_manager_keeps_direct_ready_and_probe_and_uses_relay_immediately() {
        let registry = Arc::new(PathRegistry::new());
        let peer = PeerId::new("peer-a").expect("peer id");
        let mut manager = PeerPathManager::new(peer, Arc::clone(&registry));
        let relay = manager
            .publish_ready(ConnectionProfile::new(Route::relay(
                RouteTransport::WebSocket,
            )))
            .expect("relay path");

        assert_eq!(
            manager.select(CAPABILITY_RELIABLE_MESSAGE),
            Some(PathSelection::Relay)
        );
        let (selection, lease) = manager
            .acquire(CAPABILITY_RELIABLE_MESSAGE)
            .expect("ready relay is immediately usable");
        assert_eq!(selection, PathSelection::Relay);
        assert_eq!(lease.handle(), &relay);

        manager
            .ensure_direct_probe(7, CAPABILITY_RELIABLE_MESSAGE, Duration::from_secs(4))
            .expect("direct recovery probe");
        assert!(manager.direct_probe().is_some());
        drop(lease);
    }

    #[test]
    fn peer_path_manager_prefers_direct_without_destroying_relay() {
        let registry = Arc::new(PathRegistry::new());
        let peer = PeerId::new("peer-a").expect("peer id");
        let mut manager = PeerPathManager::new(peer, Arc::clone(&registry));
        let relay = manager
            .publish_ready(ConnectionProfile::new(Route::relay(
                RouteTransport::WebSocket,
            )))
            .expect("relay path");
        let direct = manager
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Quic)))
            .expect("direct path");

        let (selection, lease) = manager
            .acquire(CAPABILITY_RELIABLE_MESSAGE)
            .expect("direct path");
        assert_eq!(selection, PathSelection::Direct);
        assert_eq!(lease.handle(), &direct);
        drop(lease);
        assert!(registry.acquire(&relay).is_ok());
    }

    #[test]
    fn hard_close_revokes_existing_leases_and_normal_drain_rejects_new_ones() {
        let registry = Arc::new(PathRegistry::new());
        let peer = PeerId::new("peer-a").expect("peer id");
        let mut manager = PeerPathManager::new(peer, Arc::clone(&registry));
        let handle = manager
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
            .expect("direct path");
        let lease = registry.acquire(&handle).expect("lease");
        manager.normal_drain();
        assert!(lease.is_active());
        assert!(matches!(
            registry.acquire(&handle),
            Err(CoreNetworkError::StaleAttempt)
        ));
        drop(lease);

        manager.hard_close();
        assert!(matches!(
            registry.acquire(&handle),
            Err(CoreNetworkError::StaleAttempt)
        ));
    }
}
