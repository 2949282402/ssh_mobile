//! v1 网络运行时生命周期、共享状态与命令/事件通道。

use network_protocol::{NetworkCommand, NetworkErrorCode, NetworkEvent};
use std::sync::{
    atomic::{AtomicBool, AtomicU16, AtomicU8, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::{
    mpsc::{self, unbounded_channel, UnboundedReceiver, UnboundedSender},
    oneshot, Mutex as AsyncMutex, Notify, RwLock,
};
use tracing::info;

use crate::commands::run_command_worker;
use crate::crypto::{CryptoContext, CryptoError, CryptoMode, SessionCryptoManager};
use crate::crypto_handshake::{
    RelayResponderConfirmation, RelayResponderHandshake, SessionCryptoMaterial,
};
use crate::delivery::DeliveryManager;
use crate::errors::NetworkError;
use crate::session::{
    SessionAdmission, SessionAdmissionError, SessionAdmissionOutcome, SessionCryptoDecision,
    SessionId, SessionManager,
};
use crate::task_supervisor::{RuntimeTaskSupervisor, TaskId};
use network_identity::DeviceIdentity;
use network_nat::PathManager;
use network_relay::RelayClient;
use network_transfer::{TransferFailureReason, TransferManager};
use quinn::Endpoint;
use std::collections::HashMap;
#[cfg(test)]
use std::collections::HashSet;
use std::net::SocketAddr;
use std::path::PathBuf;

pub(crate) const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const DEFAULT_CANDIDATE_CONNECT_WINDOW: Duration =
    Duration::from_millis(network_nat::DEFAULT_CONNECT_WINDOW_MS as u64);
pub(crate) const RELAY_RACE_DELAY: Duration = Duration::from_millis(500);
pub(crate) const RECONNECT_MAX_ATTEMPTS: usize = 5;
pub(crate) const RECONNECT_INITIAL_BACKOFF: Duration = Duration::from_millis(250);
pub(crate) const RECONNECT_MAX_BACKOFF: Duration = Duration::from_secs(5);
pub(crate) const INCOMING_APPROVAL_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const TRANSFER_COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const MAX_PENDING_INCOMING_TRANSFERS: usize = 64;
pub(crate) const MAX_PENDING_RELAY_CRYPTO_HANDSHAKES: usize = 64;
pub(crate) const DELIVERY_RETRY_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(crate) const RUNTIME_CREATED: u8 = 0;
pub(crate) const RUNTIME_RUNNING: u8 = 1;
pub(crate) const RUNTIME_STOPPING: u8 = 2;
pub(crate) const RUNTIME_STOPPED: u8 = 3;

/// Non-Copy cleanup lease for an authenticated Session admission.  A replaced
/// Session's task group is canceled only after the new route commits.  If the
/// handshake or attach path drops this lease first, the fallback cancellation
/// is scheduled as a runtime-scoped task so an old Session task never awaits
/// its own group.
pub(crate) struct SessionAdmissionLease {
    admission: SessionAdmission,
    supervisor: Arc<RuntimeTaskSupervisor>,
    armed: bool,
}

impl SessionAdmissionLease {
    fn new(admission: SessionAdmission, supervisor: Arc<RuntimeTaskSupervisor>) -> Self {
        Self {
            admission,
            supervisor,
            armed: true,
        }
    }

    /// Disarm the failure cleanup after the new route is fully attached and
    /// all post-attach initialization has succeeded.
    pub(crate) fn finalize(mut self) {
        self.armed = false;
    }

    fn schedule_abort(&self) {
        let Some(replaced_session_id) = self.admission.replaced_session_id else {
            return;
        };
        let spawn_supervisor = Arc::clone(&self.supervisor);
        let cancel_supervisor = Arc::clone(&self.supervisor);
        let session_key = replaced_session_id.wire_key();
        let _ = spawn_supervisor.spawn_runtime("abort-session-admission", async move {
            cancel_supervisor.cancel_session(&session_key).await;
        });
    }
}

impl std::ops::Deref for SessionAdmissionLease {
    type Target = SessionAdmission;

    fn deref(&self) -> &Self::Target {
        &self.admission
    }
}

impl Drop for SessionAdmissionLease {
    fn drop(&mut self) {
        if self.armed {
            self.schedule_abort();
        }
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

/// One locally initiated candidate-exchange window. The attempt ID is kept
/// outside PathManager so an old Relay answer cannot authorize a new QUIC
/// connectivity check.
#[derive(Clone, Debug)]
pub(crate) struct CandidateAttempt {
    pub(crate) attempt_id: String,
    pub(crate) generation: u64,
    pub(crate) connect_window: Duration,
    pub(crate) expires_at: Instant,
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
    pub(crate) path_managers: RwLock<HashMap<String, Arc<PathManager>>>,
    pub(crate) candidate_attempts: RwLock<HashMap<String, CandidateAttempt>>,
    pub(crate) trusted_peer_keys: RwLock<HashMap<String, [u8; 32]>>,
    pub(crate) sessions: SessionManager,
    /// Session-owned application crypto. Route changes do not replace this
    /// manager; explicit Session close removes the corresponding context.
    pub(crate) crypto: SessionCryptoManager,
    pub(crate) delivery: DeliveryManager,
    pub(crate) realtime: AsyncMutex<crate::realtime::RealtimeManager>,
    pub(crate) delivery_tasks: RwLock<HashMap<String, SessionId>>,
    pub(crate) reconnect_tasks: RwLock<HashMap<String, SessionId>>,
    #[cfg(test)]
    pub(crate) reconnect_disabled_peers: Mutex<HashSet<String>>,
    pub(crate) direct_upgrade_tasks: RwLock<HashMap<String, SessionId>>,
    pub(crate) relay: RwLock<Option<Arc<RelayClient>>>,
    pub(crate) relay_config: RwLock<Option<crate::relay::RelayReconnectConfig>>,
    pub(crate) relay_reconnect_task: Mutex<Option<TaskId>>,
    pub(crate) relay_reconnect_active: AtomicBool,
    /// 当前 Relay 凭据已被服务端判定过期/冲突；在 Dart 下发新的
    /// ConfigureRelayCommand 前抑制所有自动重连。
    pub(crate) relay_credential_stale: AtomicBool,
    pub(crate) relay_acceptances:
        RwLock<HashMap<String, oneshot::Sender<Option<crate::relay::RelayAcceptance>>>>,
    pub(crate) relay_completions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) relay_lookups: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) relay_crypto_waiters: RwLock<HashMap<String, RelayCryptoSender>>,
    pub(crate) relay_crypto_responders: AsyncMutex<HashMap<String, RelayResponderHandshake>>,
    pub(crate) relay_crypto_confirmers:
        AsyncMutex<HashMap<String, RelayResponderConfirmation<SessionAdmissionLease>>>,
    pub(crate) candidate_signal_notify: Notify,
    pub(crate) relay_sessions: RwLock<HashMap<String, String>>,
    pub(crate) relay_pending_incoming: RwLock<HashMap<String, crate::relay::PendingRelayIncoming>>,
    pub(crate) relay_active_incoming:
        AsyncMutex<HashMap<String, crate::relay::ActiveRelayIncoming>>,
    pub(crate) incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) transfers: TransferManager,
    pub(crate) event_tx: UnboundedSender<NetworkEvent>,
    pub(crate) task_supervisor: Arc<RuntimeTaskSupervisor>,
}

impl RuntimeState {
    /// 创建由一个已启动 worker 拥有的空运行时状态。
    pub(crate) fn new(event_tx: UnboundedSender<NetworkEvent>, bound_port: Arc<AtomicU16>) -> Self {
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
            path_managers: RwLock::new(HashMap::new()),
            candidate_attempts: RwLock::new(HashMap::new()),
            trusted_peer_keys: RwLock::new(HashMap::new()),
            sessions: SessionManager::new(),
            crypto: SessionCryptoManager::new(),
            delivery: DeliveryManager::new(),
            realtime: AsyncMutex::new(crate::realtime::RealtimeManager::default()),
            delivery_tasks: RwLock::new(HashMap::new()),
            reconnect_tasks: RwLock::new(HashMap::new()),
            #[cfg(test)]
            reconnect_disabled_peers: Mutex::new(HashSet::new()),
            direct_upgrade_tasks: RwLock::new(HashMap::new()),
            relay: RwLock::new(None),
            relay_config: RwLock::new(None),
            relay_reconnect_task: Mutex::new(None),
            relay_reconnect_active: AtomicBool::new(false),
            relay_credential_stale: AtomicBool::new(false),
            relay_acceptances: RwLock::new(HashMap::new()),
            relay_completions: RwLock::new(HashMap::new()),
            relay_lookups: RwLock::new(HashMap::new()),
            relay_crypto_waiters: RwLock::new(HashMap::new()),
            relay_crypto_responders: AsyncMutex::new(HashMap::new()),
            relay_crypto_confirmers: AsyncMutex::new(HashMap::new()),
            candidate_signal_notify: Notify::new(),
            relay_sessions: RwLock::new(HashMap::new()),
            relay_pending_incoming: RwLock::new(HashMap::new()),
            relay_active_incoming: AsyncMutex::new(HashMap::new()),
            incoming_decisions: RwLock::new(HashMap::new()),
            transfers: TransferManager::new(),
            event_tx,
            task_supervisor: RuntimeTaskSupervisor::new(),
        }
    }

    async fn retire_session_resources(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        // Retire aliases and task indexes before awaiting the old task group.
        // A reconnect/receiver task may be inside a bounded I/O wait; the
        // replacement Session must become cryptographically isolated without
        // waiting for that transport task to finish unwinding.
        self.crypto.remove_session(peer_id, &session_key);
        self.delivery_tasks
            .write()
            .await
            .retain(|_, current| *current != session_id);
        self.reconnect_tasks
            .write()
            .await
            .retain(|_, current| *current != session_id);
        self.direct_upgrade_tasks
            .write()
            .await
            .retain(|_, current| *current != session_id);
        self.candidate_attempts.write().await.remove(peer_id);
        let terminated_transfers = self
            .transfers
            .terminate_session_transfers(
                peer_id,
                &session_key,
                TransferFailureReason::SessionReplaced,
            )
            .await;
        for transfer in terminated_transfers {
            self.incoming_decisions
                .write()
                .await
                .remove(&transfer.transfer_id);
            crate::relay::cancel_transfer(self, &transfer.transfer_id).await;
            crate::events::emit_transfer_error(
                &self.event_tx,
                &transfer.transfer_id,
                NetworkErrorCode::Cancelled,
                "transfer terminated because the peer Session was replaced".to_string(),
                "session_replace",
                Some(peer_id),
            );
        }
        self.delivery.close_session(&session_key).await;
    }

    pub(crate) async fn cancel_session_tasks(&self, peer_id: &str, session_id: SessionId) {
        let session_key = session_id.wire_key();
        self.retire_session_resources(peer_id, session_id).await;
        self.task_supervisor.cancel_session(&session_key).await;
    }

    /// Admit authenticated Noise material only after Session continuity has
    /// been evaluated. A changed remote binding retires the old Session's
    /// aliases and receive-side Delivery state before the new crypto context
    /// is installed; task cancellation is deferred until the replacement
    /// route has attached.
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        remote_session_binding: &str,
    ) -> Result<SessionAdmissionLease, SessionAdmissionError> {
        let outcome: SessionAdmissionOutcome = self
            .sessions
            .admit_authenticated_session(peer_id, expected_session_id, remote_session_binding)
            .await?;
        let SessionAdmissionOutcome {
            admission,
            detached_route,
        } = outcome;
        if let Some(detached_route) = detached_route {
            detached_route.close().await;
        }
        if let Some(replaced_session_id) = admission.replaced_session_id {
            self.retire_session_resources(peer_id, replaced_session_id)
                .await;
        }
        Ok(SessionAdmissionLease::new(
            admission,
            Arc::clone(&self.task_supervisor),
        ))
    }

    /// Finish cancellation only after the winning replacement route has been
    /// attached. A reconnect task can itself be the handshake that discovers
    /// the peer restart; canceling its old Session group before it installs the
    /// new route would abort the successful handshake midway.
    pub(crate) fn finish_session_replacement(&self, admission: SessionAdmissionLease) {
        let Some(replaced_session_id) = admission.replaced_session_id else {
            admission.finalize();
            return;
        };
        let supervisor = Arc::clone(&self.task_supervisor);
        let session_key = replaced_session_id.wire_key();
        admission.finalize();
        let _ = self
            .task_supervisor
            .spawn_runtime("cancel-replaced-session", async move {
                supervisor.cancel_session(&session_key).await;
            });
    }

    pub(crate) async fn crypto_context(
        &self,
        peer_id: &str,
        session_id: &str,
        mode: CryptoMode,
    ) -> Result<Option<Arc<Mutex<CryptoContext>>>, CryptoError> {
        if mode == CryptoMode::None {
            return Ok(None);
        }
        self.crypto.get(peer_id, session_id).map(Some)
    }

    pub(crate) fn install_crypto_material(
        &self,
        peer_id: &str,
        session_id: &str,
        material: &SessionCryptoMaterial,
        decision: SessionCryptoDecision,
    ) -> Result<(), CryptoError> {
        self.crypto
            .install_material_aliases(
                peer_id,
                &[session_id, material.remote_session_binding.as_str()],
                material.root_key,
                material.initiator,
                decision,
            )
            .map(|_| ())
    }

    pub(crate) async fn encrypt_application_payload(
        &self,
        peer_id: &str,
        session_id: &str,
        mode: CryptoMode,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let Some(context) = self.crypto_context(peer_id, session_id, mode).await? else {
            return Ok(plaintext.to_vec());
        };
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
        mode: CryptoMode,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let Some(context) = self.crypto_context(peer_id, session_id, mode).await? else {
            return Ok(envelope.to_vec());
        };
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
        mode: CryptoMode,
        aad: &[u8],
        envelope: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let Some(context) = self.crypto_context(peer_id, session_id, mode).await? else {
            return Ok(envelope.to_vec());
        };
        let result = context
            .lock()
            .map_err(|_| CryptoError::StateUnavailable)?
            .decrypt_for_delivery(aad, envelope);
        result
    }
}

/// 管理 Tokio 异步运行时生命周期与命令/事件通道。
pub struct NetworkRuntime {
    pub(crate) runtime: Arc<Runtime>,
    pub(crate) command_tx: Mutex<Option<UnboundedSender<NetworkCommand>>>,
    pub(crate) event_rx: Arc<Mutex<UnboundedReceiver<NetworkEvent>>>,
    pub(crate) event_tx: UnboundedSender<NetworkEvent>,
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
        let (event_tx, event_rx) = unbounded_channel::<NetworkEvent>();
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
        let (command_tx, command_rx) = unbounded_channel::<NetworkCommand>();
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

    /// 运行时处于 Running 时入队一个 v1 命令。
    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        if self.lifecycle.load(Ordering::Acquire) != RUNTIME_RUNNING {
            return Err(NetworkError::RuntimeNotRunning);
        }
        self.command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))?
            .as_ref()
            .ok_or(NetworkError::RuntimeNotRunning)?
            .send(command)
            .map_err(|error| NetworkError::CommandQueueFailed(error.to_string()))
    }

    /// 轮询一个事件，但不向调用方暴露内部 receiver。
    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut receiver = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            receiver.try_recv().ok()
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
            let relay = state.relay.write().await.take();
            if let Some(relay) = relay {
                relay.request_disconnect().await;
            }
            state.realtime.lock().await.close_all();
            if let Some(endpoint) = state.endpoint.write().await.take() {
                endpoint.close(quinn::VarInt::from_u32(0), b"runtime stopping");
            }
            state.task_supervisor.shutdown().await;
        });
    }

    /// 仅测试用：强制关闭当前 peer 的 active transport Connection/route，
    /// 但不关闭逻辑 Session，从而驱动生产自动重连路径。
    ///
    /// 与 `disconnect_peer` 不同（那会 `SessionManager::close` + 清空接收态），
    /// 这里只中断底层 transport，让 `handle_connection_disconnect` →
    /// `schedule_reconnect` → `reconnect_loop` 走真实的重连 + Delivery Recovery。
    #[cfg(test)]
    pub(crate) fn close_peer_connection_for_test(&self, peer_id: &str) {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        self.runtime.block_on(async move {
            if let Some(route) = state.sessions.current_active_route(peer_id).await {
                route.close_for_test().await;
            }
        });
    }

    /// 仅测试用：禁用指定 peer 的自动重连。
    ///
    /// 断网时两端会各自触发自动重连；若两端都重连，新建连接会互相替换，
    /// 替换会再次关闭对端连接并重新调度重连，形成连接 ping-pong 与并发
    /// `recover_session` epoch 风暴，使测试无法确定收敛。需要隔离单侧重连
    /// 路径的测试（如 delivery-recovery 集成测试）可对被动端禁用自动重连，
    /// 让主动端单独走真实 `reconnect_loop`。
    #[cfg(test)]
    pub(crate) fn disable_peer_reconnect_for_test(&self, peer_id: &str) {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        state
            .reconnect_disabled_peers
            .lock()
            .expect("reconnect disabled peers lock")
            .insert(peer_id.to_string());
    }

    /// 仅测试用：为当前 Session 显式驱动一次确定性 recovery，返回其 wire key。
    ///
    /// 测试在连接保持稳定时显式重放未 ACK 消息，验证 dedup 与显式 ACK 使用
    /// 当前 recovery epoch。避免依赖生产重连路径：重连可能触发会话 crypto
    /// 换代（ReplaceWithNew），使以旧 crypto 加密的重放无法解密而静默丢失。
    #[cfg(test)]
    pub(crate) fn recover_current_session_for_test(&self, peer_id: &str) -> Option<String> {
        let state = self
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        self.runtime.block_on(async move {
            let session_id = state.sessions.current_session_id(peer_id).await?;
            let wire_key = session_id.wire_key();
            crate::channel::recover_session(Arc::clone(&state), peer_id.to_string(), session_id)
                .await;
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
                if let Ok(mut relay) = state.relay.try_write() {
                    relay.take();
                }
                if let Ok(mut realtime) = state.realtime.try_lock() {
                    realtime.close_all();
                }
                state.task_supervisor.abort_all_now();
            }
        }
        self.bound_port.store(0, Ordering::Release);
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        self.stop_notify.notify_waiters();
    }
}
