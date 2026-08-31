//! Registry ownership and process-wide peer admission limits.

use super::*;

/// Registry that creates exactly one supervisor for each validated peer id.
pub(crate) struct PeerSupervisorRegistry {
    supervisors: RwLock<HashMap<PeerId, Arc<PeerSupervisor>>>,
}

impl Default for PeerSupervisorRegistry {
    fn default() -> Self {
        Self {
            supervisors: RwLock::new(HashMap::new()),
        }
    }
}

impl PeerSupervisorRegistry {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Runtime construction keeps this entry point for the shared wiring;
    /// each peer starts its worker when the runtime state is available to
    /// `start_connect`.
    pub(crate) fn with_task_supervisor(_task_supervisor: Arc<RuntimeTaskSupervisor>) -> Self {
        Self::default()
    }

    pub(crate) fn get_or_create(
        &self,
        peer_id: &str,
    ) -> Result<Arc<PeerSupervisor>, CoreNetworkError> {
        self.get_or_create_with_configured(peer_id, false)
    }

    pub(crate) fn get_or_create_with_configured(
        &self,
        peer_id: &str,
        configured: bool,
    ) -> Result<Arc<PeerSupervisor>, CoreNetworkError> {
        let peer_id = PeerId::new(peer_id)?;
        if let Some(supervisor) = self
            .supervisors
            .read()
            .expect("peer supervisor registry lock")
            .get(&peer_id)
            .cloned()
        {
            if configured {
                if !supervisor.is_configured()
                    && self
                        .supervisors
                        .read()
                        .expect("peer supervisor registry lock")
                        .values()
                        .filter(|candidate| candidate.is_configured())
                        .count()
                        >= crate::connect::MAX_CONFIGURED_PEERS
                {
                    return Err(CoreNetworkError::ResourceLimit("configured peers"));
                }
                supervisor.set_configured(true);
            }
            return Ok(supervisor);
        }
        let mut supervisors = self
            .supervisors
            .write()
            .expect("peer supervisor registry lock");
        if let Some(supervisor) = supervisors.get(&peer_id).cloned() {
            if configured {
                if !supervisor.is_configured()
                    && supervisors
                        .values()
                        .filter(|candidate| candidate.is_configured())
                        .count()
                        >= crate::connect::MAX_CONFIGURED_PEERS
                {
                    return Err(CoreNetworkError::ResourceLimit("configured peers"));
                }
                supervisor.set_configured(true);
            }
            return Ok(supervisor);
        }
        if configured
            && supervisors
                .values()
                .filter(|supervisor| supervisor.is_configured())
                .count()
                >= crate::connect::MAX_CONFIGURED_PEERS
        {
            return Err(CoreNetworkError::ResourceLimit("configured peers"));
        }
        if supervisors.len() >= crate::connect::MAX_CONFIGURED_PEERS {
            if let Some(evict_peer) = supervisors
                .iter()
                .find(|(_, supervisor)| supervisor.can_evict())
                .map(|(peer_id, _)| peer_id.clone())
            {
                if let Some(supervisor) = supervisors.remove(&evict_peer) {
                    supervisor.stop();
                }
            } else {
                return Err(CoreNetworkError::ResourceLimit("peer supervisors"));
            }
        }

        let supervisor = PeerSupervisor::new(peer_id.clone());
        supervisor.set_configured(configured);
        supervisors.insert(peer_id, Arc::clone(&supervisor));
        Ok(supervisor)
    }

    /// Start one command-owned establishment after enforcing the frozen
    /// process-wide active-peer budget. A healthy Online/Connecting peer may
    /// join its existing generation; only a new active peer consumes a slot.
    pub(crate) fn start_connect(
        &self,
        state: Arc<RuntimeState>,
        peer_id: &str,
        command_id: String,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        let supervisor = self.get_or_create(peer_id)?;
        let already_active = matches!(
            supervisor.state(),
            PeerState::Connecting | PeerState::Online
        );
        if !already_active {
            let active_peers = self
                .supervisors
                .read()
                .expect("peer supervisor registry lock")
                .values()
                .filter(|candidate| {
                    matches!(candidate.state(), PeerState::Connecting | PeerState::Online)
                })
                .count();
            if active_peers >= crate::connect::MAX_ACTIVE_PEERS {
                return Err(CoreNetworkError::ResourceLimit("active peers"));
            }
        }
        supervisor.start_connect(state, command_id, class)
    }

    pub(crate) fn start_business(
        &self,
        state: Arc<RuntimeState>,
        peer_id: &str,
        command_id: String,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        let supervisor = self.get_or_create(peer_id)?;
        supervisor.start_business(state, command_id, class)
    }

    pub(crate) fn disconnect(&self, peer_id: &str) -> Result<usize, CoreNetworkError> {
        let peer_id = PeerId::new(peer_id)?;
        Ok(self
            .supervisors
            .read()
            .expect("peer supervisor registry lock")
            .get(&peer_id)
            .cloned()
            .map(|supervisor| supervisor.disconnect())
            .unwrap_or(0))
    }

    pub(crate) fn remove_if_evictable(&self, peer_id: &str) -> Result<bool, CoreNetworkError> {
        let peer_id = PeerId::new(peer_id)?;
        let mut supervisors = self
            .supervisors
            .write()
            .expect("peer supervisor registry lock");
        let Some(supervisor) = supervisors.get(&peer_id) else {
            return Ok(false);
        };
        if !supervisor.can_evict() {
            return Ok(false);
        }
        supervisor.stop();
        supervisors.remove(&peer_id);
        Ok(true)
    }

    pub(crate) fn stop_all(&self) {
        let supervisors = self
            .supervisors
            .read()
            .expect("peer supervisor registry lock")
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for supervisor in supervisors {
            supervisor.stop();
        }
    }
}
