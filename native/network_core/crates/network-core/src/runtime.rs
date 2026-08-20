//! V2 网络运行时生命周期、共享状态与命令/事件通道。

use network_protocol::{network_event, NetworkCommand, NetworkEvent};
use prost::Message;
use std::sync::{
    atomic::{AtomicBool, AtomicU16, AtomicU8, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::runtime::Runtime;
#[cfg(test)]
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{mpsc, oneshot, Mutex as AsyncMutex, Notify, RwLock};
use tracing::info;

use crate::commands::run_command_worker;
use crate::connect::{
    profile_capability_mask, PathHandle, PathProjection, PeerId, PeerPathManager,
};
use crate::crypto::{CryptoContext, CryptoError, SessionCryptoManager};
use crate::crypto_handshake::{
    RelayResponderConfirmation, RelayResponderHandshake, SessionCryptoMaterial,
};
use crate::delivery::DeliveryManager;
use crate::errors::{CoreNetworkError, NetworkError};
use crate::session::{
    ConnectionAdmission, ConnectionAdmissionError, ConnectionAdmissionOutcome,
    ConnectionSessionStore, SessionId,
};
use crate::stream::ReliableStreamManager;
use crate::task_supervisor::{RuntimeTaskSupervisor, TaskId};
use network_identity::DeviceIdentity;
use network_nat::{PathManager, ResolvedCandidateCache};
use network_relay::RelayDataClient;
use network_transfer::TransferManager;
use quinn::Endpoint;
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::path::PathBuf;

pub(crate) const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const RECONNECT_INITIAL_BACKOFF: Duration = Duration::from_millis(250);
pub(crate) const RECONNECT_MAX_BACKOFF: Duration = Duration::from_secs(5);
pub(crate) const INCOMING_APPROVAL_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const TRANSFER_COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const MAX_PENDING_INCOMING_TRANSFERS: usize = 64;
pub(crate) const MAX_PENDING_RELAY_CRYPTO_HANDSHAKES: usize = 64;
pub(crate) const DELIVERY_RETRY_POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Commands are control-plane input and must never grow an unbounded queue.
pub(crate) const COMMAND_MAILBOX_CAPACITY: usize = 256;
/// Native events are split before FFI polling so a data flood cannot block
/// command results, peer state, or relay lifecycle events.
pub(crate) const CONTROL_EVENT_MAILBOX_CAPACITY: usize = 256;
pub(crate) const DATA_EVENT_MAILBOX_CAPACITY: usize = 128;
pub(crate) const MAX_CONTROL_EVENT_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_DATA_EVENT_QUEUE_BYTES: usize = 8 * 1024 * 1024;
/// Compatibility names retained for the contract inventory; the actual
/// limits are enforced independently by the two lanes above.
#[allow(dead_code)]
pub(crate) const EVENT_MAILBOX_CAPACITY: usize = CONTROL_EVENT_MAILBOX_CAPACITY;
#[allow(dead_code)]
pub(crate) const MAX_EVENT_QUEUE_BYTES: usize =
    MAX_CONTROL_EVENT_QUEUE_BYTES + MAX_DATA_EVENT_QUEUE_BYTES;
pub(crate) const MAX_EVENT_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_CONSECUTIVE_CONTROL_EVENTS: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeEventLane {
    Control,
    Data,
}

fn event_lane(event: &NetworkEvent) -> RuntimeEventLane {
    match event.payload.as_ref() {
        Some(network_event::Payload::TransferProgress(_))
        | Some(network_event::Payload::PeerTransferProgress(_))
        | Some(network_event::Payload::ChannelMessage(_))
        | Some(network_event::Payload::SshStreamDataReceived(_)) => RuntimeEventLane::Data,
        _ => RuntimeEventLane::Control,
    }
}

pub(crate) const RUNTIME_CREATED: u8 = 0;
pub(crate) const RUNTIME_RUNNING: u8 = 1;
pub(crate) const RUNTIME_STOPPING: u8 = 2;
pub(crate) const RUNTIME_STOPPED: u8 = 3;

/// A bounded production event sender with an unbounded test adapter.
///
/// The test adapter keeps focused unit tests able to observe events without
/// introducing a second production queue.  `NetworkRuntime::new` always uses
/// the bounded variant below.
#[derive(Clone)]
pub(crate) enum EventSender {
    Bounded {
        control_sender: mpsc::Sender<NetworkEvent>,
        data_sender: mpsc::Sender<NetworkEvent>,
        control_queued_bytes: Arc<AtomicUsize>,
        data_queued_bytes: Arc<AtomicUsize>,
    },
    #[cfg(test)]
    Unbounded(tokio::sync::mpsc::UnboundedSender<NetworkEvent>),
}

pub(crate) struct EventReceiver {
    control_receiver: mpsc::Receiver<NetworkEvent>,
    data_receiver: mpsc::Receiver<NetworkEvent>,
    control_queued_bytes: Arc<AtomicUsize>,
    data_queued_bytes: Arc<AtomicUsize>,
    consecutive_control: usize,
    control_closed: bool,
    data_closed: bool,
}

impl EventSender {
    pub(crate) fn send(&self, event: NetworkEvent) -> Result<(), ()> {
        let bytes = event.encoded_len();
        if bytes > MAX_EVENT_BYTES {
            return Err(());
        }
        match self {
            Self::Bounded {
                control_sender,
                data_sender,
                control_queued_bytes,
                data_queued_bytes,
            } => {
                let (sender, queued_bytes, max_bytes) = match event_lane(&event) {
                    RuntimeEventLane::Control => (
                        control_sender,
                        control_queued_bytes,
                        MAX_CONTROL_EVENT_QUEUE_BYTES,
                    ),
                    RuntimeEventLane::Data => {
                        (data_sender, data_queued_bytes, MAX_DATA_EVENT_QUEUE_BYTES)
                    }
                };
                let mut current = queued_bytes.load(Ordering::Acquire);
                loop {
                    let next = current.saturating_add(bytes);
                    if next > max_bytes {
                        return Err(());
                    }
                    match queued_bytes.compare_exchange_weak(
                        current,
                        next,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    ) {
                        Ok(_) => break,
                        Err(observed) => current = observed,
                    }
                }
                if sender.try_send(event).is_err() {
                    queued_bytes.fetch_sub(bytes, Ordering::AcqRel);
                    return Err(());
                }
                Ok(())
            }
            #[cfg(test)]
            Self::Unbounded(sender) => sender.send(event).map_err(|_| ()),
        }
    }
}

#[cfg(test)]
impl From<UnboundedSender<NetworkEvent>> for EventSender {
    fn from(sender: UnboundedSender<NetworkEvent>) -> Self {
        Self::Unbounded(sender)
    }
}

impl EventReceiver {
    fn release(&self, event: &NetworkEvent) {
        let counter = match event_lane(event) {
            RuntimeEventLane::Control => &self.control_queued_bytes,
            RuntimeEventLane::Data => &self.data_queued_bytes,
        };
        counter.fetch_sub(event.encoded_len(), Ordering::AcqRel);
    }

    fn received(&mut self, event: NetworkEvent) -> NetworkEvent {
        match event_lane(&event) {
            RuntimeEventLane::Control => {
                self.consecutive_control = self.consecutive_control.saturating_add(1);
            }
            RuntimeEventLane::Data => {
                self.consecutive_control = 0;
            }
        }
        self.release(&event);
        event
    }

    fn try_recv(&mut self) -> Option<NetworkEvent> {
        if self.consecutive_control >= MAX_CONSECUTIVE_CONTROL_EVENTS {
            if let Ok(event) = self.data_receiver.try_recv() {
                return Some(self.received(event));
            }
        }
        if let Ok(event) = self.control_receiver.try_recv() {
            return Some(self.received(event));
        }
        self.data_receiver
            .try_recv()
            .ok()
            .map(|event| self.received(event))
    }

    async fn recv(&mut self) -> Option<NetworkEvent> {
        loop {
            if let Some(event) = self.try_recv() {
                return Some(event);
            }
            if self.control_closed && self.data_closed {
                return None;
            }

            let prefer_data = self.consecutive_control >= MAX_CONSECUTIVE_CONTROL_EVENTS;
            let (event, lane) = match (self.control_closed, self.data_closed, prefer_data) {
                (true, false, _) => (self.data_receiver.recv().await, RuntimeEventLane::Data),
                (false, true, _) => (
                    self.control_receiver.recv().await,
                    RuntimeEventLane::Control,
                ),
                (false, false, true) => {
                    tokio::select! {
                        biased;
                        event = self.data_receiver.recv() => (event, RuntimeEventLane::Data),
                        event = self.control_receiver.recv() => (event, RuntimeEventLane::Control),
                    }
                }
                (false, false, false) => {
                    tokio::select! {
                        biased;
                        event = self.control_receiver.recv() => (event, RuntimeEventLane::Control),
                        event = self.data_receiver.recv() => (event, RuntimeEventLane::Data),
                    }
                }
                (true, true, _) => unreachable!(),
            };
            match event {
                Some(event) => return Some(self.received(event)),
                None => match lane {
                    RuntimeEventLane::Control => self.control_closed = true,
                    RuntimeEventLane::Data => self.data_closed = true,
                },
            }
        }
    }
}

fn bounded_event_channel() -> (EventSender, EventReceiver) {
    let (control_sender, control_receiver) = mpsc::channel(CONTROL_EVENT_MAILBOX_CAPACITY);
    let (data_sender, data_receiver) = mpsc::channel(DATA_EVENT_MAILBOX_CAPACITY);
    let control_queued_bytes = Arc::new(AtomicUsize::new(0));
    let data_queued_bytes = Arc::new(AtomicUsize::new(0));
    (
        EventSender::Bounded {
            control_sender,
            data_sender,
            control_queued_bytes: Arc::clone(&control_queued_bytes),
            data_queued_bytes: Arc::clone(&data_queued_bytes),
        },
        EventReceiver {
            control_receiver,
            data_receiver,
            control_queued_bytes,
            data_queued_bytes,
            consecutive_control: 0,
            control_closed: false,
            data_closed: false,
        },
    )
}

/// 一次 authenticated Session admission 的不可变载体。
///
/// transport-network v2（§18）：Session 与 connection 一一对应，被替换的旧 Session
/// 会在 admission 时立即整体销毁（route 关闭 + task group 取消 + 资源 retire），
/// 因此不需要 drop 时机的延迟取消。
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConnectionAdmissionLease {
    admission: ConnectionAdmission,
}

/// Session admission is deliberately separate from Peer lifecycle. This
/// result only tells the attempt whether it owns a fresh SessionId reservation
/// or must observe an already-reserved identity; the PeerSupervisor owns the
/// actual in-flight operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConnectDecision {
    Started(SessionId),
    AlreadyConnected(SessionId),
    InProgress(SessionId),
}

/// Non-owning runtime projection of a path owned by `PeerPathManager`.
///
/// RuntimeState keeps this only for session-scoped lookup and stale guards. It
/// never retains an `Arc<PhysicalRoute>` or any other carrier lifetime owner.
struct OwnedPathProjection {
    session_id: SessionId,
    projection: PathProjection,
}

impl ConnectionAdmissionLease {
    pub(crate) fn new(admission: ConnectionAdmission) -> Self {
        Self { admission }
    }
}

impl std::ops::Deref for ConnectionAdmissionLease {
    type Target = ConnectionAdmission;

    fn deref(&self) -> &Self::Target {
        &self.admission
    }
}

pub(crate) type RelayCryptoMessage = (u8, Vec<u8>);
type RelayCryptoSender = mpsc::Sender<RelayCryptoMessage>;

#[derive(Clone)]
pub(crate) struct PeerConfig {
    pub(crate) endpoint: Option<SocketAddr>,
    pub(crate) identity_public_key: [u8; 32],
    pub(crate) e2e_public_key: [u8; 32],
    pub(crate) e2ee_policy: network_protocol::E2eePolicy,
}

pub(crate) struct RuntimeState {
    /// Native bind 完成后发布实际 UDP 端口，供受控 FFI 诊断读取。
    ///
    /// 该快照只描述当前 Runtime 的监听资源，不把 socket 或 Quinn handle
    /// 暴露给 Dart，也不参与 Session/Peer 的业务状态。
    pub(crate) bound_port: Arc<AtomicU16>,
    pub(crate) endpoint: RwLock<Option<Endpoint>>,
    /// Runtime-owned QUIC accept loop task id.  The task itself lives only in
    /// `RuntimeTaskSupervisor`; this field is a cancellation lookup, not a
    /// second ownership path.
    pub(crate) accept_task: Mutex<Option<TaskId>>,
    /// Runtime-owned TCP fallback accept loop. TCP shares the configured port
    /// with QUIC's UDP socket because TCP and UDP have independent bind
    /// namespaces.
    pub(crate) tcp_accept_task: Mutex<Option<TaskId>>,
    #[cfg(test)]
    pub(crate) tcp_fallback_enabled: AtomicBool,
    pub(crate) identity: RwLock<Option<Arc<DeviceIdentity>>>,
    pub(crate) receive_directory: RwLock<Option<PathBuf>>,
    pub(crate) local_path_manager: RwLock<Option<Arc<PathManager>>>,
    pub(crate) peers: RwLock<HashMap<String, PeerConfig>>,
    pub(crate) trusted_peer_keys: RwLock<HashMap<String, [u8; 32]>>,
    /// ConnectionSession storage only; logical Peer lifecycle is owned by
    /// `PeerSupervisorRegistry` and never by this connection store.
    pub(crate) connection_sessions: ConnectionSessionStore,
    /// Session-owned application crypto. Route changes do not replace this
    /// manager; explicit Session close removes the corresponding context.
    pub(crate) crypto: SessionCryptoManager,
    pub(crate) delivery: DeliveryManager,
    pub(crate) realtime: AsyncMutex<crate::realtime::RealtimeManager>,
    pub(crate) relay_config: RwLock<Option<crate::relay::RelayReconnectConfig>>,
    pub(crate) relay_reconnect_task: Mutex<Option<TaskId>>,
    pub(crate) relay_reconnect_active: AtomicBool,
    /// 当前 Relay 凭据已被服务端判定过期/冲突；在 Dart 下发新的
    /// ConfigureRelayCommand 前抑制所有自动重连。
    pub(crate) relay_credential_stale: AtomicBool,
    /// transport-network v2：本地 Discovery 生命周期 owner（§9/§29）。
    pub(crate) local_discovery: RwLock<Option<Arc<crate::discovery::LocalDiscoveryManager>>>,
    /// transport-network v2：v2 控制面客户端 sink（§31 `RelayControlClient` 抽象）。
    ///
    /// resolve / publish / signaling / reserve 均经此 trait 对象路由。Step 6 接线后由
    /// `relay::configure_relay_for_state` 填充。
    pub(crate) relay_control: RwLock<Option<Arc<dyn crate::discovery::DiscoveryControlPlane>>>,
    /// transport-network v2：已就绪 Session 摘要索引（§34/§29）；不拥有连接。
    pub(crate) ready_session_index: crate::connect::ready_index::ReadySessionIndex,
    /// transport-network v2：Presence → UI-only 提示缓存（§23/§29）。Presence 事件
    /// 只更新本缓存，绝不修改 ConnectivityAttempt / CandidateSet / ConnectionSession。
    pub(crate) presence_hints: crate::connect::presence::PresenceHintCache,
    /// Authoritative remote candidate cache for uncoordinated Direct Stage A.
    /// Entries are refreshed only from accepted Resolve/answer snapshots; age is
    /// checked with `Instant` inside `ResolvedCandidateCache`.
    pub(crate) remote_candidate_cache: RwLock<HashMap<String, ResolvedCandidateCache>>,
    /// V2 peer-owned lifecycle coordinator. It isolates intent generations,
    /// waiters, and bounded control mailboxes by validated PeerId.
    pub(crate) peer_supervisors: crate::connect::PeerSupervisorRegistry,
    /// Runtime owner of ready-path handles. Borrowers receive leases only.
    pub(crate) ready_paths: Arc<crate::connect::PathRegistry>,
    /// Strong peer-owned path managers. `ready_paths` is only a weak index;
    /// these managers own the corresponding PhysicalPath and its carrier.
    pub(crate) peer_path_managers: RwLock<HashMap<String, Arc<Mutex<PeerPathManager>>>>,
    /// Runtime lookup for non-owning path projections. Direct and Relay
    /// entries may coexist; the peer path manager owns every carrier.
    path_projections: RwLock<HashMap<String, Vec<OwnedPathProjection>>>,
    /// Direct recovery policy is a scheduler gate only. It never owns a path
    /// or a session and Relay business availability is tracked independently.
    direct_recovery: Mutex<HashMap<String, crate::discovery::DirectRecoveryPolicy>>,
    /// ReliableStream byte-stream managers, keyed by peer（§17）。每个 peer 的
    /// receive buffer / QUIC send half / 网关桥都挂在这个 manager 上。
    pub(crate) reliable_streams: RwLock<HashMap<String, ReliableStreamManager>>,
    /// SSH 网关桥接的本地 sshd 端口（§21 option B）。生产默认 22；测试可覆盖指向
    /// 本地 echo server。
    pub(crate) stream_gateway_port: Arc<AtomicU16>,
    pub(crate) relay_crypto_waiters: RwLock<HashMap<String, RelayCryptoSender>>,
    pub(crate) relay_crypto_responders: AsyncMutex<HashMap<String, RelayResponderHandshake>>,
    pub(crate) relay_crypto_confirmers:
        AsyncMutex<HashMap<String, RelayResponderConfirmation<ConnectionAdmissionLease>>>,
    /// Peer-level business admission guard.  RelayDataClient owns the socket
    /// and the Relay remains opaque; only the endpoint sets this after the
    /// authenticated Noise/PathHandshakeV2 admission is complete.
    pub(crate) relay_path_ready: RwLock<HashSet<String>>,
    /// reservation 数据面上的 Relay 文件传输业务状态（非 V2 会话协议）：
    /// - `relay_pending_incoming`：等待 UI 审批的传入 offer（transfer_id → pending）。
    /// - `relay_active_incoming`：正在接收的活跃传输（transfer_id → active）。
    /// - `relay_acceptances` / `relay_completions`：发送方按 transfer_id 等待 accept/
    ///   complete_ack 应答的 oneshot（由数据面事件循环投递）。
    pub(crate) relay_pending_incoming: RwLock<HashMap<String, crate::relay::PendingRelayIncoming>>,
    pub(crate) relay_active_incoming:
        AsyncMutex<HashMap<String, crate::relay::ActiveRelayIncoming>>,
    pub(crate) relay_acceptances:
        RwLock<HashMap<String, oneshot::Sender<Option<crate::relay::RelayAcceptance>>>>,
    pub(crate) relay_completions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) transfers: TransferManager,
    pub(crate) event_tx: EventSender,
    pub(crate) task_supervisor: Arc<RuntimeTaskSupervisor>,
}

impl RuntimeState {
    /// 创建由一个已启动 worker 拥有的空运行时状态。
    pub(crate) fn new<S: Into<EventSender>>(event_tx: S, bound_port: Arc<AtomicU16>) -> Self {
        let task_supervisor = RuntimeTaskSupervisor::new();
        Self {
            bound_port,
            endpoint: RwLock::new(None),
            accept_task: Mutex::new(None),
            tcp_accept_task: Mutex::new(None),
            #[cfg(test)]
            tcp_fallback_enabled: AtomicBool::new(true),
            identity: RwLock::new(None),
            receive_directory: RwLock::new(None),
            local_path_manager: RwLock::new(None),
            peers: RwLock::new(HashMap::new()),
            trusted_peer_keys: RwLock::new(HashMap::new()),
            connection_sessions: ConnectionSessionStore::new(),
            crypto: SessionCryptoManager::new(),
            delivery: DeliveryManager::new(),
            realtime: AsyncMutex::new(crate::realtime::RealtimeManager::default()),
            relay_config: RwLock::new(None),
            relay_reconnect_task: Mutex::new(None),
            relay_reconnect_active: AtomicBool::new(false),
            relay_credential_stale: AtomicBool::new(false),
            local_discovery: RwLock::new(None),
            relay_control: RwLock::new(None),
            ready_session_index: crate::connect::ready_index::ReadySessionIndex::new(),
            presence_hints: crate::connect::presence::PresenceHintCache::new(),
            remote_candidate_cache: RwLock::new(HashMap::new()),
            peer_supervisors: crate::connect::PeerSupervisorRegistry::with_task_supervisor(
                Arc::clone(&task_supervisor),
            ),
            ready_paths: Arc::new(crate::connect::PathRegistry::new()),
            peer_path_managers: RwLock::new(HashMap::new()),
            path_projections: RwLock::new(HashMap::new()),
            direct_recovery: Mutex::new(HashMap::new()),
            reliable_streams: RwLock::new(HashMap::new()),
            stream_gateway_port: Arc::new(AtomicU16::new(crate::stream::STREAM_LOCAL_SSH_PORT)),
            relay_crypto_waiters: RwLock::new(HashMap::new()),
            relay_crypto_responders: AsyncMutex::new(HashMap::new()),
            relay_crypto_confirmers: AsyncMutex::new(HashMap::new()),
            relay_path_ready: RwLock::new(HashSet::new()),
            relay_pending_incoming: RwLock::new(HashMap::new()),
            relay_active_incoming: AsyncMutex::new(HashMap::new()),
            relay_acceptances: RwLock::new(HashMap::new()),
            relay_completions: RwLock::new(HashMap::new()),
            incoming_decisions: RwLock::new(HashMap::new()),
            transfers: TransferManager::new(),
            event_tx: event_tx.into(),
            task_supervisor,
        }
    }

    async fn retire_session_resources(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        // Retire aliases before awaiting the old task group.
        // A receiver task may be inside a bounded I/O wait; the replacement
        // Session must become cryptographically isolated without waiting for
        // that transport task to finish unwinding.
        self.crypto.remove_session(peer_id, &session_key);
        // transport-network v2：Session 替换/关闭时同步注销连接登记（§34）。
        self.ready_session_index
            .unregister_if_session(peer_id, session_id);
        // §17/§21：ConnectionSession 销毁时关闭该 peer 的所有 ReliableStream，
        // 并向应用发布 SshStreamClosed（SSH 不做透明恢复，客户端自行重连）。
        if let Some(manager) = self.reliable_streams.read().await.get(peer_id).cloned() {
            let local_opener_device_id = self
                .identity
                .read()
                .await
                .as_ref()
                .map(|identity| identity.device_id.clone())
                .unwrap_or_default();
            manager.close_all(peer_id, &local_opener_device_id).await;
        }
        // §19/§20 业务状态（pending / dedup / ordered）不属于 Session：transport
        // 丢失或 Session 被替换时**不得**清理 Delivery 的接收端去重/有序状态，
        // 否则新连接无法按 MessageId 去重、无法在有序通道上从断点继续。显式
        // Disconnect 才清理（见 peer::disconnect_peer）。
    }

    pub(crate) async fn cancel_session_tasks(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        self.retire_session_resources(peer_id, session_id).await;
        // §19：ConnectionSession 销毁（transport 丢失 / 显式断开 / 被新连接替换）
        // 时把该 Peer 的非终态 TransferOperation 置为 Paused。业务状态保留在
        // TransferManager，等待下一次连接上的 ResumeTransfer(transfer_id) 恢复。
        self.transfers.pause_peer_transfers(peer_id).await;
        // §22：RealtimeSession 绑定在 ConnectionSession 上，transport 丢失即随
        // ConnectionSession 销毁（发出 Closed、销毁 PeerConnection）；不做透明恢复。
        crate::realtime::close_realtime_sessions_for_session(self, peer_id, session_id).await;
        self.task_supervisor.cancel_session(&session_key).await;
    }
    pub(crate) async fn begin_connect(
        &self,
        peer_id: &str,
        _required_capabilities: u8,
    ) -> ConnectDecision {
        // SessionStore only reserves a fresh identity. It deliberately does
        // not know whether a peer is Connecting or Online; that decision is
        // owned by PeerSupervisor. The existing binding is sufficient for
        // this attempt-local stale guard.
        if let Some(session_id) = self.connection_sessions.current_session_id(peer_id).await {
            if self
                .connection_sessions
                .current_remote_session_binding(peer_id)
                .await
                .is_some()
            {
                ConnectDecision::AlreadyConnected(session_id)
            } else {
                ConnectDecision::InProgress(session_id)
            }
        } else {
            let session_id = SessionId::new();
            match self
                .connection_sessions
                .register_pending_session(peer_id, session_id)
                .await
            {
                Ok(()) => ConnectDecision::Started(session_id),
                Err(_) => ConnectDecision::InProgress(
                    self.connection_sessions
                        .current_session_id(peer_id)
                        .await
                        .unwrap_or(session_id),
                ),
            }
        }
    }

    /// Admit authenticated Noise material for a 1:1 ConnectionSession（§18）。
    ///
    /// 被替换的旧 Session 在这里立即整体销毁（关闭 detached route + retire 资源 +
    /// 取消其 task group）。因为 Session 与 connection 一一对应，旧 Session 属于另一条
    /// connection，取消其任务组不会中断当前新连接的握手。
    #[allow(dead_code)]
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
    ) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
        self.admit_authenticated_session_with_capability(
            peer_id,
            expected_session_id,
            remote_session_binding,
            u8::MAX,
        )
        .await
    }

    pub(crate) async fn admit_authenticated_session_with_capability(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
        candidate_capabilities: u8,
    ) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
        let _ = candidate_capabilities;
        let outcome: ConnectionAdmissionOutcome = self
            .connection_sessions
            .admit_authenticated_session(peer_id, expected_session_id, remote_session_binding)
            .await?;
        let admission = outcome.admission;
        if let Some(replaced_session_id) = admission.replaced_session_id {
            self.close_transport_path(peer_id).await;
            self.cancel_session_tasks(peer_id, replaced_session_id)
                .await;
        }
        Ok(ConnectionAdmissionLease::new(admission))
    }

    async fn peer_path_manager(
        &self,
        peer_id: &str,
    ) -> Result<Arc<Mutex<PeerPathManager>>, CoreNetworkError> {
        let peer = PeerId::new(peer_id)?;
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            return Ok(manager);
        }
        let mut managers = self.peer_path_managers.write().await;
        Ok(managers
            .entry(peer_id.to_string())
            .or_insert_with(|| {
                Arc::new(Mutex::new(PeerPathManager::new(
                    peer.clone(),
                    Arc::clone(&self.ready_paths),
                )))
            })
            .clone())
    }

    /// Acquire one explicit business lease from the sole peer path owner.
    /// RuntimeState exposes the lookup boundary; it never stores or returns a
    /// second strong carrier owner.
    pub(crate) async fn acquire_path_lease(
        &self,
        peer_id: &str,
        required_capabilities: u8,
    ) -> Result<crate::connect::PathLease, CoreNetworkError> {
        let _peer_id = PeerId::new(peer_id)?;
        let manager = self
            .peer_path_managers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or(CoreNetworkError::NoRoute)?;
        let manager = manager.lock().expect("peer path manager lock");
        let selected = manager
            .select(required_capabilities)
            .ok_or(CoreNetworkError::NoRoute)?;
        let (acquired, lease) = manager.acquire(required_capabilities)?;
        if acquired != selected {
            lease.release();
            return Err(CoreNetworkError::StaleAttempt);
        }
        Ok(lease)
    }

    /// Ensure one business capability through the peer supervisor. This path
    /// starts the supervisor mailbox worker but never enables maintenance;
    /// only an explicit ConnectPeer intent may do that.
    pub(crate) async fn ensure_business_path(
        state: Arc<Self>,
        peer_id: &str,
        command_id: &str,
        class: network_protocol::CommunicationClass,
        required_capabilities: u8,
    ) -> Result<SessionId, CoreNetworkError> {
        if let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await {
            if state
                .acquire_path_lease(peer_id, required_capabilities)
                .await
                .is_ok()
            {
                return Ok(session_id);
            }
        }

        let supervisor = state.peer_supervisors.get_or_create(peer_id)?;
        let intent = state.peer_supervisors.start_business(
            Arc::clone(&state),
            peer_id,
            command_id.to_string(),
            class,
        )?;
        match intent.completion().await {
            Ok(Ok(crate::connect::PeerState::Online)) => {
                let session_id = state
                    .connection_sessions
                    .current_session_id(peer_id)
                    .await
                    .ok_or(CoreNetworkError::NoRoute)?;
                if state
                    .acquire_path_lease(peer_id, required_capabilities)
                    .await
                    .is_err()
                {
                    supervisor.path_lost();
                    return Err(CoreNetworkError::NoRoute);
                }
                Ok(session_id)
            }
            Ok(Ok(_)) | Ok(Err(CoreNetworkError::NoRoute)) => Err(CoreNetworkError::NoRoute),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(CoreNetworkError::Cancelled),
        }
    }

    async fn publish_transport_path(
        &self,
        peer_id: &str,
        session_id: SessionId,
        route: crate::connect::ActiveRoute,
    ) -> Result<Option<PathHandle>, CoreNetworkError> {
        let profile = route.profile();
        let manager = self.peer_path_manager(peer_id).await?;
        let (old_handle, projection) = {
            let mut manager = manager.lock().expect("peer path manager lock");
            let old_handle = match profile.topology() {
                crate::connection::RouteTopology::Direct => manager.direct_ready().first().cloned(),
                crate::connection::RouteTopology::Relay => manager.relay_ready().cloned(),
            };
            let handle = manager.publish_ready_with_route(route)?;
            let projection = manager
                .projection(&handle)
                .ok_or(CoreNetworkError::StaleAttempt)?;
            (old_handle, projection)
        };
        let mut paths = self.path_projections.write().await;
        let entries = paths.entry(peer_id.to_string()).or_default();
        entries
            .retain(|entry| entry.projection.handle().profile().topology() != profile.topology());
        entries.push(OwnedPathProjection {
            session_id,
            projection,
        });
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        let policy = recovery.entry(peer_id.to_string()).or_default();
        match profile.topology() {
            crate::connection::RouteTopology::Direct => policy.mark_direct_ready(),
            crate::connection::RouteTopology::Relay => policy.mark_relay_ready(),
        }
        Ok(old_handle)
    }

    pub(crate) async fn has_ready_direct_path(&self, peer_id: &str) -> bool {
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                !manager
                    .lock()
                    .expect("peer path manager lock")
                    .direct_ready()
                    .is_empty()
            })
    }

    pub(crate) async fn has_ready_relay_path(&self, peer_id: &str) -> bool {
        self.peer_path_managers
            .read()
            .await
            .get(peer_id)
            .is_some_and(|manager| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
    }

    pub(crate) fn reset_direct_recovery(&self, peer_id: &str) {
        let mut recovery = self.direct_recovery.lock().expect("recovery policy lock");
        recovery
            .entry(peer_id.to_string())
            .or_default()
            .reset_after_environment_change();
    }

    pub(crate) fn next_direct_recovery_delay(&self, peer_id: &str) -> Option<Duration> {
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .get_mut(peer_id)
            .and_then(crate::discovery::DirectRecoveryPolicy::next_delay)
    }

    pub(crate) async fn arm_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
        budget: Duration,
        required_capabilities: u8,
    ) -> bool {
        let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() else {
            return false;
        };
        let mut manager = manager.lock().expect("peer path manager lock");
        if manager.direct_probe().is_some() {
            return false;
        }
        manager
            .ensure_direct_probe(generation.get(), required_capabilities, budget)
            .is_ok()
    }

    pub(crate) async fn finish_direct_probe(
        &self,
        peer_id: &str,
        generation: crate::connect::IntentGeneration,
    ) {
        if let Some(manager) = self.peer_path_managers.read().await.get(peer_id).cloned() {
            manager
                .lock()
                .expect("peer path manager lock")
                .finish_direct_probe(generation.get());
        }
    }

    pub(crate) async fn attach_connection_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: quinn::Connection,
        route: network_protocol::RouteType,
    ) -> Result<Option<PathHandle>, ()> {
        let session_id = match self.connection_sessions.current_session_id(peer_id).await {
            Some(session_id) => {
                if expected_session_id.is_some_and(|expected| expected != session_id) {
                    connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                    return Err(());
                }
                session_id
            }
            None if expected_session_id.is_some() => {
                connection.close(quinn::VarInt::from_u32(0), b"stale physical path");
                return Err(());
            }
            None => {
                let session_id = SessionId::new();
                self.connection_sessions
                    .register_pending_session(peer_id, session_id)
                    .await
                    .map_err(|_| ())?;
                session_id
            }
        };
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::quic(connection, route),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn attach_generic_route_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        scope: &mut crate::connect::GenericRouteScope,
    ) -> Result<Option<PathHandle>, ()> {
        let session_id = self
            .connection_sessions
            .current_session_id(peer_id)
            .await
            .ok_or(())?;
        if expected_session_id.is_some_and(|expected| expected != session_id) {
            return Err(());
        }
        let profile = scope.profile().ok_or(())?;
        if self.path_profile(peer_id).await == Some(profile) {
            return Err(());
        }
        let owner = scope.commit_and_take_owner()?;
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic(owner),
        )
        .await
        .map_err(|_| ())
    }

    pub(crate) async fn mark_relay_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        relay: Option<Arc<RelayDataClient>>,
    ) -> bool {
        if self.connection_sessions.current_session_id(peer_id).await != Some(expected_session_id) {
            return false;
        }
        self.publish_transport_path(
            peer_id,
            expected_session_id,
            crate::connect::ActiveRoute::relay(relay),
        )
        .await
        .is_ok()
    }

    pub(crate) async fn path_profile(
        &self,
        peer_id: &str,
    ) -> Option<crate::connection::ConnectionProfile> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let manager = manager.lock().expect("peer path manager lock");
        manager
            .direct_ready()
            .first()
            .or_else(|| manager.relay_ready())
            .map(PathHandle::profile)
    }

    pub(crate) async fn e2ee_policy(
        &self,
        peer_id: &str,
    ) -> crate::crypto_handshake::path_handshake::E2eePolicy {
        let configured = self
            .peers
            .read()
            .await
            .get(peer_id)
            .map(|peer| peer.e2ee_policy)
            .unwrap_or(network_protocol::E2eePolicy::Required);
        crate::crypto_handshake::path_handshake::E2eePolicy::from_network_code(configured as i32)
            .unwrap_or_default()
    }

    pub(crate) async fn path_route(&self, peer_id: &str) -> Option<network_protocol::RouteType> {
        self.path_profile(peer_id)
            .await
            .and_then(|profile| profile.route().to_wire())
    }

    #[allow(dead_code)] // retained for runtime diagnostics and focused tests
    pub(crate) async fn path_connection(&self, peer_id: &str) -> Option<quinn::Connection> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let lease = manager
            .lock()
            .expect("peer path manager lock")
            .acquire(crate::connect::CAPABILITY_RELIABLE_MESSAGE)
            .ok()?
            .1;
        lease.connection()
    }

    pub(crate) async fn path_connection_for_lease(
        &self,
        lease: &crate::connect::PathLease,
    ) -> Option<quinn::Connection> {
        if !lease.is_active() {
            return None;
        }
        lease.connection()
    }

    #[allow(dead_code)] // retained for runtime diagnostics and focused tests
    pub(crate) async fn path_stream_carrier(
        &self,
        peer_id: &str,
    ) -> Option<crate::connect::StreamCarrier> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let lease = manager
            .lock()
            .expect("peer path manager lock")
            .acquire(crate::connect::CAPABILITY_RELIABLE_STREAM)
            .ok()?
            .1;
        lease.stream_carrier()
    }

    pub(crate) async fn path_relay_data(&self, peer_id: &str) -> Option<Arc<RelayDataClient>> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let projection = {
            let manager = manager.lock().expect("peer path manager lock");
            manager
                .relay_ready()
                .and_then(|handle| manager.projection(handle))
        }?;
        projection.acquire().ok()?.relay_data()
    }

    pub(crate) async fn path_relay_data_for_lease(
        &self,
        lease: &crate::connect::PathLease,
    ) -> Option<Arc<RelayDataClient>> {
        if !lease.is_active() {
            return None;
        }
        lease.relay_data()
    }

    pub(crate) async fn path_is_current_relay_data(
        &self,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
    ) -> bool {
        self.path_relay_data(peer_id)
            .await
            .is_some_and(|current| Arc::ptr_eq(&current, data))
    }

    #[allow(dead_code)] // retained for runtime diagnostics and focused tests
    pub(crate) async fn path_send_channel_frame(
        &self,
        peer_id: &str,
        relay_token: &str,
        kind: crate::connection::GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let required_capability = match kind {
            crate::connection::GenericFrameKind::DataMessage
            | crate::connection::GenericFrameKind::DeliveryAck => {
                crate::connect::CAPABILITY_RELIABLE_MESSAGE
            }
            crate::connection::GenericFrameKind::StreamOpen
            | crate::connection::GenericFrameKind::StreamBytes
            | crate::connection::GenericFrameKind::StreamClose => {
                crate::connect::CAPABILITY_RELIABLE_STREAM
            }
        };
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned();
        let Some(manager) = manager else {
            return Err(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "path unavailable").into(),
            );
        };
        let lease = manager
            .lock()
            .expect("peer path manager lock")
            .acquire(required_capability)
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotConnected, "path unavailable"))?
            .1;
        lease.send_channel_frame(relay_token, kind, payload).await
    }

    pub(crate) async fn path_send_channel_frame_for_lease(
        &self,
        lease: &crate::connect::PathLease,
        relay_token: &str,
        kind: crate::connection::GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if !lease.is_active() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "path lease inactive",
            )
            .into());
        }
        let result = lease.send_channel_frame(relay_token, kind, payload).await;
        if result.is_ok() && !lease.is_active() {
            return Err(
                std::io::Error::new(std::io::ErrorKind::NotConnected, "path lease lost").into(),
            );
        }
        result
    }

    pub(crate) async fn path_is_connected(&self, peer_id: &str) -> bool {
        let current_session = self.connection_sessions.current_session_id(peer_id).await;
        let Some(session_id) = current_session else {
            return false;
        };
        self.path_projections
            .read()
            .await
            .get(peer_id)
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry.session_id == session_id && entry.projection.is_alive())
            })
    }

    /// Validate an authenticated candidate before its PhysicalRoute is
    /// published. This is an admission check, not a connectivity truth read:
    /// the candidate owns no Runtime path until the caller commits it.
    pub(crate) async fn candidate_supports_required(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        profile: crate::connection::ConnectionProfile,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == Some(expected_session_id)
            && profile_capability_mask(profile) != 0
    }

    /// Validate a candidate against the requested capability before path
    /// publication. The capability mask remains attempt-local and is never
    /// stored in ConnectionSessionStore.
    pub(crate) async fn candidate_supports(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        profile: crate::connection::ConnectionProfile,
        required_capabilities: u8,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == Some(expected_session_id)
            && profile_capability_mask(profile) & required_capabilities == required_capabilities
    }

    pub(crate) async fn path_admission_can_retry(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
    ) -> bool {
        self.connection_sessions.current_session_id(peer_id).await == expected_session_id
            && self
                .connection_sessions
                .current_remote_session_binding(peer_id)
                .await
                .is_none()
    }

    pub(crate) async fn wait_for_path_change(&self) {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    pub(crate) async fn fail_session(&self, peer_id: &str, session_id: SessionId) {
        self.close_transport_path(peer_id).await;
        if self
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await
        {
            self.cancel_session_tasks(peer_id, session_id).await;
        }
    }

    pub(crate) async fn close_transport_path(&self, peer_id: &str) -> Option<PathHandle> {
        let manager = self.peer_path_managers.write().await.remove(peer_id);
        let entries = self.path_projections.write().await.remove(peer_id);
        self.direct_recovery
            .lock()
            .expect("recovery policy lock")
            .remove(peer_id);
        let first = entries
            .as_ref()
            .and_then(|entries| entries.first())
            .map(|entry| entry.projection.handle().clone());
        if let Some(manager) = manager {
            manager.lock().expect("peer path manager lock").hard_close();
        }
        first
    }

    pub(crate) async fn close_relay_path(
        &self,
        peer_id: &str,
        data: Option<&Arc<RelayDataClient>>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let relay_handle = {
            let manager = manager.lock().expect("peer path manager lock");
            let handle = manager.relay_ready()?.clone();
            if let Some(wanted) = data {
                let projection = manager.projection(&handle)?;
                let lease = projection.acquire().ok()?;
                let current = lease.relay_data()?;
                if !Arc::ptr_eq(&current, wanted) {
                    return None;
                }
            }
            handle
        };
        manager
            .lock()
            .expect("peer path manager lock")
            .hard_close_relay();
        self.close_inactive_streams(peer_id).await;
        if let Ok(mut recovery) = self.direct_recovery.lock() {
            if let Some(policy) = recovery.get_mut(peer_id) {
                policy.mark_relay_lost();
            }
        }
        self.remove_path_projections(peer_id, crate::connection::RouteTopology::Relay)
            .await;
        if !self.manager_has_ready_path(&manager).await {
            self.peer_path_managers.write().await.remove(peer_id);
            self.path_projections.write().await.remove(peer_id);
        }
        Some(relay_handle)
    }

    pub(crate) async fn close_direct_path(
        &self,
        peer_id: &str,
        route_id: Option<u64>,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let direct_handle = {
            let manager = manager.lock().expect("peer path manager lock");
            let handle = manager.direct_ready().first()?.clone();
            if route_id.is_some_and(|id| id != handle.id()) {
                return None;
            }
            handle
        };
        manager
            .lock()
            .expect("peer path manager lock")
            .hard_close_direct();
        self.close_inactive_streams(peer_id).await;
        if let Ok(mut recovery) = self.direct_recovery.lock() {
            if let Some(policy) = recovery.get_mut(peer_id) {
                policy.mark_direct_unavailable();
            }
        }
        self.remove_path_projections(peer_id, crate::connection::RouteTopology::Direct)
            .await;
        if !self.manager_has_ready_path(&manager).await {
            self.peer_path_managers.write().await.remove(peer_id);
            self.path_projections.write().await.remove(peer_id);
        }
        Some(direct_handle)
    }

    pub(crate) async fn close_direct_path_for_connection(
        &self,
        peer_id: &str,
        connection: &quinn::Connection,
    ) -> Option<PathHandle> {
        let manager = self.peer_path_managers.read().await.get(peer_id).cloned()?;
        let route_id = {
            let manager = manager.lock().expect("peer path manager lock");
            let handle = manager.direct_ready().first()?.clone();
            let projection = manager.projection(&handle)?;
            let lease = projection.acquire().ok()?;
            let candidate = lease.connection()?;
            (candidate.stable_id() == connection.stable_id()).then_some(handle.id())
        };
        self.close_direct_path(peer_id, route_id).await
    }

    pub(crate) async fn close_all_relay_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .iter()
            .filter(|(_, manager)| {
                manager
                    .lock()
                    .expect("peer path manager lock")
                    .relay_ready()
                    .is_some()
            })
            .map(|(peer_id, _)| peer_id.clone())
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_relay_path(&peer_id, None).await;
        }
    }

    pub(crate) async fn close_all_transport_paths(&self) {
        let peers = self
            .peer_path_managers
            .read()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for peer_id in peers {
            let _ = self.close_transport_path(&peer_id).await;
        }
    }

    async fn remove_path_projections(
        &self,
        peer_id: &str,
        topology: crate::connection::RouteTopology,
    ) {
        let mut projections = self.path_projections.write().await;
        if let Some(entries) = projections.get_mut(peer_id) {
            entries.retain(|entry| entry.projection.handle().profile().topology() != topology);
            if entries.is_empty() {
                projections.remove(peer_id);
            }
        }
    }

    async fn manager_has_ready_path(&self, manager: &Arc<Mutex<PeerPathManager>>) -> bool {
        let manager = manager.lock().expect("peer path manager lock");
        !manager.direct_ready().is_empty() || manager.relay_ready().is_some()
    }

    #[cfg(test)]
    pub(crate) async fn attach_test_generic_route(
        &self,
        peer_id: &str,
        session_id: SessionId,
        handle: crate::connection::GenericRouteHandle,
    ) -> Result<(), ()> {
        self.publish_transport_path(
            peer_id,
            session_id,
            crate::connect::ActiveRoute::generic_test(handle),
        )
        .await
        .map(|_| ())
        .map_err(|_| ())
    }

    #[cfg(test)]
    pub(crate) async fn close_path_for_test(&self, peer_id: &str) {
        let session_id = self.connection_sessions.current_session_id(peer_id).await;
        if self.close_direct_path(peer_id, None).await.is_some() {
            if let Some(session_id) = session_id {
                if self
                    .connection_sessions
                    .retire_session(peer_id, session_id)
                    .await
                {
                    self.cancel_session_tasks(peer_id, session_id).await;
                    if let Ok(supervisor) = self.peer_supervisors.get_or_create(peer_id) {
                        supervisor.path_lost();
                    }
                    crate::events::emit_peer_state(
                        &self.event_tx,
                        peer_id,
                        network_protocol::PeerConnectionState::Disconnected,
                        network_protocol::RouteType::Unspecified,
                        None,
                    );
                }
            }
        }
    }

    pub(crate) async fn crypto_context(
        &self,
        peer_id: &str,
        session_id: &str,
    ) -> Result<Arc<Mutex<CryptoContext>>, CryptoError> {
        self.crypto.get(peer_id, session_id)
    }

    pub(crate) fn install_crypto_material(
        &self,
        peer_id: &str,
        session_id: &str,
        material: &SessionCryptoMaterial,
    ) -> Result<(), CryptoError> {
        self.crypto
            .install_material_aliases(
                peer_id,
                &[session_id, material.remote_session_binding.as_str()],
                material.root_key,
                material.initiator,
            )
            .map(|_| ())
    }

    pub(crate) async fn encrypt_application_payload(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .encrypt(aad, plaintext);
        result
    }

    pub(crate) async fn decrypt_application_payload(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .decrypt(aad, envelope);
        result
    }

    pub(crate) async fn decrypt_application_payload_for_delivery(
        &self,
        peer_id: &str,
        session_id: &str,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let context = self.crypto_context(peer_id, session_id).await?;
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .decrypt_for_delivery(aad, envelope);
        result
    }

    /// Returns the per-peer ReliableStream manager, creating it lazily. The
    /// manager holds the receive buffers and QUIC send halves for every byte
    /// stream to `peer_id` (§17).
    pub(crate) async fn stream_manager(&self, peer_id: &str) -> ReliableStreamManager {
        let mut map = self.reliable_streams.write().await;
        map.entry(peer_id.to_string())
            .or_insert_with(|| ReliableStreamManager::new(self.event_tx.clone()))
            .clone()
    }

    /// Close streams whose long-lived path lease was revoked by a hard path
    /// close. Normal retirement leaves the lease active and therefore does not
    /// reach this boundary; the stream remains bound to its original path
    /// until the operation closes normally.
    pub(crate) async fn close_inactive_streams(&self, peer_id: &str) {
        let Some(manager) = self.reliable_streams.read().await.get(peer_id).cloned() else {
            return;
        };
        let local_opener_device_id = self
            .identity
            .read()
            .await
            .as_ref()
            .map(|identity| identity.device_id.clone())
            .unwrap_or_default();
        let _ = manager
            .close_inactive(peer_id, &local_opener_device_id)
            .await;
    }
}

/// 管理 Tokio 异步运行时生命周期与命令/事件通道。
pub struct NetworkRuntime {
    pub(crate) runtime: Arc<Runtime>,
    pub(crate) command_tx: Mutex<Option<mpsc::Sender<NetworkCommand>>>,
    pub(crate) event_rx: Arc<Mutex<EventReceiver>>,
    pub(crate) event_tx: EventSender,
    pub(crate) bound_port: Arc<AtomicU16>,
    pub(crate) lifecycle: AtomicU8,
    pub(crate) state: Mutex<Option<Arc<RuntimeState>>>,
    pub(crate) stop_notify: Arc<Notify>,
}

impl NetworkRuntime {
    /// 创建运行时。调用 `start` 并提交配置命令后才开始使用网络；
    /// 生命周期转换前不会启动 worker。
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|error| NetworkError::RuntimeInitFailed(error.to_string()))?;
        let (event_tx, event_rx) = bounded_event_channel();
        let bound_port = Arc::new(AtomicU16::new(0));
        info!("NetworkRuntime initialized successfully");
        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx: Mutex::new(None),
            event_rx: Arc::new(Mutex::new(event_rx)),
            event_tx,
            bound_port,
            lifecycle: AtomicU8::new(RUNTIME_CREATED),
            state: Mutex::new(None),
            stop_notify: Arc::new(Notify::new()),
        })
    }

    /// 将运行时从 Created 转换为 Running，并启动 worker。
    pub fn start(&self) -> Result<(), NetworkError> {
        self.lifecycle
            .compare_exchange(
                RUNTIME_CREATED,
                RUNTIME_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        let (command_tx, command_rx) = mpsc::channel::<NetworkCommand>(COMMAND_MAILBOX_CAPACITY);
        let state = Arc::new(RuntimeState::new(
            self.event_tx.clone(),
            Arc::clone(&self.bound_port),
        ));
        *self.state.lock().map_err(|_| {
            NetworkError::CommandQueueFailed("runtime state lock poisoned".into())
        })? = Some(Arc::clone(&state));
        let _runtime_guard = self.runtime.enter();
        if state
            .task_supervisor
            .spawn_runtime(
                "command-worker",
                run_command_worker(command_rx, Arc::clone(&state)),
            )
            .is_none()
        {
            return Err(NetworkError::RuntimeNotRunning);
        }
        *self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))? =
            Some(command_tx);
        Ok(())
    }

    /// 恰好停止 worker 一次；重复调用仍然成功。
    pub fn stop(&self) -> Result<(), NetworkError> {
        let current = self.lifecycle.load(Ordering::Acquire);
        if current == RUNTIME_CREATED || current == RUNTIME_STOPPED {
            self.bound_port.store(0, Ordering::Release);
            self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
            self.stop_notify.notify_waiters();
            return Ok(());
        }
        if current == RUNTIME_STOPPING {
            loop {
                let notified = self.stop_notify.notified();
                if self.lifecycle.load(Ordering::Acquire) != RUNTIME_STOPPING {
                    break;
                }
                self.runtime.block_on(notified);
            }
            return Ok(());
        }
        self.lifecycle
            .compare_exchange(
                RUNTIME_RUNNING,
                RUNTIME_STOPPING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| NetworkError::RuntimeNotRunning)?;
        self.command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .take();
        let state = self
            .state
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("runtime state lock poisoned".into()))?
            .take();
        if let Some(state) = state {
            self.shutdown_listener(state);
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
        Ok(())
    }

    /// 返回 native QUIC endpoint 实际绑定的 UDP 端口。
    ///
    /// 该值只用于受控测试和诊断；调用方不会获得 socket 或 Quinn handle。
    pub fn bound_local_port(&self) -> Option<u16> {
        let port = self.bound_port.load(Ordering::Acquire);
        (port != 0).then_some(port)
    }

    /// 返回原生轮询边界使用的 Tokio handle。
    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }

    /// 运行时处于 Running 时入队一个 V2 命令。
    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(NetworkError::RuntimeNotRunning);
        }
        let sender = self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .as_ref()
            .ok_or(NetworkError::RuntimeNotRunning)?
            .clone();
        sender.try_send(command).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => {
                NetworkError::CommandQueueFailed("command mailbox is full".into())
            }
            mpsc::error::TrySendError::Closed(_) => {
                NetworkError::CommandQueueFailed("command mailbox is closed".into())
            }
        })
    }

    /// 轮询一个事件，但不向调用方暴露内部 receiver。
    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut receiver = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            receiver.try_recv()
        } else {
            let handle = self.runtime.handle();
            let _guard = handle.enter();
            handle
                .block_on(tokio::time::timeout(
                    Duration::from_millis(timeout_ms as u64),
                    receiver.recv(),
                ))
                .ok()?
        }
    }

    /// 为原生测试和受控集成注入一个事件。
    pub fn emit_event(&self, event: NetworkEvent) {
        let _ = self.event_tx.send(event);
    }

    /// Cancel the root, close every native I/O owner, then await every task
    /// registered in the supervisor before releasing the runtime state.
    fn shutdown_listener(&self, state: Arc<RuntimeState>) {
        self.runtime.block_on(async move {
            state.task_supervisor.cancel_root();
            state.peer_supervisors.stop_all();
            state.close_all_transport_paths().await;
            // 控制面 Drop 会中止后台读写 worker（RelayControlClient::drop）；显式
            // take 释放共享引用即可。
            state.relay_control.write().await.take();
            state.realtime.lock().await.close_all();
            if let Some(endpoint) = state.endpoint.write().await.take() {
                endpoint.close(quinn::VarInt::from_u32(0), b"runtime stopping");
            }
            state.task_supervisor.shutdown().await;
        });
    }

    /// 仅测试用：为当前 Peer 显式驱动一次确定性 recovery，返回其 wire key。
    ///
    /// 测试在连接保持稳定时显式重放未 ACK 消息，验证接收端按 MessageId 去重。
    /// 重放会以当前 ConnectionSession 重新编码发送（§20），不依赖生产重连路径。
    #[cfg(test)]
    pub(crate) fn recover_current_peer_for_test(&self, peer_id: &str) -> Option<String> {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        self.runtime.block_on(async move {
            let session_id = state
                .connection_sessions
                .current_session_id(peer_id)
                .await?;
            let wire_key = session_id.wire_key();
            crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
            Some(wire_key)
        })
    }
}

/// Rust 侧最终销毁时中止仍存在的 supervised tasks。
impl Drop for NetworkRuntime {
    /// 中止在显式停止转换后仍存活的 tasks。
    fn drop(&mut self) {
        if let Ok(mut sender) = self.command_tx.lock() {
            sender.take();
        }
        if let Ok(mut state) = self.state.lock() {
            if let Some(state) = state.take() {
                if let Ok(mut endpoint) = state.endpoint.try_write() {
                    if let Some(endpoint) = endpoint.take() {
                        endpoint.close(quinn::VarInt::from_u32(0), b"runtime dropped");
                    }
                }
                if let Ok(mut realtime) = state.realtime.try_lock() {
                    realtime.close_all();
                }
                state.peer_supervisors.stop_all();
                state.task_supervisor.abort_all_now();
            }
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::{PeerId, PeerPathManager};
    use crate::connection::{ConnectionProfile, Route, RouteTransport};
    use std::sync::atomic::AtomicU16;
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn runtime_path_projection_is_non_owning() {
        let (event_tx, _event_rx) = mpsc::unbounded_channel();
        let state = RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0)));
        let peer_id = "projection-peer";
        let session_id = SessionId::new();
        state
            .connection_sessions
            .register_pending_session(peer_id, session_id)
            .await
            .expect("register session");

        let mut manager = PeerPathManager::new(
            PeerId::new(peer_id).expect("peer id"),
            Arc::clone(&state.ready_paths),
        );
        let handle = manager
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
            .expect("publish path");
        let projection = manager.projection(&handle).expect("projection");
        state
            .peer_path_managers
            .write()
            .await
            .insert(peer_id.to_string(), Arc::new(Mutex::new(manager)));
        state.path_projections.write().await.insert(
            peer_id.to_string(),
            vec![OwnedPathProjection {
                session_id,
                projection: projection.clone(),
            }],
        );

        assert!(state.path_is_connected(peer_id).await);
        state.peer_path_managers.write().await.remove(peer_id);
        assert!(
            !projection.is_alive(),
            "projection must not own the carrier"
        );
    }
}
