//! v1 网络运行时生命周期、共享状态与命令/事件通道。

use network_protocol::{NetworkCommand, NetworkEvent};
use std::sync::{
    atomic::{AtomicU8, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{
    mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
    oneshot, Mutex as AsyncMutex, RwLock,
};
use tracing::info;

use crate::commands::run_command_worker;
use crate::delivery::DeliveryManager;
use crate::errors::NetworkError;
use crate::session::{SessionId, SessionManager};
use network_identity::DeviceIdentity;
use network_nat::PathManager;
use network_relay::RelayClient;
use network_transfer::TransferManager;
use quinn::Endpoint;
#[cfg(test)]
use quinn::VarInt;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;

pub(crate) const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const RELAY_RACE_DELAY: Duration = Duration::from_millis(500);
pub(crate) const RECONNECT_MAX_ATTEMPTS: usize = 5;
pub(crate) const RECONNECT_INITIAL_BACKOFF: Duration = Duration::from_millis(250);
pub(crate) const RECONNECT_MAX_BACKOFF: Duration = Duration::from_secs(5);
pub(crate) const INCOMING_APPROVAL_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const TRANSFER_COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const MAX_PENDING_INCOMING_TRANSFERS: usize = 64;
pub(crate) const DELIVERY_RETRY_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(crate) const RUNTIME_CREATED: u8 = 0;
pub(crate) const RUNTIME_RUNNING: u8 = 1;
pub(crate) const RUNTIME_STOPPING: u8 = 2;
pub(crate) const RUNTIME_STOPPED: u8 = 3;

#[derive(Clone)]
pub(crate) struct PeerConfig {
    pub(crate) endpoint: Option<SocketAddr>,
    pub(crate) identity_public_key: [u8; 32],
    pub(crate) e2e_public_key: [u8; 32],
}

pub(crate) struct RuntimeState {
    pub(crate) endpoint: RwLock<Option<Endpoint>>,
    pub(crate) identity: RwLock<Option<Arc<DeviceIdentity>>>,
    pub(crate) receive_directory: RwLock<Option<PathBuf>>,
    pub(crate) local_path_manager: RwLock<Option<Arc<PathManager>>>,
    pub(crate) peers: RwLock<HashMap<String, PeerConfig>>,
    pub(crate) path_managers: RwLock<HashMap<String, Arc<PathManager>>>,
    pub(crate) trusted_peer_keys: RwLock<HashMap<String, [u8; 32]>>,
    pub(crate) sessions: SessionManager,
    pub(crate) delivery: DeliveryManager,
    pub(crate) delivery_tasks: RwLock<HashMap<String, SessionId>>,
    pub(crate) reconnect_tasks: RwLock<HashMap<String, SessionId>>,
    pub(crate) relay: RwLock<Option<Arc<RelayClient>>>,
    pub(crate) relay_config: RwLock<Option<crate::relay::RelayReconnectConfig>>,
    pub(crate) relay_reconnect_task: AsyncMutex<Option<tokio::task::JoinHandle<()>>>,
    pub(crate) relay_acceptances:
        RwLock<HashMap<String, oneshot::Sender<Option<crate::relay::RelayAcceptance>>>>,
    pub(crate) relay_completions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) relay_lookups: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) relay_sessions: RwLock<HashMap<String, String>>,
    pub(crate) relay_pending_incoming: RwLock<HashMap<String, crate::relay::PendingRelayIncoming>>,
    pub(crate) relay_active_incoming:
        AsyncMutex<HashMap<String, crate::relay::ActiveRelayIncoming>>,
    pub(crate) incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    pub(crate) transfers: TransferManager,
    pub(crate) event_tx: UnboundedSender<NetworkEvent>,
}

impl RuntimeState {
    /// 创建由一个已启动 worker 拥有的空运行时状态。
    pub(crate) fn new(event_tx: UnboundedSender<NetworkEvent>) -> Self {
        Self {
            endpoint: RwLock::new(None),
            identity: RwLock::new(None),
            receive_directory: RwLock::new(None),
            local_path_manager: RwLock::new(None),
            peers: RwLock::new(HashMap::new()),
            path_managers: RwLock::new(HashMap::new()),
            trusted_peer_keys: RwLock::new(HashMap::new()),
            sessions: SessionManager::new(),
            delivery: DeliveryManager::new(),
            delivery_tasks: RwLock::new(HashMap::new()),
            reconnect_tasks: RwLock::new(HashMap::new()),
            relay: RwLock::new(None),
            relay_config: RwLock::new(None),
            relay_reconnect_task: AsyncMutex::new(None),
            relay_acceptances: RwLock::new(HashMap::new()),
            relay_completions: RwLock::new(HashMap::new()),
            relay_lookups: RwLock::new(HashMap::new()),
            relay_sessions: RwLock::new(HashMap::new()),
            relay_pending_incoming: RwLock::new(HashMap::new()),
            relay_active_incoming: AsyncMutex::new(HashMap::new()),
            incoming_decisions: RwLock::new(HashMap::new()),
            transfers: TransferManager::new(),
            event_tx,
        }
    }
}

/// 管理 Tokio 异步运行时生命周期与命令/事件通道。
pub struct NetworkRuntime {
    pub(crate) runtime: Arc<Runtime>,
    pub(crate) command_tx: Mutex<Option<UnboundedSender<NetworkCommand>>>,
    pub(crate) worker_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub(crate) event_rx: Arc<Mutex<UnboundedReceiver<NetworkEvent>>>,
    pub(crate) event_tx: UnboundedSender<NetworkEvent>,
    pub(crate) lifecycle: AtomicU8,
    #[cfg(test)]
    test_state: Mutex<Option<Arc<RuntimeState>>>,
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
        info!("NetworkRuntime initialized successfully");
        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx: Mutex::new(None),
            worker_task: Mutex::new(None),
            event_rx: Arc::new(Mutex::new(event_rx)),
            event_tx,
            lifecycle: AtomicU8::new(RUNTIME_CREATED),
            #[cfg(test)]
            test_state: Mutex::new(None),
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
        let state = Arc::new(RuntimeState::new(self.event_tx.clone()));
        self.store_test_state(Arc::clone(&state))?;
        let worker = self.runtime.spawn(run_command_worker(command_rx, state));
        *self
            .command_tx
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("command lock poisoned".into()))? =
            Some(command_tx);
        *self
            .worker_task
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("worker lock poisoned".into()))? =
            Some(worker);
        Ok(())
    }

    /// 恰好停止 worker 一次；重复调用仍然成功。
    pub fn stop(&self) -> Result<(), NetworkError> {
        let current = self.lifecycle.load(Ordering::Acquire);
        if current == RUNTIME_CREATED || current == RUNTIME_STOPPED {
            self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
            return Ok(());
        }
        if current == RUNTIME_STOPPING {
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
        let worker = self
            .worker_task
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("worker lock poisoned".into()))?
            .take();
        if let Some(worker) = worker {
            self.runtime.block_on(async {
                worker.abort();
                let _ = worker.await;
            });
        }
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
        Ok(())
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

    #[cfg(test)]
    fn store_test_state(&self, state: Arc<RuntimeState>) -> Result<(), NetworkError> {
        *self
            .test_state
            .lock()
            .map_err(|_| NetworkError::CommandQueueFailed("test state lock poisoned".into()))? =
            Some(state);
        Ok(())
    }

    #[cfg(not(test))]
    fn store_test_state(&self, _state: Arc<RuntimeState>) -> Result<(), NetworkError> {
        Ok(())
    }

    /// 只供 network-core 集成测试模拟底层 Connection 断开；生产 API 不暴露
    /// Quinn handle，也不允许业务层绕过 Session/Delivery 生命周期。
    #[cfg(test)]
    pub(crate) fn close_peer_connection_for_test(&self, peer_id: &str) {
        let state = self
            .test_state
            .lock()
            .expect("test state lock")
            .clone()
            .expect("runtime test state");
        self.runtime.block_on(async move {
            if let Some(connection) = state.sessions.current_connection(peer_id).await {
                connection.close(VarInt::from_u32(0), b"test transport interruption");
            }
        });
    }
}

/// Rust 侧最终销毁时中止仍存在的 worker。
impl Drop for NetworkRuntime {
    /// 中止在显式停止转换后仍存活的 worker。
    fn drop(&mut self) {
        if let Ok(mut sender) = self.command_tx.lock() {
            sender.take();
        }
        if let Ok(mut worker) = self.worker_task.lock() {
            if let Some(worker) = worker.take() {
                worker.abort();
            }
        }
        self.lifecycle.store(RUNTIME_STOPPED, Ordering::Release);
    }
}
