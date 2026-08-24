//! Per-peer lifecycle ownership for the transport-network v2 core.
//!
//! One validated [`PeerId`] owns one bounded mailbox, one intent generation,
//! one connectivity-attempt worker, and one bounded set of completion waiters.
//! Transport and path observations are reported here; they do not become a
//! second lifecycle state machine in the connection-session store.

use network_protocol::{CommunicationClass, NetworkError as ProtocolError};
use std::collections::HashMap;
use std::fmt;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, RwLock,
};
use tokio::sync::{mpsc, oneshot};

use crate::errors::CoreNetworkError;
use crate::events::{emit_peer_state, protocol_error_with_peer};
use crate::runtime::RuntimeState;
use crate::task_supervisor::{RuntimeTaskSupervisor, TaskLease};
use network_protocol::{NetworkErrorCode, PeerConnectionState, RouteType};

/// Maximum number of physical intents waiting behind one peer supervisor.
pub(crate) const PEER_MAILBOX_CAPACITY: usize = 32;
/// Maximum number of callers waiting for one peer's current intent.
pub(crate) const MAX_PEER_WAITERS: usize = 64;
/// Maximum number of peer-owned resource reservations.
pub(crate) const MAX_PEER_RESOURCES: usize = 64;

/// Stable, validated identity used as a key by the v2 peer-owned stores.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(crate) struct PeerId(Arc<str>);

impl PeerId {
    pub(crate) fn new(value: &str) -> Result<Self, CoreNetworkError> {
        let length = value.chars().count();
        if !(1..=128).contains(&length) || value.chars().any(char::is_control) {
            return Err(CoreNetworkError::InvalidPeerId);
        }
        Ok(Self(Arc::<str>::from(value)))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<&str> for PeerId {
    type Error = CoreNetworkError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl TryFrom<String> for PeerId {
    type Error = CoreNetworkError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(&value)
    }
}

impl AsRef<str> for PeerId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for PeerId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Lifecycle state owned by a peer supervisor.
///
/// The frozen wire contract still projects these values to
/// `Disconnected`/`Connecting`/`Connected`; keeping the native state separate
/// prevents a transport failure from becoming a second, global state machine.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PeerState {
    Offline,
    Connecting,
    Online,
}

/// Monotonic generation of a peer intent.  A completion from an older
/// generation is never allowed to mutate the current peer state.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(crate) struct IntentGeneration(u64);

impl IntentGeneration {
    pub(crate) const INITIAL: Self = Self(0);

    pub(crate) fn get(self) -> u64 {
        self.0
    }

    fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PeerIntent {
    pub(crate) generation: IntentGeneration,
    pub(crate) class: CommunicationClass,
    pub(crate) required_capabilities: u8,
}

/// Capability demand carried by a peer-owned connectivity intent.
///
/// Reliable streams also require the reliable-message baseline: a stream-capable
/// route can carry both shapes, while a message-only route cannot satisfy a
/// stream waiter.  Keeping this requirement in the supervisor prevents the
/// Session store from becoming a second capability-union owner.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PeerRequirement(u8);

impl PeerRequirement {
    const RELIABLE_MESSAGE: u8 = super::CAPABILITY_RELIABLE_MESSAGE;
    const RELIABLE_STREAM: u8 = super::CAPABILITY_RELIABLE_STREAM;
    const UNRELIABLE_DATAGRAM: u8 = super::CAPABILITY_UNRELIABLE_DATAGRAM;

    fn from_class(class: CommunicationClass) -> Self {
        let class = super::default_communication_class(class);
        let capabilities = match class {
            CommunicationClass::ReliableStream | CommunicationClass::BulkTransfer => {
                Self::RELIABLE_MESSAGE | Self::RELIABLE_STREAM
            }
            CommunicationClass::ReliableMessage => Self::RELIABLE_MESSAGE,
            CommunicationClass::UnreliableDatagram => Self::UNRELIABLE_DATAGRAM,
            CommunicationClass::RealtimeMedia | CommunicationClass::Unspecified => {
                super::DEFAULT_CONNECTION_CAPABILITY
            }
        };
        Self(capabilities)
    }

    fn from_capability_mask(mask: u8) -> Self {
        Self(mask & (Self::RELIABLE_MESSAGE | Self::RELIABLE_STREAM | Self::UNRELIABLE_DATAGRAM))
    }

    fn is_satisfied_by(self, provided: Self) -> bool {
        provided.0 & self.0 == self.0
    }

    fn extend(self, requested: Self) -> Self {
        Self(self.0 | requested.0)
    }

    fn capability_mask(self) -> u8 {
        self.0
    }

    fn communication_class(self) -> CommunicationClass {
        if self.0 & Self::RELIABLE_STREAM != 0 {
            CommunicationClass::ReliableStream
        } else if self.0 & Self::UNRELIABLE_DATAGRAM != 0 {
            CommunicationClass::UnreliableDatagram
        } else {
            CommunicationClass::ReliableMessage
        }
    }
}

/// A connect request's native completion waiter.
pub(crate) type PeerCompletion = Result<PeerState, CoreNetworkError>;

/// The result of submitting a connect intent.
pub(crate) struct PeerConnectIntent {
    pub(crate) generation: IntentGeneration,
    pub(crate) is_new: bool,
    completion: oneshot::Receiver<PeerCompletion>,
}

impl PeerConnectIntent {
    /// Detach a command-level caller from the native lifecycle waiter.  The
    /// command result remains queue-level; internal callers may retain it.
    pub(crate) fn detach_completion(self) {
        drop(self.completion);
    }

    pub(crate) fn completion(self) -> oneshot::Receiver<PeerCompletion> {
        self.completion
    }
}

struct Waiter {
    command_id: String,
    generation: IntentGeneration,
    requirement: PeerRequirement,
    sender: oneshot::Sender<PeerCompletion>,
}

struct PeerInner {
    state: PeerState,
    generation: IntentGeneration,
    active_requirement: Option<PeerRequirement>,
    ready_requirement: Option<PeerRequirement>,
    stopping: bool,
    waiters: HashMap<String, Waiter>,
    resources: usize,
    maintain_connection: bool,
    active_children: usize,
    retry_scheduled: bool,
    business_work: usize,
    configured: bool,
}

struct ConnectionTask {
    generation: IntentGeneration,
    attempt_id: u64,
    requirement: PeerRequirement,
    lease: TaskLease,
}

fn core_error_for_attempt(error: &ProtocolError) -> CoreNetworkError {
    match NetworkErrorCode::try_from(error.code).unwrap_or(NetworkErrorCode::Unspecified) {
        NetworkErrorCode::NoRoute
        | NetworkErrorCode::PeerOffline
        | NetworkErrorCode::PeerNotReady => CoreNetworkError::NoRoute,
        NetworkErrorCode::Cancelled => CoreNetworkError::Cancelled,
        _ => CoreNetworkError::Cancelled,
    }
}

/// One peer's bounded lifecycle coordinator.
pub(crate) struct PeerSupervisor {
    peer_id: PeerId,
    mailbox_tx: mpsc::Sender<PeerIntent>,
    mailbox_rx: Mutex<Option<mpsc::Receiver<PeerIntent>>>,
    mailbox_task: Mutex<Option<TaskLease>>,
    inner: Mutex<PeerInner>,
    connection_task: Mutex<Option<ConnectionTask>>,
    next_resource_id: AtomicU64,
    next_attempt_id: AtomicU64,
}

impl PeerSupervisor {
    pub(crate) fn new(peer_id: PeerId) -> Arc<Self> {
        let (mailbox_tx, mailbox_rx) = mpsc::channel(PEER_MAILBOX_CAPACITY);
        Arc::new(Self {
            peer_id,
            mailbox_tx,
            mailbox_rx: Mutex::new(Some(mailbox_rx)),
            mailbox_task: Mutex::new(None),
            inner: Mutex::new(PeerInner {
                state: PeerState::Offline,
                generation: IntentGeneration::INITIAL,
                active_requirement: None,
                ready_requirement: None,
                stopping: false,
                waiters: HashMap::new(),
                resources: 0,
                maintain_connection: false,
                active_children: 0,
                retry_scheduled: false,
                business_work: 0,
                configured: false,
            }),
            connection_task: Mutex::new(None),
            next_resource_id: AtomicU64::new(1),
            next_attempt_id: AtomicU64::new(1),
        })
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn state(&self) -> PeerState {
        self.inner.lock().expect("peer supervisor lock").state
    }

    pub(crate) fn generation(&self) -> IntentGeneration {
        self.inner.lock().expect("peer supervisor lock").generation
    }

    pub(crate) fn is_current(&self, generation: IntentGeneration) -> bool {
        let inner = self.inner.lock().expect("peer supervisor lock");
        !inner.stopping && inner.generation == generation
    }

    /// Take the only mailbox receiver.  The receiver belongs to the peer
    /// worker; callers cannot manufacture a second consumer for this peer.
    pub(crate) fn take_mailbox(&self) -> Option<mpsc::Receiver<PeerIntent>> {
        self.mailbox_rx.lock().expect("peer mailbox lock").take()
    }

    /// Start or join the current connect intent for this peer.
    pub(crate) fn begin_connect(
        &self,
        command_id: &str,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        self.begin_connect_with_policy(command_id, class, true)
    }

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
                    .connect_with_capabilities(&peer_id, attempt_requirement.capability_mask())
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

    fn complete_ready(
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

    fn release_resource(&self, _resource_id: u64) {
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        inner.resources = inner.resources.saturating_sub(1);
    }

    fn fail_generation(&self, generation: IntentGeneration, error: CoreNetworkError) {
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
        self.admit_inbound_with_capabilities(authenticated, super::DEFAULT_CONNECTION_CAPABILITY)
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
    fn cancel_connection_task(&self) {
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

    fn cancel_connection_task_for(&self, generation: IntentGeneration) {
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

    fn take_connection_task(
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

    fn is_configured(&self) -> bool {
        self.inner.lock().expect("peer supervisor lock").configured
    }

    #[cfg(test)]
    fn waiter_count(&self) -> usize {
        self.inner
            .lock()
            .expect("peer supervisor lock")
            .waiters
            .len()
    }

    #[cfg(test)]
    fn active_requirement(&self) -> Option<PeerRequirement> {
        self.inner
            .lock()
            .expect("peer supervisor lock")
            .active_requirement
    }
}

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
                        >= super::MAX_CONFIGURED_PEERS
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
                        >= super::MAX_CONFIGURED_PEERS
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
                >= super::MAX_CONFIGURED_PEERS
        {
            return Err(CoreNetworkError::ResourceLimit("configured peers"));
        }
        if supervisors.len() >= super::MAX_CONFIGURED_PEERS {
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
            if active_peers >= super::MAX_ACTIVE_PEERS {
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

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.supervisors
            .read()
            .expect("peer supervisor registry lock")
            .len()
    }
}

/// An owning reservation for one peer-scoped resource.
pub(crate) struct PeerResourceLease {
    supervisor: Arc<PeerSupervisor>,
    resource_id: u64,
}

impl Drop for PeerResourceLease {
    fn drop(&mut self) {
        self.supervisor.release_resource(self.resource_id);
    }
}

#[cfg(test)]
#[path = "../tests/connect/peer_supervisor.rs"]
mod tests;
