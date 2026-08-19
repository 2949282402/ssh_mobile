//! Per-peer intent coordination for the transport-network v2 core slice.
//!
//! The legacy runtime stores a number of transport objects in maps keyed by a
//! string peer id.  This module provides the smaller ownership boundary that
//! new lifecycle code can use while those older owners are migrated: one
//! validated [`PeerId`] owns one bounded mailbox, one intent generation, and
//! one bounded set of completion waiters.

use network_protocol::CommunicationClass;
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
    generation: IntentGeneration,
    sender: oneshot::Sender<PeerCompletion>,
}

struct PeerInner {
    state: PeerState,
    generation: IntentGeneration,
    stopping: bool,
    waiters: HashMap<String, Waiter>,
    resources: usize,
    maintain_connection: bool,
    active_children: usize,
    retry_scheduled: bool,
    business_work: usize,
    configured: bool,
}

/// One peer's bounded lifecycle coordinator.
pub(crate) struct PeerSupervisor {
    peer_id: PeerId,
    mailbox_tx: mpsc::Sender<PeerIntent>,
    mailbox_rx: Mutex<Option<mpsc::Receiver<PeerIntent>>>,
    inner: Mutex<PeerInner>,
    connection_task: Mutex<Option<TaskLease>>,
    next_resource_id: AtomicU64,
}

impl PeerSupervisor {
    pub(crate) fn new(peer_id: PeerId) -> Arc<Self> {
        let (mailbox_tx, mailbox_rx) = mpsc::channel(PEER_MAILBOX_CAPACITY);
        Arc::new(Self {
            peer_id,
            mailbox_tx,
            mailbox_rx: Mutex::new(Some(mailbox_rx)),
            inner: Mutex::new(PeerInner {
                state: PeerState::Offline,
                generation: IntentGeneration::INITIAL,
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

    /// Start the sole transport establishment owned by this peer supervisor.
    ///
    /// Command dispatch submits an intent here rather than creating a second
    /// per-peer connectivity owner.  The bounded mailbox remains the intent
    /// hand-off/serialization point, while this method owns the supervised
    /// `ConnectivityAttemptCoordinator` task and its generation completion.
    pub(crate) fn start_connect(
        self: &Arc<Self>,
        state: Arc<RuntimeState>,
        command_id: String,
        class: CommunicationClass,
    ) -> Result<PeerConnectIntent, CoreNetworkError> {
        let intent = self.begin_connect(&command_id, class)?;
        if !intent.is_new {
            return Ok(intent);
        }

        let generation = intent.generation;
        if let Err(error) = self.mark_child_started() {
            let _ = self.complete(generation, Err(error.clone()));
            return Err(error);
        }
        let supervisor = Arc::clone(self);
        let task_peer_id = self.peer_id.as_str().to_string();
        let task_supervisor = Arc::clone(&state.task_supervisor);
        let task_state = Arc::clone(&state);
        let task_lease = task_supervisor.spawn_session_controlled(
            format!("peer-connect/{task_peer_id}"),
            "peer-connect",
            async move {
                let attempt_coordinator =
                    crate::connect::ConnectivityAttemptCoordinator::new(Arc::clone(&task_state));
                match attempt_coordinator
                    .connect_with_class(&task_peer_id, class)
                    .await
                {
                    Ok(()) => {
                        if supervisor.is_current(generation) {
                            let _ = supervisor.complete(generation, Ok(PeerState::Online));
                        }
                    }
                    Err(error) => {
                        if supervisor.is_current(generation) {
                            let _ =
                                supervisor.complete(generation, Err(CoreNetworkError::Cancelled));
                            let code = NetworkErrorCode::try_from(error.code)
                                .unwrap_or(NetworkErrorCode::Unspecified);
                            emit_peer_state(
                                &task_state.event_tx,
                                &task_peer_id,
                                PeerConnectionState::Failed,
                                RouteType::Unspecified,
                                Some(protocol_error_with_peer(
                                    code,
                                    error.message,
                                    "connect",
                                    &task_peer_id,
                                )),
                            );
                        }
                    }
                }
                supervisor.mark_child_finished();
            },
        );
        let Some(task_lease) = task_lease else {
            self.mark_child_finished();
            let _ = self.complete(generation, Err(CoreNetworkError::SupervisorStopping));
            return Err(CoreNetworkError::SupervisorStopping);
        };
        self.connection_task
            .lock()
            .expect("peer connection task lock")
            .replace(task_lease);
        Ok(intent)
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

        let (generation, is_new, receiver) = {
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
            if inner.state == PeerState::Online {
                sender
                    .send(Ok(PeerState::Online))
                    .expect("newly-created peer waiter receiver exists");
                return Ok(PeerConnectIntent {
                    generation: inner.generation,
                    is_new: false,
                    completion: receiver,
                });
            }

            let is_new = inner.state != PeerState::Connecting;
            if is_new {
                inner.generation = inner.generation.next();
                inner.state = PeerState::Connecting;
            }
            let generation = inner.generation;
            inner
                .waiters
                .insert(command_id.to_string(), Waiter { generation, sender });
            (generation, is_new, receiver)
        };

        if is_new {
            let intent = PeerIntent { generation, class };
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

    /// Complete exactly the current generation and wake every joined waiter.
    pub(crate) fn complete(
        &self,
        generation: IntentGeneration,
        result: PeerCompletion,
    ) -> Result<usize, CoreNetworkError> {
        let (waiters, delivered) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            if inner.stopping || inner.generation != generation {
                return Err(CoreNetworkError::StaleIntent);
            }
            inner.state = match &result {
                Ok(state) => *state,
                Err(_) => PeerState::Offline,
            };
            let waiters = inner
                .waiters
                .drain()
                .filter(|(_, waiter)| waiter.generation == generation)
                .map(|(_, waiter)| waiter.sender)
                .collect::<Vec<_>>();
            let delivered = waiters.len();
            (waiters, delivered)
        };

        for waiter in waiters {
            let _ = waiter.send(result.clone());
        }
        Ok(delivered)
    }

    /// Invalidate all current work and wake its waiters before the peer is
    /// removed from the active graph.
    pub(crate) fn disconnect(&self) -> usize {
        self.cancel_connection_task();
        let (waiters, delivered) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            inner.generation = inner.generation.next();
            inner.state = PeerState::Offline;
            inner.maintain_connection = false;
            let waiters = inner
                .waiters
                .drain()
                .map(|(_, waiter)| waiter.sender)
                .collect::<Vec<_>>();
            let delivered = waiters.len();
            (waiters, delivered)
        };
        for waiter in waiters {
            let _ = waiter.send(Err(CoreNetworkError::Cancelled));
        }
        delivered
    }

    pub(crate) fn stop(&self) -> usize {
        self.cancel_connection_task();
        let (waiters, delivered) = {
            let mut inner = self.inner.lock().expect("peer supervisor lock");
            inner.stopping = true;
            inner.generation = inner.generation.next();
            inner.state = PeerState::Offline;
            inner.maintain_connection = false;
            let waiters = inner
                .waiters
                .drain()
                .map(|(_, waiter)| waiter.sender)
                .collect::<Vec<_>>();
            let delivered = waiters.len();
            (waiters, delivered)
        };
        for waiter in waiters {
            let _ = waiter.send(Err(CoreNetworkError::SupervisorStopping));
        }
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
        if !authenticated {
            return Err(CoreNetworkError::Cancelled);
        }
        let mut inner = self.inner.lock().expect("peer supervisor lock");
        if inner.stopping {
            return Err(CoreNetworkError::SupervisorStopping);
        }
        inner.state = PeerState::Online;
        Ok(inner.state)
    }

    /// Path loss is a lifecycle observation, not a transport/session truth
    /// leak. Passive peers go Offline; maintained peers remain Offline until a
    /// bounded, explicit recovery trigger starts a new intent.
    pub(crate) fn path_lost(&self) {
        self.cancel_connection_task();
        self.inner.lock().expect("peer supervisor lock").state = PeerState::Offline;
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
            task.abort_now();
            self.mark_child_finished();
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
}

/// Registry that creates exactly one supervisor for each validated peer id.
pub(crate) struct PeerSupervisorRegistry {
    supervisors: RwLock<HashMap<PeerId, Arc<PeerSupervisor>>>,
    task_supervisor: Option<Arc<RuntimeTaskSupervisor>>,
}

impl Default for PeerSupervisorRegistry {
    fn default() -> Self {
        Self {
            supervisors: RwLock::new(HashMap::new()),
            task_supervisor: None,
        }
    }
}

impl PeerSupervisorRegistry {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Runtime construction opts into a supervised mailbox consumer. The
    /// plain `new()` constructor remains available for unit tests that take
    /// the receiver themselves.
    pub(crate) fn with_task_supervisor(task_supervisor: Arc<RuntimeTaskSupervisor>) -> Self {
        Self {
            supervisors: RwLock::new(HashMap::new()),
            task_supervisor: Some(task_supervisor),
        }
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
                supervisors.remove(&evict_peer);
            } else {
                return Err(CoreNetworkError::ResourceLimit("peer supervisors"));
            }
        }

        let supervisor = PeerSupervisor::new(peer_id.clone());
        supervisor.set_configured(configured);
        if let Some(task_supervisor) = &self.task_supervisor {
            let receiver = supervisor
                .take_mailbox()
                .ok_or(CoreNetworkError::SupervisorStopping)?;
            let worker_supervisor = Arc::clone(&supervisor);
            task_supervisor
                .spawn_runtime(format!("peer-mailbox/{}", peer_id.as_str()), async move {
                    let mut receiver = receiver;
                    while let Some(intent) = receiver.recv().await {
                        // The transport child owns the actual attempt. The
                        // mailbox worker only drains bounded coordination
                        // intents and drops late generations.
                        if !worker_supervisor.is_current(intent.generation) {
                            continue;
                        }
                    }
                })
                .ok_or(CoreNetworkError::SupervisorStopping)?;
        }
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
mod tests {
    use super::*;

    fn supervisor() -> Arc<PeerSupervisor> {
        PeerSupervisor::new(PeerId::new("peer-a").expect("peer id"))
    }

    #[test]
    fn peer_ids_are_validated_and_isolated() {
        assert!(PeerId::new("").is_err());
        assert!(PeerId::new("x".repeat(129).as_str()).is_err());
        let registry = PeerSupervisorRegistry::new();
        let first = registry.get_or_create("peer-a").expect("first supervisor");
        let second = registry.get_or_create("peer-b").expect("second supervisor");
        assert!(!Arc::ptr_eq(&first, &second));
        assert_eq!(registry.len(), 2);
    }

    #[tokio::test]
    async fn concurrent_connects_share_one_generation_and_completion() {
        let supervisor = supervisor();
        let first = supervisor
            .begin_connect("command-1", CommunicationClass::ReliableMessage)
            .expect("first intent");
        let second = supervisor
            .begin_connect("command-2", CommunicationClass::ReliableStream)
            .expect("joined intent");
        assert!(first.is_new);
        assert!(!second.is_new);
        assert_eq!(first.generation, second.generation);
        assert_eq!(supervisor.waiter_count(), 2);
        assert_eq!(
            supervisor
                .take_mailbox()
                .expect("mailbox")
                .recv()
                .await
                .unwrap()
                .generation,
            first.generation
        );
        assert_eq!(
            supervisor
                .complete(first.generation, Ok(PeerState::Online))
                .expect("complete"),
            2
        );
        assert_eq!(
            first.completion().await.expect("first waiter"),
            Ok(PeerState::Online)
        );
        assert_eq!(
            second.completion().await.expect("second waiter"),
            Ok(PeerState::Online)
        );
        assert_eq!(supervisor.state(), PeerState::Online);
    }

    #[test]
    fn business_ensure_does_not_enable_maintenance_but_connect_does() {
        let supervisor = supervisor();
        let business = supervisor
            .ensure("business-1", CommunicationClass::ReliableMessage)
            .expect("ensure");
        assert!(!supervisor.maintain_connection());
        supervisor.disconnect();
        business.detach_completion();

        let connect = supervisor
            .begin_connect("connect-1", CommunicationClass::ReliableMessage)
            .expect("connect");
        assert!(supervisor.maintain_connection());
        connect.detach_completion();
    }

    #[test]
    fn passive_inbound_does_not_enable_maintenance_or_recovery() {
        let supervisor = supervisor();
        assert!(supervisor.admit_inbound(false).is_err());
        assert_eq!(
            supervisor.admit_inbound(true).expect("trusted inbound"),
            PeerState::Online
        );
        assert!(!supervisor.maintain_connection());
        supervisor.path_lost();
        assert_eq!(supervisor.state(), PeerState::Offline);
    }

    #[test]
    fn stale_completion_cannot_change_a_new_generation() {
        let supervisor = supervisor();
        let first = supervisor
            .begin_connect("command-1", CommunicationClass::ReliableMessage)
            .expect("first intent");
        supervisor.disconnect();
        assert_eq!(
            supervisor.complete(first.generation, Ok(PeerState::Online)),
            Err(CoreNetworkError::StaleIntent)
        );
        assert_eq!(supervisor.state(), PeerState::Offline);
    }

    #[tokio::test]
    async fn mailbox_and_resource_limits_are_bounded() {
        let closed_supervisor = supervisor();
        let receiver = closed_supervisor.take_mailbox().expect("mailbox");
        drop(receiver);
        assert!(matches!(
            closed_supervisor.begin_connect("command-1", CommunicationClass::ReliableMessage),
            Err(CoreNetworkError::SupervisorStopping)
        ));

        let supervisor = supervisor();
        let mut leases = Vec::new();
        for _ in 0..MAX_PEER_RESOURCES {
            leases.push(supervisor.acquire_resource().expect("resource lease"));
        }
        assert!(matches!(
            supervisor.acquire_resource(),
            Err(CoreNetworkError::ResourceLimit("peer resources"))
        ));
        drop(leases);
        assert!(supervisor.acquire_resource().is_ok());
    }

    #[test]
    fn eviction_requires_offline_and_no_owned_work() {
        let registry = PeerSupervisorRegistry::new();
        registry.get_or_create("peer-a").expect("supervisor");
        assert!(registry.remove_if_evictable("peer-a").expect("evict"));

        let retained = registry.get_or_create("peer-b").expect("supervisor");
        let intent = retained
            .begin_connect("command-1", CommunicationClass::ReliableMessage)
            .expect("connect");
        assert!(!registry.remove_if_evictable("peer-b").expect("evict check"));
        retained.disconnect();
        intent.detach_completion();
        assert!(registry.remove_if_evictable("peer-b").expect("evict"));
    }

    #[tokio::test]
    async fn supervised_registry_drains_repeated_intents_without_filling_mailbox() {
        let task_supervisor = RuntimeTaskSupervisor::new();
        let registry = PeerSupervisorRegistry::with_task_supervisor(Arc::clone(&task_supervisor));
        let supervisor = registry.get_or_create("peer-a").expect("peer supervisor");

        for index in 0..(PEER_MAILBOX_CAPACITY * 2) {
            let command_id = format!("command-{index}");
            let intent = supervisor
                .begin_connect(&command_id, CommunicationClass::ReliableMessage)
                .expect("mailbox consumer keeps up");
            assert!(intent.is_new);
            assert_eq!(
                supervisor.complete(intent.generation, Err(CoreNetworkError::Cancelled),),
                Ok(1)
            );
            assert_eq!(
                intent.completion().await.expect("completion"),
                Err(CoreNetworkError::Cancelled)
            );
            tokio::task::yield_now().await;
        }

        task_supervisor.shutdown().await;
    }
}
