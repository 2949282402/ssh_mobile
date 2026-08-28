//! Per-peer lifecycle ownership for the transport-network v2 core.
//!
//! One validated PeerId owns one bounded mailbox, one intent generation,
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

mod attempts;
mod intents;
mod lifecycle;
mod registry;
mod resource;

pub(crate) use registry::PeerSupervisorRegistry;
pub(crate) use resource::PeerResourceLease;

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
    pub(crate) command_id: String,
}

/// Capability demand carried by a peer-owned connectivity intent.
///
/// Reliable streams also require the reliable-message baseline: a stream-capable
/// route can carry both shapes, while a message-only route cannot satisfy a
/// stream waiter.  Keeping this requirement in the supervisor prevents the
/// Session store from becoming a second capability-union owner.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PeerRequirement(u8);

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

pub(crate) struct ConnectionTask {
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

    /// Take the only mailbox receiver. The receiver belongs to the peer worker;
    /// callers cannot manufacture a second consumer for this peer.
    pub(crate) fn take_mailbox(&self) -> Option<mpsc::Receiver<PeerIntent>> {
        self.mailbox_rx.lock().expect("peer mailbox lock").take()
    }
}

#[cfg(test)]
#[path = "../tests/connect/peer_supervisor.rs"]
mod tests;
