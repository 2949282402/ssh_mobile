//! Capability-aware connect intent admission and completion.

use super::*;

impl PeerSupervisor {
    /// Start or join the current connect intent for this peer.
    pub(crate) fn begin_connect(
        &self,
        command_id: &str,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        self.begin_connect_with_policy(command_id, class, true)
    }

    /// Business operations ensure a compatible path without opting into
    /// long-lived reconnect maintenance.
    pub(crate) fn ensure(
        &self,
        command_id: &str,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        self.begin_connect_with_policy(command_id, class, false)
    }

    fn begin_connect_with_policy(
        &self,
        command_id: &str,
        class: CommunicationClass,
        maintain_connection: bool,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        if command_id.is_empty() || command_id.len() > 128 {
            return Err(CoreNetworkError::InvalidCommandId);
        }

        let requirement = PeerRequirement::from_class(class);
        let (generation, is_new, queue_intent, receiver) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if inner.stopping {
                return Err(CoreNetworkError::SupervisorStopping);
            }
            if maintain_connection {
                inner.maintain_connection = true;
            }
            if inner.waiters.contains_key(command_id) {
                return Err(CoreNetworkError::DuplicateCommand);
            }
            if inner.waiters.len() >= MAX_PEER_WAITERS {
                return Err(CoreNetworkError::ResourceLimit("peer waiters"));
            }

            let (sender, receiver) = oneshot::channel();
            if inner
                .ready_requirement
                .is_some_and(|ready| requirement.is_satisfied_by(ready))
            {
                sender
                    .send(Ok(PeerState::Online))
                    .expect("newly-created peer waiter receiver exists");
                return Ok(PeerConnectIntent {
                    generation: inner.generation,
                    is_new: false,
                    completion: receiver,
                });
            }
            if inner.state == PeerState::Online {
                let ready_requirement = inner
                    .ready_requirement
                    .or(inner.active_requirement)
                    .unwrap_or(PeerRequirement::from_class(class));
                if requirement.is_satisfied_by(ready_requirement) {
                    sender
                        .send(Ok(PeerState::Online))
                        .expect("newly-created peer waiter receiver exists");
                    return Ok(PeerConnectIntent {
                        generation: inner.generation,
                        is_new: false,
                        completion: receiver,
                    });
                }
            }

            // A healthy weaker path cannot complete a stronger demand.  Keep
            // the supervisor as the sole owner and start a fresh attempt
            // generation for the stronger requirement.
            let mut is_new = false;
            let queue_intent = if inner.state != PeerState::Connecting {
                inner.generation = inner.generation.next();
                inner.state = PeerState::Connecting;
                inner.active_requirement = Some(requirement);
                inner.ready_requirement = None;
                inner.retry_scheduled = true;
                is_new = true;
                true
            } else {
                let active_requirement = inner
                    .active_requirement
                    .unwrap_or_else(|| PeerRequirement::from_class(class));
                let combined_requirement = active_requirement.extend(requirement);
                let changed = combined_requirement != active_requirement;
                if changed {
                    inner.active_requirement = Some(combined_requirement);
                }
                // An intent already waiting in the mailbox will observe the
                // extended active requirement.  Only enqueue another intent
                // when the current attempt is already running.
                changed && !inner.retry_scheduled
            };
            let generation = inner.generation;
            if queue_intent {
                inner.retry_scheduled = true;
            }
            inner.waiters.insert(
                command_id.to_string(),
                Waiter {
                    command_id: command_id.to_string(),
                    generation,
                    requirement,
                    sender,
                },
            );
            (generation, is_new, queue_intent, receiver)
        };

        if queue_intent {
            let active_requirement = self
                .inner
                .lock()
                .expect("peer supervisor lock")
                .active_requirement
                .unwrap_or(requirement);
            let intent = PeerIntent {
                generation,
                class: active_requirement.communication_class(),
                required_capabilities: active_requirement.capability_mask(),
                command_id: command_id.to_string(),
            };
            if let Err(error) = self.mailbox_tx.try_send(intent) {
                let reason = match error {
                    mpsc::error::TrySendError::Full(_) => CoreNetworkError::MailboxFull,
                    mpsc::error::TrySendError::Closed(_) => CoreNetworkError::SupervisorStopping,
                };
                self.fail_generation(generation, reason.clone());
                return Err(reason);
            }
        }

        Ok(PeerConnectIntent {
            generation,
            is_new,
            completion: receiver,
        })
    }

    /// Complete exactly the current generation, evaluating each waiter against
    /// the capability of the Ready path rather than broadcasting success.
    pub(crate) fn complete(
        &self,
        generation: IntentGeneration,
        result: PeerCompletion,
    ) -> Result<usize, CoreNetworkError> {
        let ready_requirement = self
            .inner
            .lock()
            .expect("peer supervisor lock")
            .active_requirement
            .unwrap_or(PeerRequirement::from_class(
                CommunicationClass::ReliableMessage,
            ));
        self.complete_ready(generation, ready_requirement, result)
    }

    pub(crate) fn complete_ready(
        &self,
        generation: IntentGeneration,
        ready_requirement: PeerRequirement,
        result: PeerCompletion,
    ) -> Result<usize, CoreNetworkError> {
        let (waiters, delivered, retry_intent) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if inner.stopping || inner.generation != generation {
                return Err(CoreNetworkError::StaleIntent);
            }

            match &result {
                Err(_) => {
                    inner.state = PeerState::Offline;
                    inner.active_requirement = None;
                    inner.ready_requirement = None;
                    inner.retry_scheduled = false;
                    let waiters = inner
                        .waiters
                        .drain()
                        .filter(|(_, waiter)| waiter.generation == generation)
                        .map(|(_, waiter)| waiter.sender)
                        .collect::<Vec<_>>();
                    let delivered = waiters.len();
                    (waiters, delivered, None)
                }
                Ok(state) => {
                    inner.ready_requirement = Some(ready_requirement);
                    let mut pending = HashMap::new();
                    let mut waiters = Vec::new();
                    for (command_id, waiter) in inner.waiters.drain() {
                        if waiter.generation == generation
                            && waiter.requirement.is_satisfied_by(ready_requirement)
                        {
                            waiters.push(waiter.sender);
                        } else {
                            pending.insert(command_id, waiter);
                        }
                    }
                    inner.waiters = pending;
                    let pending_current = inner
                        .waiters
                        .values()
                        .any(|waiter| waiter.generation == generation);
                    if pending_current {
                        inner.state = PeerState::Connecting;
                        let should_queue = !inner.retry_scheduled;
                        inner.retry_scheduled = true;
                        let retry_requirement =
                            inner.active_requirement.unwrap_or(ready_requirement);
                        let delivered = waiters.len();
                        let retry_intent = should_queue.then_some(PeerIntent {
                            generation,
                            class: retry_requirement.communication_class(),
                            required_capabilities: retry_requirement.capability_mask(),
                            command_id: inner
                                .waiters
                                .values()
                                .next()
                                .map(|waiter| waiter.command_id.clone())
                                .unwrap_or_default(),
                        });
                        (waiters, delivered, retry_intent)
                    } else {
                        inner.state = *state;
                        inner.active_requirement = Some(ready_requirement);
                        inner.retry_scheduled = false;
                        let delivered = waiters.len();
                        (waiters, delivered, None)
                    }
                }
            }
        };

        for waiter in waiters {
            let _ = waiter.send(result.clone());
        }

        if let Some(intent) = retry_intent {
            if let Err(error) = self.mailbox_tx.try_send(intent) {
                let reason = match error {
                    mpsc::error::TrySendError::Full(_) => CoreNetworkError::MailboxFull,
                    mpsc::error::TrySendError::Closed(_) => CoreNetworkError::SupervisorStopping,
                };
                self.fail_generation(generation, reason.clone());
                return Err(reason);
            }
        }
        Ok(delivered)
    }
}
