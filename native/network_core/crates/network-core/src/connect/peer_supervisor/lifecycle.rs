//! Peer lifecycle invalidation, inbound admission, and task/resource cleanup.

use super::*;

impl PeerSupervisor {
    /// Invalidate all current work and wake its waiters before the peer is
    /// removed from the active graph.
    pub(crate) fn disconnect(&self) -> usize {
        self.invalidate_generation(false, true, CoreNetworkError::Cancelled)
    }

    pub(crate) fn stop(&self) -> usize {
        let delivered =
            self.invalidate_generation(true, true, CoreNetworkError::SupervisorStopping);
        self.cancel_mailbox_worker();
        delivered
    }

    pub(crate) fn acquire_resource(
        self: &Arc<Self>,
    ) -> Result<PeerResourceLease, CoreNetworkError> {
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        if inner.stopping {
            return Err(CoreNetworkError::SupervisorStopping);
        }
        if inner.resources >= MAX_PEER_RESOURCES {
            return Err(CoreNetworkError::ResourceLimit("peer resources"));
        }
        inner.resources += 1;
        Ok(PeerResourceLease {
            supervisor: Arc::clone(self),
            resource_id: self.next_resource_id.fetch_add(1, Ordering::Relaxed),
        })
    }

    pub(crate) fn release_resource(&self, _resource_id: u64) {
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        inner.resources = inner.resources.saturating_sub(1);
    }

    pub(crate) fn fail_generation(&self, generation: IntentGeneration, error: CoreNetworkError) {
        let waiters = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if inner.generation != generation {
                return;
            }
            inner.state = PeerState::Offline;
            inner.active_requirement = None;
            inner.ready_requirement = None;
            inner.retry_scheduled = false;
            inner
                .waiters
                .drain()
                .map(|(_, waiter)| waiter.sender)
                .collect::<Vec<_>>()
        };
        for waiter in waiters {
            let _ = waiter.send(Err(error.clone()));
        }
    }

    pub(crate) fn maintain_connection(&self) -> bool {
        self.inner
            .lock()
            .expect("peer supervisor lock")
            .maintain_connection
    }

    /// A trusted authenticated inbound path may make a passive peer Online,
    /// but never changes the maintenance policy or starts background recovery.
    pub(crate) fn admit_inbound(&self, authenticated: bool) -> Result<PeerState, CoreNetworkError> {
        self.admit_inbound_with_capabilities(
            authenticated,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        )
    }

    pub(crate) fn admit_inbound_with_capabilities(
        &self,
        authenticated: bool,
        capabilities: u8,
    ) -> Result<PeerState, CoreNetworkError> {
        if !authenticated {
            return Err(CoreNetworkError::Cancelled);
        }
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        if inner.stopping {
            return Err(CoreNetworkError::SupervisorStopping);
        }
        inner.state = PeerState::Online;
        let requirement = PeerRequirement::from_capability_mask(capabilities);
        inner.active_requirement = Some(requirement);
        inner.ready_requirement = Some(requirement);
        Ok(inner.state)
    }

    /// Path loss is a lifecycle observation, not a transport/session truth
    /// leak. Passive peers go Offline; maintained peers remain Offline until a
    /// bounded, explicit recovery trigger starts a new intent.
    pub(crate) fn path_lost(&self) {
        // A loss is an observation owned by the peer lifecycle coordinator.
        // It invalidates the current attempt generation but deliberately
        // preserves `maintain_connection`; a later explicit retry can submit
        // a fresh intent without the SessionStore becoming a reconnect owner.
        self.invalidate_generation(false, false, CoreNetworkError::Cancelled);
    }

    fn invalidate_generation(
        &self,
        stopping: bool,
        clear_maintenance: bool,
        completion_error: CoreNetworkError,
    ) -> usize {
        let (previous_generation, waiters, delivered) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if stopping {
                inner.stopping = true;
            } else if inner.stopping {
                return 0;
            }
            let previous_generation = inner.generation;
            inner.generation = inner.generation.next();
            inner.state = PeerState::Offline;
            inner.active_requirement = None;
            inner.ready_requirement = None;
            inner.retry_scheduled = false;
            if clear_maintenance {
                inner.maintain_connection = false;
            }
            let waiters = inner
                .waiters
                .drain()
                .map(|(_, waiter)| waiter.sender)
                .collect::<Vec<_>>();
            let delivered = waiters.len();
            (previous_generation, waiters, delivered)
        };

        // Invalidate the generation before cancellation so a completion that
        // races with abort can only observe StaleIntent.
        self.cancel_connection_task_for(previous_generation);
        for waiter in waiters {
            let _ = waiter.send(Err(completion_error.clone()));
        }
        delivered
    }

    /// Cancel the single supervised connectivity attempt, if any. This is
    /// deliberately separate from closing a route: the owner invalidates the
    /// generation first, then aborts only its own establishment task.
    pub(crate) fn cancel_connection_task(&self) {
        if let Some(mut task) = self
            .connection_task
            .lock()
            .expect("peer connection task lock")
            .take()
        {
            task.lease.abort_now();
            self.mark_child_finished();
        }
    }

    pub(crate) fn cancel_connection_task_for(&self, generation: IntentGeneration) {
        let task = {
            let mut current = self
                .connection_task
                .lock()
                .expect("peer connection task lock");
            if current
                .as_ref()
                .is_some_and(|task| task.generation == generation)
            {
                current.take()
            } else {
                None
            }
        };
        if let Some(mut task) = task {
            task.lease.abort_now();
            self.mark_child_finished();
        }
    }

    fn cancel_mailbox_worker(&self) {
        if let Some(mut task) = self
            .mailbox_task
            .lock()
            .expect("peer mailbox task lock")
            .take()
        {
            task.abort_now();
        }
    }

    pub(crate) fn take_connection_task(
        &self,
        generation: IntentGeneration,
        attempt_id: u64,
    ) -> Option<ConnectionTask> {
        let mut task = self
            .connection_task
            .lock()
            .expect("peer connection task lock");
        if task
            .as_ref()
            .is_some_and(|task| task.generation == generation && task.attempt_id == attempt_id)
        {
            task.take()
        } else {
            None
        }
    }

    pub(crate) fn set_configured(&self, configured: bool) {
        self.inner.lock().expect("peer supervisor lock").configured = configured;
    }

    pub(crate) fn mark_child_started(&self) -> Result<(), CoreNetworkError> {
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        if inner.active_children >= 1 {
            return Err(CoreNetworkError::ResourceLimit("peer establishment"));
        }
        inner.active_children += 1;
        Ok(())
    }

    pub(crate) fn mark_child_finished(&self) {
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        inner.active_children = inner.active_children.saturating_sub(1);
    }

    pub(crate) fn can_evict(&self) -> bool {
        let inner = self.inner.lock().expect("peer supervisor lock");
        inner.state == PeerState::Offline
            && !inner.maintain_connection
            && inner.waiters.is_empty()
            && inner.active_children == 0
            && !inner.retry_scheduled
            && inner.resources == 0
            && inner.business_work == 0
    }

    pub(crate) fn is_configured(&self) -> bool {
        self.inner.lock().expect("peer supervisor lock").configured
    }
}
