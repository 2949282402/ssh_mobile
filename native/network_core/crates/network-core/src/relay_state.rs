//! Runtime-owned Relay control/data/transfer state.

use std::collections::{HashMap, HashSet};
use std::sync::{atomic::AtomicBool, Arc, Mutex};
use tokio::sync::{mpsc, oneshot, Mutex as AsyncMutex, RwLock};

use crate::crypto_handshake::{RelayResponderConfirmation, RelayResponderHandshake};
use crate::relay::{
    ActiveRelayIncoming, PendingRelayIncoming, RelayAcceptance, RelayReconnectConfig,
};
use crate::runtime::ConnectionAdmissionLease;
use crate::task_supervisor::TaskId;

type RelayCryptoWaiter = mpsc::Sender<(u8, Vec<u8>)>;

/// Relay control-plane, authenticated path, and reservation transfer state.
///
/// The Runtime root owns this aggregate, while Relay adapters borrow the
/// Runtime's identity, path, crypto, and event services explicitly.
pub(crate) struct RelayDomainState {
    pub(crate) config: RwLock<Option<RelayReconnectConfig>>,
    pub(crate) reconnect_task: Mutex<Option<TaskId>>,
    pub(crate) reconnect_active: AtomicBool,
    pub(crate) credential_stale: AtomicBool,
    pub(crate) control: RwLock<Option<Arc<dyn crate::discovery::DiscoveryControlPlane>>>,
    pub(crate) crypto_waiters: RwLock<HashMap<String, RelayCryptoWaiter>>,
    pub(crate) crypto_responders: AsyncMutex<HashMap<String, RelayResponderHandshake>>,
    pub(crate) crypto_confirmers:
        AsyncMutex<HashMap<String, RelayResponderConfirmation<ConnectionAdmissionLease>>>,
    pub(crate) relay_path_ready: RwLock<HashSet<String>>,
    pub(crate) pending_incoming: RwLock<HashMap<String, PendingRelayIncoming>>,
    pub(crate) active_incoming: AsyncMutex<HashMap<String, ActiveRelayIncoming>>,
    pub(crate) acceptances: RwLock<HashMap<String, oneshot::Sender<Option<RelayAcceptance>>>>,
    pub(crate) completions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
}

impl RelayDomainState {
    pub(crate) fn new() -> Self {
        Self {
            config: RwLock::new(None),
            reconnect_task: Mutex::new(None),
            reconnect_active: AtomicBool::new(false),
            credential_stale: AtomicBool::new(false),
            control: RwLock::new(None),
            crypto_waiters: RwLock::new(HashMap::new()),
            crypto_responders: AsyncMutex::new(HashMap::new()),
            crypto_confirmers: AsyncMutex::new(HashMap::new()),
            relay_path_ready: RwLock::new(HashSet::new()),
            pending_incoming: RwLock::new(HashMap::new()),
            active_incoming: AsyncMutex::new(HashMap::new()),
            acceptances: RwLock::new(HashMap::new()),
            completions: RwLock::new(HashMap::new()),
        }
    }
}
