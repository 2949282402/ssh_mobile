//! Supervised mailbox and connectivity-attempt execution.

use super::*;

impl PeerSupervisor {
    /// Start the peer mailbox worker and submit the sole transport-establishment
    /// intent owned by this supervisor.
    pub(crate) fn start_connect(
        self: &Arc<Self>,
        state: Arc<RuntimeState>,
        command_id: String,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        self.start_mailbox_worker(Arc::clone(&state))?;
        self.begin_connect(&command_id, class)
    }

    /// Start or join a business-owned establishment without enabling
    /// long-lived maintenance. The mailbox worker is still the only caller
    /// allowed to launch `ConnectivityAttemptCoordinator`.
    pub(crate) fn start_business(
        self: &Arc<Self>,
        state: Arc<RuntimeState>,
        command_id: String,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        self.start_mailbox_worker(state)?;
        self.ensure(&command_id, class)
    }

    /// Start the only worker that consumes this peer's intents.  The worker
    /// owns the hand-off from the mailbox to a supervised
    /// `ConnectivityAttemptCoordinator`; callers never start an attempt
    /// directly.
    fn start_mailbox_worker(
        self: &Arc<Self>,
        state: Arc<RuntimeState>,
    ) -> Result<(), CoreNetworkError> {
        let mut mailbox_task = self.mailbox_task.lock().expect("peer mailbox task lock");
        if mailbox_task.is_some() {
            return Ok(());
        }

        let receiver = self
            .mailbox_rx
            .lock()
            .expect("peer mailbox lock")
            .take()
            .ok_or(CoreNetworkError::SupervisorStopping)?;
        let supervisor = Arc::clone(self);
        let task_supervisor = Arc::clone(&state.task_supervisor);
        let worker_task_supervisor = Arc::clone(&task_supervisor);
        let peer_id = self.peer_id.as_str().to_string();
        let task = task_supervisor.spawn_session_controlled(
            format!("peer-mailbox/{peer_id}"),
            "peer-mailbox",
            async move {
                let mut receiver = receiver;
                while let Some(intent) = receiver.recv().await {
                    supervisor.start_attempt(
                        Arc::clone(&state),
                        Arc::clone(&worker_task_supervisor),
                        intent,
                    );
                }
            },
        );
        let Some(task) = task else {
            return Err(CoreNetworkError::SupervisorStopping);
        };
        *mailbox_task = Some(task);
        Ok(())
    }

    fn start_attempt(
        self: &Arc<Self>,
        state: Arc<RuntimeState>,
        task_supervisor: Arc<RuntimeTaskSupervisor>,
        intent: PeerIntent,
    ) {
        if !self.is_current(intent.generation) {
            return;
        }

        let attempt_requirement = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if inner.stopping || inner.generation != intent.generation {
                return;
            }
            inner.retry_scheduled = false;
            inner.active_requirement.unwrap_or_else(|| {
                PeerRequirement::from_capability_mask(intent.required_capabilities)
            })
        };

        // A newly queued attempt cancels the previous attempt before its
        // candidate race is started.  This can be a stronger replacement in
        // the same generation; the generation plus attempt token remains the
        // authority for deciding whether a completion may update peer state.
        self.cancel_connection_task();
        if let Err(error) = self.mark_child_started() {
            self.complete_attempt_without_task(intent.generation, Err(error), false);
            return;
        }

        let supervisor = Arc::clone(self);
        let peer_id = self.peer_id.as_str().to_string();
        let generation = intent.generation;
        let attempt_id = self.next_attempt_id.fetch_add(1, Ordering::Relaxed);
        let task_state = Arc::clone(&state);
        let task = task_supervisor.spawn_session_controlled(
            format!(
                "peer-connect/{peer_id}/{generation}",
                generation = generation.get()
            ),
            "peer-connect",
            async move {
                let attempt_coordinator =
                    crate::connect::ConnectivityAttemptCoordinator::new(Arc::clone(&task_state));
                let result = attempt_coordinator
                    .connect_with_capabilities_for_command(
                        &peer_id,
                        attempt_requirement.capability_mask(),
                        &intent.command_id,
                    )
                    .await;
                supervisor.finish_attempt(generation, attempt_id, result, task_state);
            },
        );
        let Some(task) = task else {
            self.complete_attempt_without_task(
                generation,
                Err(CoreNetworkError::SupervisorStopping),
                true,
            );
            return;
        };
        self.connection_task
            .lock()
            .expect("peer connection task lock")
            .replace(ConnectionTask {
                generation,
                attempt_id,
                requirement: attempt_requirement,
                lease: task,
            });
        if !self.is_current(generation) {
            self.cancel_connection_task_for(generation);
        }
    }

    fn finish_attempt(
        &self,
        generation: IntentGeneration,
        attempt_id: u64,
        result: Result<(), ProtocolError>,
        state: Arc<RuntimeState>,
    ) {
        let failure = result.as_ref().err().map(|error| {
            (
                NetworkErrorCode::try_from(error.code).unwrap_or(NetworkErrorCode::Unspecified),
                error.message.clone(),
            )
        });
        let completion = match &result {
            Ok(()) => Ok(PeerState::Online),
            Err(error) => Err(core_error_for_attempt(error)),
        };

        // Take the task lease before completing the generation.  This closes
        // the race where a new intent could observe Offline and start while
        // the previous child is still counted as active.
        let Some(task_owned) = self.take_connection_task(generation, attempt_id) else {
            // This attempt was superseded within the same generation.  A
            // generation guard alone is insufficient when a stronger demand
            // replaces a weaker attempt without creating a new generation.
            return;
        };
        let attempt_requirement = task_owned.requirement;
        drop(task_owned);
        self.mark_child_finished();

        // `complete_ready` performs the generation/stopping check.  Do not add
        // a session id, route id, or connection-store check here: a late
        // result is stale when its intent generation or attempt token is no
        // longer current.
        if self
            .complete_ready(generation, attempt_requirement, completion)
            .is_ok()
        {
            if let Some((code, message)) = failure {
                emit_peer_state(
                    &state.event_tx,
                    self.peer_id.as_str(),
                    PeerConnectionState::Failed,
                    RouteType::Unspecified,
                    Some(protocol_error_with_peer(
                        code,
                        message,
                        "connect",
                        self.peer_id.as_str(),
                    )),
                );
            }
        }
    }

    fn complete_attempt_without_task(
        &self,
        generation: IntentGeneration,
        completion: Result<PeerState, CoreNetworkError>,
        child_started: bool,
    ) {
        if child_started {
            self.mark_child_finished();
        }
        let _ = self.complete(generation, completion);
    }
}
