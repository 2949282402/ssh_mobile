//! V2 网络运行时生命周期、共享状态与命令/事件通道。

use network_protocol::{NetworkCommand, NetworkEvent};
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
use crate::crypto::{CryptoContext, CryptoError, SessionCryptoManager};
use crate::crypto_handshake::{
    RelayResponderConfirmation, RelayResponderHandshake, SessionCryptoMaterial,
};
use crate::delivery::DeliveryManager;
use crate::errors::NetworkError;
use crate::session::{
    ConnectDecision, ConnectionAdmission, ConnectionAdmissionError, ConnectionAdmissionOutcome,
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
/// Native events are drained by FFI polling and must remain bounded even when
/// the mobile consumer is temporarily paused.
pub(crate) const EVENT_MAILBOX_CAPACITY: usize = 512;
pub(crate) const MAX_EVENT_QUEUE_BYTES: usize = 12 * 1024 * 1024;
pub(crate) const MAX_EVENT_BYTES: usize = 1024 * 1024;

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
        sender: mpsc::Sender<NetworkEvent>,
        queued_bytes: Arc<AtomicUsize>,
    },
    #[cfg(test)]
    Unbounded(tokio::sync::mpsc::UnboundedSender<NetworkEvent>),
}

pub(crate) struct EventReceiver {
    receiver: mpsc::Receiver<NetworkEvent>,
    queued_bytes: Arc<AtomicUsize>,
}

impl EventSender {
    pub(crate) fn send(&self, event: NetworkEvent) -> Result<(), ()> {
        let bytes = event.encoded_len();
        if bytes > MAX_EVENT_BYTES {
            return Err(());
        }
        match self {
            Self::Bounded {
                sender,
                queued_bytes,
            } => {
                let mut current = queued_bytes.load(Ordering::Acquire);
                loop {
                    let next = current.saturating_add(bytes);
                    if next > MAX_EVENT_QUEUE_BYTES {
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
        self.queued_bytes
            .fetch_sub(event.encoded_len(), Ordering::AcqRel);
    }

    fn try_recv(&mut self) -> Option<NetworkEvent> {
        let event = self.receiver.try_recv().ok()?;
        self.release(&event);
        Some(event)
    }

    async fn recv(&mut self) -> Option<NetworkEvent> {
        let event = self.receiver.recv().await?;
        self.release(&event);
        Some(event)
    }
}

fn bounded_event_channel() -> (EventSender, EventReceiver) {
    let (sender, receiver) = mpsc::channel(EVENT_MAILBOX_CAPACITY);
    let queued_bytes = Arc::new(AtomicUsize::new(0));
    (
        EventSender::Bounded {
            sender,
            queued_bytes: Arc::clone(&queued_bytes),
        },
        EventReceiver {
            receiver,
            queued_bytes,
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
    /// transport-network v2：reservation 作用域的 Relay v2 数据面客户端（§25/§31）。
    ///
    /// 由 `ConnectivityAttemptCoordinator::connect_relay_fallback`（发起方）或控制面
    /// `IncomingRelayReservation`（应答方）建立；文件/流/消息数据经它转发。
    /// 活跃 reservation 数据面客户端，按对端 device_id 索引（§25 每条 reservation
    /// 数据面相互独立，一个对端的关闭不得切断另一个对端的活跃连接）。
    pub(crate) relay_data: RwLock<HashMap<String, Arc<RelayDataClient>>>,
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
    pub(crate) ready_paths: crate::connect::PathRegistry,
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
            relay_data: RwLock::new(HashMap::new()),
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
            ready_paths: crate::connect::PathRegistry::new(),
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
        required_capabilities: u8,
    ) -> ConnectDecision {
        // Session admission owns transport lifecycle only. A business
        // capability is selected by the caller's path/attempt; it must not
        // cause a healthy Connected session to be closed and replaced.
        self.connection_sessions
            .begin_connect_with_capability(peer_id, required_capabilities)
            .await
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
        let outcome: ConnectionAdmissionOutcome = self
            .connection_sessions
            .admit_authenticated_session_with_capability(
                peer_id,
                expected_session_id,
                remote_session_binding,
                candidate_capabilities,
            )
            .await?;
        let ConnectionAdmissionOutcome {
            admission,
            detached_route,
        } = outcome;
        if let Some(detached_route) = detached_route {
            detached_route.close().await;
        }
        if let Some(replaced_session_id) = admission.replaced_session_id {
            self.cancel_session_tasks(peer_id, replaced_session_id)
                .await;
        }
        Ok(ConnectionAdmissionLease::new(admission))
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
            let relay_data = state.relay_data.write().await.drain().collect::<Vec<_>>();
            for (_, relay_data) in relay_data {
                relay_data.request_disconnect().await;
            }
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
                if let Ok(mut relay_data) = state.relay_data.try_write() {
                    relay_data.clear();
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
