//! transport-network v2：唯一连接入口 `ConnectionOrchestrator`（设计 §11/§12/§14/§15/§37）。
//!
//! 固定状态机（§11）：
//!
//! ```text
//! IDLE → RESOLVING → RESOLVED → COORDINATING → DIRECT_CONNECTING
//!   ├──────────────────────────────→ CONNECTED_DIRECT
//!   ↓
//! DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY
//! ```
//!
//! 不存在 `RECONNECTING` / `DIRECT_UPGRADING` / `PATH_REPAIRING`（§11/§35）。
//!
//! 主链（§37）：
//!
//! 1. **Resolve**（§10）：经 `DiscoveryResolver` 解析对端 4-state；只有 `READY` 允许建连。
//!    控制面不可用时退化为本地直连（LAN / 显式 endpoint），`remote_epoch = None`。
//! 2. **Registry 重用**（§34）：同 epoch + capability 且连接健康 → 重用；新 epoch → 关旧建新。
//! 3. **Create ConnectivityAttempt**（§12）：一次性对象，candidate 完全 attempt-scoped。
//! 4. **Coordinate**（§14）：ConnectivityOffer 经控制面发给对端，按 attempt_id 关联应答；
//!    不阻塞 Direct 窗口。
//! 5. **Direct First 4s**（§15）：并发 Direct 候选，第一个 identity authenticated + E2EE
//!    ready 胜出 → CONNECTED_DIRECT。
//! 6. **Direct Failed → Reserve Relay**（§25/§31）：控制面 `reserve_relay`。
//! 7. **Relay Data** → CONNECTED_RELAY：连接 `/v2/relay/{reservation_id}` 数据面
//!    （`RelayDataClient`），在其上完成 Relay E2EE 握手后挂载 ConnectionSession。

use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::{watch, Mutex};

use network_nat::{
    Candidate, CandidateAdvertisement, CandidateKind, ConnectivityAttempt,
    MAX_CANDIDATES_PER_SIGNAL,
};
use network_protocol::{
    CommunicationClass, NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState,
    RouteType,
};
use network_relay::v2::{DiscoverySnapshot, RuntimeEpoch};
use network_relay::RelayError;
use quinn::VarInt;

use crate::discovery::resolver::{DiscoveryResolver, ResolvedPeer};
use crate::events::{
    emit_peer_state, emit_peer_state_profile, emit_route_changed, emit_route_changed_profile,
    protocol_error_with_peer, protocol_error_with_retry,
};
use crate::peer::{
    connect_direct_or_generic, install_admitted_crypto, ConnectedRoute, DirectRouteAttempt,
};
use crate::runtime::{RuntimeState, SessionAdmissionLease};
use crate::session::{ConnectDecision, SessionId};

use super::{
    communication_class_capability, default_communication_class, profile_capability_mask,
    DEFAULT_CONNECTION_CAPABILITY, DIRECT_CONNECT_WINDOW, RELAY_RESERVE_TIMEOUT, RESOLVE_TIMEOUT,
};

/// 编排器状态机的可观察状态（§11）。`Idle`/`Failed` 是诊断端点（初始/终态），
/// 当前不在 `set_stage` 中显式转换。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum OrchestratorState {
    Idle,
    Resolving,
    Resolved,
    Coordinating,
    DirectConnecting,
    ConnectedDirect,
    DirectFailed,
    RelayReserving,
    RelayConnecting,
    ConnectedRelay,
    Failed,
}

/// 唯一连接入口。
pub(crate) struct ConnectionOrchestrator {
    state: Arc<RuntimeState>,
    /// 当前状态机位置（诊断/测试）。
    stage: std::sync::atomic::AtomicU8,
}

impl ConnectionOrchestrator {
    pub(crate) fn new(state: Arc<RuntimeState>) -> Self {
        Self {
            state,
            stage: std::sync::atomic::AtomicU8::new(0),
        }
    }

    /// 当前状态机阶段。
    #[allow(dead_code)] // 诊断/测试查询面；生产路径通过日志观察状态机
    pub(crate) fn stage(&self) -> OrchestratorState {
        use OrchestratorState::*;
        match self.stage.load(std::sync::atomic::Ordering::Acquire) {
            1 => Resolving,
            2 => Resolved,
            3 => Coordinating,
            4 => DirectConnecting,
            5 => ConnectedDirect,
            6 => DirectFailed,
            7 => RelayReserving,
            8 => RelayConnecting,
            9 => ConnectedRelay,
            10 => Failed,
            _ => Idle,
        }
    }

    fn set_stage(&self, state: OrchestratorState) {
        use OrchestratorState::*;
        let value = match state {
            Idle => 0,
            Resolving => 1,
            Resolved => 2,
            Coordinating => 3,
            DirectConnecting => 4,
            ConnectedDirect => 5,
            DirectFailed => 6,
            RelayReserving => 7,
            RelayConnecting => 8,
            ConnectedRelay => 9,
            Failed => 10,
        };
        self.stage
            .store(value, std::sync::atomic::Ordering::Release);
    }

    /// 建连唯一入口（§37），默认 CommunicationClass=ReliableMessage（§17）。
    /// 成功后返回 `()`；失败返回类型化错误（§33）。
    ///
    /// 这是 FFI 默认路径的便捷入口（命令面经 `connect_with_class` 到达）；
    /// 保留它以让默认调用保持工作。
    #[allow(dead_code)]
    pub(crate) async fn connect(&self, peer_id: &str) -> Result<(), ProtocolError> {
        self.connect_with_class(peer_id, CommunicationClass::ReliableMessage)
            .await
    }

    /// 带 CommunicationClass 的建连入口（§17/§37）。这是 FFI 面向的连接表面：
    /// 调用方指定本次业务所需能力，连接层只用它查询/选择实际 ConnectionProfile；
    /// ConnectionSession 不保存最近一次业务类别。
    pub(crate) async fn connect_with_class(
        &self,
        peer_id: &str,
        class: CommunicationClass,
    ) -> Result<(), ProtocolError> {
        let class = default_communication_class(class);
        let state = Arc::clone(&self.state);
        // 配置/身份/对端校验。
        let endpoint = state.endpoint.read().await.clone().ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "runtime is not configured",
                "connect",
                peer_id,
            )
        })?;
        let identity = state.identity.read().await.clone().ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "runtime is not configured",
                "connect",
                peer_id,
            )
        })?;
        let peer = state
            .peers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "peer has no configured route",
                    "connect",
                    peer_id,
                )
            })?;

        // -----------------------------------------------------------------
        // 1. RESOLVING（§10）：Resolve 是每次建连前的权威入口。
        // -----------------------------------------------------------------
        self.set_stage(OrchestratorState::Resolving);
        let resolved = self.resolve(peer_id, &peer).await?;
        self.set_stage(OrchestratorState::Resolved);

        let remote_epoch = resolved_runtime_epoch(&resolved);
        let capability = communication_class_capability(class);

        // -----------------------------------------------------------------
        // 2. Registry 重用（§34）。
        // -----------------------------------------------------------------
        if let Some(reused) = self.try_reuse(peer_id, &remote_epoch, capability).await? {
            tracing::info!(
                peer_id = %peer_id,
                session = ?reused,
                "reused existing healthy connection"
            );
            // 重用成功同样发布 Connected 终态：Dart connect() 把该事件当作成功信号
            // （失败才由命令面发 Failed），不发布会令其等待超时。
            let route = state
                .sessions
                .current_route(peer_id)
                .await
                .unwrap_or(RouteType::Unspecified);
            emit_peer_state(
                &state.event_tx,
                peer_id,
                PeerConnectionState::Connected,
                route,
                None,
            );
            self.set_stage(OrchestratorState::ConnectedDirect);
            return Ok(());
        }

        // -----------------------------------------------------------------
        // 3. Session 门控：同 peer 并发 connect 合并（§40 Concurrency）。
        // -----------------------------------------------------------------
        let session_id = match state.sessions.begin_connect(peer_id).await {
            ConnectDecision::AlreadyConnected(session_id) => {
                // 有健康连接但未登记（例如被动端 accept 建立的 Session）→ 登记并重用。
                self.register_current(state.clone(), peer_id, &remote_epoch, session_id)
                    .await;
                // 已连接会话满足一次新的 connect()：同样发布 Connected 终态，
                // 否则 Dart connect() 的成功信号会缺失。
                let route = state
                    .sessions
                    .current_route(peer_id)
                    .await
                    .unwrap_or(RouteType::Unspecified);
                emit_peer_state(
                    &state.event_tx,
                    peer_id,
                    PeerConnectionState::Connected,
                    route,
                    None,
                );
                self.set_stage(OrchestratorState::ConnectedDirect);
                return Ok(());
            }
            ConnectDecision::InProgress(_) => {
                // 已有连接任务在途：合并，不做重复建连；每个调用方的 required
                // capability 只影响自己的 registry 查询，不写共享 Session 状态。
                return Ok(());
            }
            ConnectDecision::Started(session_id) => session_id,
        };

        // -----------------------------------------------------------------
        // 4. Create ConnectivityAttempt（§12）+ COORDINATING（§14）。
        // -----------------------------------------------------------------
        self.set_stage(OrchestratorState::Coordinating);
        let local_epoch = state
            .local_discovery
            .read()
            .await
            .as_ref()
            .map(|manager| manager.runtime_epoch())
            .unwrap_or(RuntimeEpoch { high: 0, low: 0 });
        let local_revision = state
            .local_discovery
            .read()
            .await
            .as_ref()
            .map(|manager| manager.revision())
            .unwrap_or(1);
        let local_snapshot = state
            .local_discovery
            .read()
            .await
            .as_ref()
            .map(|manager| manager.snapshot());

        let attempt_id = new_attempt_id();
        // 一次性 ConnectivityAttempt（§12）：candidate 完全 attempt-scoped。
        // - `local_candidates`：本端已 gather 的候选（用于信令/供对端直连）。
        // - `remote_candidates`：Resolve 返回的对端候选（§14 服务器附带 A 当前
        //   Discovery 给 B）+ 手工配置 endpoint。
        // Direct 的**连接目标**是 remote_candidates；本端候选绝不加入连接目标。
        let attempt_started_at = SystemTime::now();
        let mut attempt = ConnectivityAttempt::with_connect_window(
            attempt_id.clone(),
            peer_id.to_string(),
            local_epoch.low,
            attempt_started_at,
            DIRECT_CONNECT_WINDOW,
        )
        .with_local_candidates(collect_local_candidates(state.clone()).await);
        let initial_remote_candidates = resolved_candidates(&resolved, &peer);
        if let Err(error) = attempt.apply_remote_candidates(
            resolved_snapshot(&resolved)
                .and_then(|snapshot| snapshot.runtime_epoch.as_ref().map(runtime_epoch_value)),
            resolved_snapshot(&resolved)
                .map(|snapshot| u64::from(snapshot.revision))
                .unwrap_or(0),
            initial_remote_candidates,
        ) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                format!("invalid remote candidate snapshot: {error}"),
                "connect",
                peer_id,
            ));
        }
        let _ = attempt.set_state(network_nat::ConnectivityAttemptState::Resolved);
        let preserved_direct_candidates = attempt
            .remote_candidates()
            .iter()
            .filter(|candidate| candidate.interface_name == "peer-configured")
            .cloned()
            .collect::<Vec<_>>();
        let attempt = Arc::new(Mutex::new(attempt));
        {
            let mut attempt_state = attempt.lock().await;
            let _ = attempt_state.set_state(network_nat::ConnectivityAttemptState::Coordinating);
        }

        // 发 offer 的异步任务：不阻塞 Direct 窗口（§14 双方 simultaneous checks）。
        let candidate_updates = if let Some(control) = self.state.relay_control.read().await.clone()
        {
            self.spawn_coordination(
                control,
                peer_id.to_string(),
                attempt_id.clone(),
                local_epoch,
                local_revision,
                local_snapshot,
                Arc::clone(&attempt),
                preserved_direct_candidates,
            )
        } else {
            let (sender, receiver) = watch::channel(None);
            drop(sender);
            receiver
        };
        let remote_candidates = attempt.lock().await.remote_candidates().to_vec();
        let _ = attempt
            .lock()
            .await
            .set_state(network_nat::ConnectivityAttemptState::Connecting);

        // -----------------------------------------------------------------
        // 5. DIRECT_CONNECTING（§15）：Direct First 4s。
        // -----------------------------------------------------------------
        self.set_stage(OrchestratorState::DirectConnecting);
        let direct_result = tokio::time::timeout(
            DIRECT_CONNECT_WINDOW,
            connect_direct_or_generic(DirectRouteAttempt {
                state: Arc::clone(&state),
                endpoint,
                candidates: remote_candidates,
                identity,
                expected_peer_public_key: peer.identity_public_key,
                peer_id: peer_id.to_string(),
                session_binding: session_id.wire_key(),
                session_id,
                attempt_id: attempt_id.clone(),
                connect_window: DIRECT_CONNECT_WINDOW,
                candidate_updates,
            }),
        )
        .await;

        let route = match direct_result {
            Ok(Ok(route)) => Ok(route),
            Ok(Err(error)) => {
                tracing::debug!(
                    peer_id = %peer_id,
                    attempt_id = %attempt_id,
                    error = %error.message,
                    "direct first failed; falling back to relay"
                );
                Err(error)
            }
            Err(_) => {
                tracing::debug!(
                    peer_id = %peer_id,
                    attempt_id = %attempt_id,
                    "direct first window elapsed; falling back to relay"
                );
                Err(protocol_error_with_peer(
                    NetworkErrorCode::Timeout,
                    "Direct connect window elapsed",
                    "connect",
                    peer_id,
                ))
            }
        };

        match route {
            // Direct 成功：挂载 Session → CONNECTED_DIRECT。
            Ok(route) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Succeeded);
                let admission = self.attach_direct_route(peer_id, route).await?;
                self.register_current(
                    Arc::clone(&state),
                    peer_id,
                    &remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(OrchestratorState::ConnectedDirect);
                Ok(())
            }
            // Direct 失败：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING（§15/§37）。
            Err(direct_error) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Expired);
                self.set_stage(OrchestratorState::DirectFailed);
                match self
                    .connect_relay_fallback(peer_id, session_id, &peer, &attempt_id)
                    .await
                {
                    Ok(admission) => {
                        self.register_current(
                            Arc::clone(&state),
                            peer_id,
                            &remote_epoch,
                            admission.session_id,
                        )
                        .await;
                        self.set_stage(OrchestratorState::ConnectedRelay);
                        Ok(())
                    }
                    Err(relay_error) => {
                        state.sessions.mark_failed(peer_id, session_id).await;
                        tracing::warn!(
                            peer_id = %peer_id,
                            relay_error = %relay_error.message,
                            "Relay fallback failed; reporting the direct error"
                        );
                        // §40：direct timeout + relay failure → 报告 Direct 错误。
                        Err(direct_error)
                    }
                }
            }
        }
    }

    /// Resolve 阶段：控制面可用时走服务器权威解析（§10），否则退化为本地直连。
    ///
    /// §13 v1 LAN 回退：Resolve 仍是 peer discovery/candidates 的权威入口，但
    /// OFFLINE / NOT_READY / UNKNOWN 且本地 PeerConfig 配置了直连 endpoint 时，退化为
    /// 一次有界本地直连（remote_epoch = None，候选 = 配置 endpoint，仍在同一个
    /// DIRECT_CONNECT_WINDOW 内）；仅当既无控制面结果也无配置 endpoint 时才返回类型化
    /// 错误（保持 fail-closed）。
    async fn resolve(
        &self,
        peer_id: &str,
        peer: &crate::runtime::PeerConfig,
    ) -> Result<ResolvedPeer, ProtocolError> {
        let Some(control) = self.state.relay_control.read().await.clone() else {
            tracing::debug!(peer_id = %peer_id, "no control plane; using local direct mode");
            return Ok(ResolvedPeer::Ready { discovery: None });
        };
        if !control.is_usable().await {
            tracing::debug!(peer_id = %peer_id, "control plane unusable; using local direct mode");
            return Ok(ResolvedPeer::Ready { discovery: None });
        }
        let resolver = DiscoveryResolver::new(control);
        let result = match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
            Ok(Ok(resolved)) => Ok(resolved),
            Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Resolve timed out",
                "connect",
                peer_id,
            )),
        };
        self.fallback_to_local_direct_or_error(peer_id, peer, result)
    }

    /// Preserve a configured local endpoint when the authoritative Resolve path
    /// returns a non-ready status, transport error, or timeout. This is a local
    /// direct attempt only; it never converts Relay UNKNOWN/OFFLINE into an
    /// online result or fabricates remote discovery.
    fn fallback_to_local_direct_or_error(
        &self,
        peer_id: &str,
        peer: &crate::runtime::PeerConfig,
        result: Result<ResolvedPeer, ProtocolError>,
    ) -> Result<ResolvedPeer, ProtocolError> {
        match result {
            Ok(resolved @ ResolvedPeer::Ready { .. }) => Ok(resolved),
            Ok(non_ready) => self.local_endpoint_fallback(peer_id, peer, non_ready),
            Err(error) if peer.endpoint.is_some() => {
                tracing::debug!(
                    peer_id = %peer_id,
                    error = %error.message,
                    "Resolve failed but peer has a configured direct endpoint; attempting local direct"
                );
                Ok(ResolvedPeer::Ready { discovery: None })
            }
            Err(error) => Err(error),
        }
    }

    /// §13：控制面返回 OFFLINE/NOT_READY/UNKNOWN 时的 v1 LAN 回退。对端配置了直连
    /// endpoint → 退化为本地直连（Ready + discovery=None）；否则返回权威类型化错误。
    fn local_endpoint_fallback(
        &self,
        peer_id: &str,
        peer: &crate::runtime::PeerConfig,
        resolved: ResolvedPeer,
    ) -> Result<ResolvedPeer, ProtocolError> {
        if peer.endpoint.is_some() {
            tracing::debug!(
                peer_id = %peer_id,
                ?resolved,
                "resolve is not READY but peer has a configured direct endpoint; attempting local direct"
            );
            return Ok(ResolvedPeer::Ready { discovery: None });
        }
        match resolved {
            ResolvedPeer::Offline => Err(protocol_error_with_peer(
                NetworkErrorCode::PeerOffline,
                "Relay peer is offline",
                "connect",
                peer_id,
            )),
            // §33 错误模型（PeerNotReady / ControlUnavailable / RelayUnavailable）在
            // 本轮 wire 协议（network-protocol）中尚不存在；映射到最接近的既有码：
            // NotReady → Timeout + RetryAfter；Unknown → RelayError。
            ResolvedPeer::NotReady { retry_after_ms } => Err(protocol_error_with_retry(
                NetworkErrorCode::Timeout,
                "Relay peer discovery is not ready",
                "connect",
                Some(peer_id),
                network_protocol::RetryDisposition::RetryAfter,
                retry_after_ms / 1000,
            )),
            ResolvedPeer::Unknown { .. } => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay peer resolution is unavailable",
                "connect",
                peer_id,
            )),
            ResolvedPeer::Ready { .. } => {
                unreachable!("local_endpoint_fallback is only invoked for non-READY statuses")
            }
        }
    }

    /// Registry 重用（§34）：同 epoch + capability 且健康 → 重用；新 epoch → 关旧建新。
    async fn try_reuse(
        &self,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        capability: u8,
    ) -> Result<Option<SessionId>, ProtocolError> {
        let state = Arc::clone(&self.state);
        // epoch 换代：先关闭旧连接，再走新建（§34 Close old → New ConnectivityAttempt）。
        if let Some(obsolete) = state
            .connection_registry
            .take_obsolete(peer_id, remote_epoch)
        {
            tracing::info!(
                peer_id = %peer_id,
                session = ?obsolete.session_id,
                "remote runtime epoch changed; closing obsolete connection"
            );
            close_session_and_registry(
                Arc::clone(&state),
                peer_id.to_string(),
                obsolete.session_id,
            )
            .await;
        }
        let Some(registered) = state
            .connection_registry
            .lookup(peer_id, remote_epoch, capability)
        else {
            return Ok(None);
        };
        if state.sessions.is_connected(peer_id).await
            && state.sessions.current_session_id(peer_id).await == Some(registered.session_id)
        {
            return Ok(Some(registered.session_id));
        }
        // 登记存在但连接已不健康：移除登记，走新建。
        state
            .connection_registry
            .unregister_if_session(peer_id, registered.session_id);
        Ok(None)
    }

    /// 登记一条已建立的连接（§34）。注册表记录连接**实际**能力（由 route profile
    /// 推导），而不是请求时的 class，因此 QUIC/TCP 基线连接可被后续不同 class 的
    /// 请求复用。
    async fn register_current(
        &self,
        state: Arc<RuntimeState>,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        session_id: SessionId,
    ) {
        let capability = state
            .sessions
            .current_profile(peer_id)
            .await
            .map(profile_capability_mask)
            .unwrap_or(DEFAULT_CONNECTION_CAPABILITY);
        state
            .connection_registry
            .register(peer_id, remote_epoch.clone(), capability, session_id);
    }

    /// 发送 ConnectivityOffer（异步任务，不阻塞 Direct 窗口）。
    #[allow(clippy::too_many_arguments)]
    fn spawn_coordination(
        &self,
        control: Arc<dyn crate::discovery::DiscoveryControlPlane>,
        peer_id: String,
        attempt_id: String,
        local_epoch: RuntimeEpoch,
        local_revision: u32,
        local_snapshot: Option<DiscoverySnapshot>,
        attempt: Arc<Mutex<ConnectivityAttempt>>,
        preserved_direct_candidates: Vec<Candidate>,
    ) -> watch::Receiver<Option<Vec<Candidate>>> {
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        let state = Arc::clone(&self.state);
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_runtime("connectivity-coordination", async move {
            let device_id = state
                .identity
                .read()
                .await
                .as_ref()
                .map(|identity| identity.device_id.clone());
            let Some(device_id) = device_id else {
                return;
            };
            match control
                .start_connectivity_attempt(
                    attempt_id.clone(),
                    peer_id.clone(),
                    device_id,
                    local_epoch,
                    local_revision,
                    local_snapshot,
                )
                .await
            {
                Ok(answer) => {
                    if answer.attempt_id != attempt_id {
                        tracing::debug!(
                            peer_id = %peer_id,
                            expected_attempt_id = %attempt_id,
                            received_attempt_id = %answer.attempt_id,
                            "ignored stale connectivity answer"
                        );
                        return;
                    }
                    if answer.accepted {
                        if let Some(snapshot) = answer.responder_snapshot.as_ref() {
                            let mut candidates = discovery_snapshot_candidates(snapshot);
                            candidates.extend(preserved_direct_candidates.iter().cloned());
                            let result = {
                                let mut attempt = attempt.lock().await;
                                let result = attempt.apply_remote_candidates(
                                    snapshot.runtime_epoch.as_ref().map(runtime_epoch_value),
                                    u64::from(snapshot.revision),
                                    candidates,
                                );
                                match result {
                                    Ok(true) => {
                                        let _ = attempt.set_state(
                                            network_nat::ConnectivityAttemptState::Connecting,
                                        );
                                        Ok(Some(attempt.remote_candidates().to_vec()))
                                    }
                                    Ok(false) => Ok(None),
                                    Err(error) => Err(error),
                                }
                            };
                            match result {
                                Ok(Some(candidates)) => {
                                    let _ = candidate_update_tx.send(Some(candidates));
                                }
                                Ok(None) => {}
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        attempt_id = %attempt_id,
                                        error = %error,
                                        "rejected responder candidate snapshot"
                                    );
                                }
                            }
                        }
                    }
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        accepted = answer.accepted,
                        "connectivity answer received"
                    );
                }
                Err(error) => {
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        error = %error,
                        "connectivity coordination failed"
                    );
                }
            }
        });
        candidate_updates
    }

    /// Relay 回退：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY。
    ///
    /// - RELAY_RESERVING（§25/§31）：经 v2 控制面 `reserve_relay` 请求 reservation。
    /// - RELAY_CONNECTING（§25）：连接 `/v2/relay/{reservation_id}` 数据面
    ///   （`RelayDataClient`），在其上完成 Relay E2EE 握手后挂载 ConnectionSession。
    async fn connect_relay_fallback(
        &self,
        peer_id: &str,
        session_id: SessionId,
        peer: &crate::runtime::PeerConfig,
        attempt_id: &str,
    ) -> Result<SessionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);

        // RELAY_RESERVING：reserve_relay 经 v2 控制面路由（§31 reserveRelay）。
        self.set_stage(OrchestratorState::RelayReserving);
        let reservation = {
            let control = state.relay_control.read().await.clone().ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay control plane is unavailable",
                    "connect",
                    peer_id,
                )
            })?;
            if !control.is_usable().await {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay control plane is not connected",
                    "connect",
                    peer_id,
                ));
            }
            match tokio::time::timeout(
                RELAY_RESERVE_TIMEOUT,
                control.reserve_relay(
                    attempt_id.to_string(),
                    peer_id.to_string(),
                    super::RELAY_RESERVATION_LIFETIME_S,
                ),
            )
            .await
            {
                Ok(Ok(reservation)) => {
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        reservation_id = %reservation.reservation_id,
                        "relay reservation acquired"
                    );
                    reservation
                }
                Ok(Err(error)) => {
                    tracing::warn!(peer_id = %peer_id, error = %error, "relay reservation failed");
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        format!("Relay reservation failed: {error}"),
                        "connect",
                        peer_id,
                    ));
                }
                Err(_) => {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::Timeout,
                        "Relay reservation timed out",
                        "connect",
                        peer_id,
                    ));
                }
            }
        };

        // RELAY_CONNECTING（§25）：连接 reservation 数据面并启动事件循环。
        self.set_stage(OrchestratorState::RelayConnecting);
        let data =
            match crate::relay::connect_initiator_relay_data(&state, peer_id, reservation).await {
                Ok(data) => data,
                Err(error) => {
                    state.sessions.mark_failed(peer_id, session_id).await;
                    return Err(error);
                }
            };
        let crypto_identity = state.identity.read().await.clone().ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "runtime identity is unavailable",
                "connect",
                peer_id,
            )
        })?;
        let (crypto, admission) = match crate::peer::establish_relay_crypto(
            &state,
            Arc::clone(&data),
            peer_id,
            session_id,
            crypto_identity,
            peer.identity_public_key,
        )
        .await
        {
            Ok(crypto) => crypto,
            Err(error) => {
                state.sessions.mark_failed(peer_id, session_id).await;
                return Err(error);
            }
        };
        if install_admitted_crypto(&state, peer_id, &admission, &crypto)
            .await
            .is_err()
        {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE handshake was not accepted",
                "connect",
                peer_id,
            ));
        }
        let session_id = admission.session_id;
        let attached = state
            .sessions
            .mark_relay_route_connected(peer_id, session_id, RouteType::Relay, Some(data))
            .await;
        if !attached {
            state.sessions.mark_failed(peer_id, session_id).await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "Relay route completed after Session was closed",
                "connect",
                peer_id,
            ));
        }
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Connected,
            RouteType::Relay,
            None,
        );
        crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
        // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
        crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string()).await;
        Ok(admission)
    }

    /// Direct 成功后挂载 Session（连接 Session 同生命周期，§18）。
    pub(crate) async fn attach_direct_route(
        &self,
        peer_id: &str,
        route: ConnectedRoute,
    ) -> Result<SessionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);
        match route {
            ConnectedRoute::Quic {
                connection,
                crypto,
                admission,
            } => {
                let session_id = admission.session_id;
                if install_admitted_crypto(&state, peer_id, &admission, &crypto)
                    .await
                    .is_err()
                {
                    connection.close(VarInt::from_u32(0), b"application E2EE install failed");
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::AuthenticationFailed,
                        "application E2EE handshake was not accepted",
                        "connect",
                        peer_id,
                    ));
                }
                let previous_route = state
                    .sessions
                    .attach_connection_for_session(
                        peer_id,
                        Some(session_id),
                        connection.clone(),
                        RouteType::QuicDirect,
                    )
                    .await
                    .map_err(|_| {
                        protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "connection completed after Session was closed",
                            "connect",
                            peer_id,
                        )
                    })?;
                if let Some(previous_route) = previous_route {
                    previous_route.close().await;
                }
                if state.sessions.current_session_id(peer_id).await != Some(session_id) {
                    state.sessions.mark_failed(peer_id, session_id).await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::Cancelled,
                        "connection completed after Session was closed",
                        "connect",
                        peer_id,
                    ));
                }
                emit_peer_state(
                    &state.event_tx,
                    peer_id,
                    PeerConnectionState::Connected,
                    RouteType::QuicDirect,
                    None,
                );
                emit_route_changed(
                    &state.event_tx,
                    peer_id,
                    RouteType::QuicDirect,
                    connection.remote_address(),
                    connection.rtt().as_millis().min(u32::MAX as u128) as u32,
                    0.0,
                );
                crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
                // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输
                // （ResumeTransfer(transfer_id)，按 transfer_id + peer_id 领取）。
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string())
                    .await;
                crate::peer::spawn_session_receivers(
                    Arc::clone(&state),
                    peer_id.to_string(),
                    connection,
                    session_id,
                );
                Ok(admission)
            }
            ConnectedRoute::Generic(generic) => {
                let mut scope = generic.scope;
                let profile = scope
                    .profile()
                    .expect("supervised GenericRoute scope has a profile");
                let admission = generic.admission;
                let session_id = admission.session_id;
                if install_admitted_crypto(&state, peer_id, &admission, &generic.crypto)
                    .await
                    .is_err()
                {
                    scope.close().await;
                    state.sessions.mark_failed(peer_id, session_id).await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::AuthenticationFailed,
                        "application E2EE handshake was not accepted",
                        "connect",
                        peer_id,
                    ));
                }
                let previous_route = match state
                    .sessions
                    .attach_generic_route_for_session(peer_id, Some(session_id), &mut scope)
                    .await
                {
                    Ok(previous_route) => previous_route,
                    Err(_) => {
                        scope.close().await;
                        state.sessions.mark_failed(peer_id, session_id).await;
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "generic connection completed after Session was closed",
                            "connect",
                            peer_id,
                        ));
                    }
                };
                if let Some(previous_route) = previous_route {
                    previous_route.close().await;
                }
                emit_peer_state_profile(
                    &state.event_tx,
                    peer_id,
                    PeerConnectionState::Connected,
                    Some(profile),
                    None,
                );
                emit_route_changed_profile(
                    &state.event_tx,
                    peer_id,
                    Some(profile),
                    generic.endpoint,
                    0,
                    0.0,
                );
                crate::channel::recover_session(Arc::clone(&state), peer_id.to_string()).await;
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string())
                    .await;
                Ok(admission)
            }
        }
    }
}

/// 关闭一个已登记的连接（§34 Close old）。
pub(crate) async fn close_session_and_registry(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
) {
    if let Some(route) = state.sessions.close(&peer_id).await {
        route.close().await;
    }
    state.cancel_session_tasks(&peer_id, session_id).await;
    state
        .connection_registry
        .unregister_if_session(&peer_id, session_id);
    // 显式关闭连接（§34 Close old）时清理接收端 dedup/ordered 状态；transport
    // 丢失路径不清理（§20 需要跨连接去重）。
    state.delivery.close_peer(&peer_id).await;
}

/// 生成一次独立的 attempt_id（§12：每次建连独立 attempt）。
fn new_attempt_id() -> String {
    hex::encode(rand::random::<[u8; 16]>())
}

/// 从 Resolve 结果提取对端 runtime_epoch。
fn resolved_runtime_epoch(resolved: &ResolvedPeer) -> Option<RuntimeEpoch> {
    match resolved {
        ResolvedPeer::Ready { discovery } => discovery
            .as_ref()
            .and_then(|snapshot| snapshot.runtime_epoch.clone()),
        _ => None,
    }
}

/// 从 Resolve 结果解码远端候选（opaque JSON → Candidate）。
fn resolved_snapshot(resolved: &ResolvedPeer) -> Option<&DiscoverySnapshot> {
    match resolved {
        ResolvedPeer::Ready { discovery } => discovery.as_ref(),
        ResolvedPeer::Offline | ResolvedPeer::NotReady { .. } | ResolvedPeer::Unknown { .. } => {
            None
        }
    }
}

/// `ConnectivityAttempt` stores the compact u64 epoch used by the older NAT
/// exchange API; fold the v2 128-bit runtime epoch without treating either
/// wire half as a peer-controlled candidate value.
fn runtime_epoch_value(epoch: &RuntimeEpoch) -> u64 {
    epoch.high.rotate_left(17) ^ epoch.low
}

fn discovery_snapshot_candidates(snapshot: &DiscoverySnapshot) -> Vec<Candidate> {
    snapshot
        .candidate_bundle
        .as_ref()
        .into_iter()
        .flat_map(|bundle| bundle.candidates.iter())
        .filter_map(|bytes| serde_json::from_slice::<CandidateAdvertisement>(bytes).ok())
        .filter_map(|advertisement| Candidate::from_advertisement(advertisement).ok())
        .collect()
}

fn resolved_candidates(
    resolved: &ResolvedPeer,
    peer: &crate::runtime::PeerConfig,
) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    if let Some(snapshot) = resolved_snapshot(resolved) {
        candidates.extend(discovery_snapshot_candidates(snapshot));
    }
    append_configured_endpoint(&mut candidates, peer);
    candidates.sort_by(|left, right| {
        candidate_order(left)
            .cmp(&candidate_order(right))
            .then_with(|| right.priority.cmp(&left.priority))
            .then_with(|| left.candidate_id.cmp(&right.candidate_id))
    });
    candidates
}

/// Direct candidate order is deterministic and deliberately independent of the
/// order in which a remote snapshot happened to arrive. The configured endpoint
/// is a last-resort direct candidate after the advertised LAN/public/reflexive
/// candidates, while the remaining kinds keep their lower-priority tail.
fn candidate_order(candidate: &Candidate) -> u8 {
    if candidate.interface_name == "peer-configured" {
        return 3;
    }
    match candidate.kind {
        CandidateKind::Lan => 0,
        CandidateKind::PublicIpv6 => 1,
        CandidateKind::ServerReflexive => 2,
        CandidateKind::PortMapped => 4,
        CandidateKind::Relay => 5,
    }
}

/// 收集本地候选（local PathManager 已 gather 的候选）。
async fn collect_local_candidates(state: Arc<RuntimeState>) -> Vec<Candidate> {
    let Some(manager) = state.local_path_manager.read().await.clone() else {
        return Vec::new();
    };
    manager
        .ranked_candidates()
        .await
        .into_iter()
        .take(MAX_CANDIDATES_PER_SIGNAL)
        .collect()
}

/// 追加手工配置的 endpoint 候选（peer.endpoint，LAN/显式直连）。
fn append_configured_endpoint(candidates: &mut Vec<Candidate>, peer: &crate::runtime::PeerConfig) {
    if let Some(endpoint) = peer.endpoint {
        if !candidates
            .iter()
            .any(|candidate| candidate.endpoint == endpoint)
        {
            candidates.push(Candidate::new(
                endpoint,
                crate::peer::candidate_kind_for(endpoint),
                "peer-configured".into(),
            ));
        }
    }
}

/// 把控制面错误映射为类型化错误（§33 ControlUnavailable/ResolveTimeout/ProtocolError）。
fn relay_resolve_error(error: &RelayError, peer_id: &str) -> ProtocolError {
    match error {
        RelayError::Timeout(_) => protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Resolve timed out",
            "connect",
            peer_id,
        ),
        _ => protocol_error_with_peer(
            NetworkErrorCode::RelayError,
            format!("Resolve failed: {error}"),
            "connect",
            peer_id,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_nat::PathManager;
    use network_relay::v2::ResolveStatus;
    use std::time::Duration;

    /// 构造一个可跑通 `connect_with_class` 前段（配置校验 + Resolve + try_reuse）
    /// 的 RuntimeState：配置了 endpoint/identity/peer，无控制面（本地直连，epoch=None）。
    async fn configured_reuse_state() -> (
        Arc<RuntimeState>,
        tokio::sync::mpsc::UnboundedReceiver<network_protocol::NetworkEvent>,
    ) {
        let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let path_manager = Arc::new(PathManager::new());
        let manager = network_quic::QuicEndpointManager::new(
            "127.0.0.1:0".parse().expect("test bind address"),
            path_manager,
        )
        .expect("create test QUIC endpoint");
        *state.endpoint.write().await = Some(manager.endpoint);
        *state.identity.write().await = Some(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "device-a".into(),
                [21u8; 32],
                [31u8; 32],
            ),
        ));
        state.peers.write().await.insert(
            "peer-b".to_string(),
            crate::runtime::PeerConfig {
                endpoint: None,
                identity_public_key: [7u8; 32],
                e2e_public_key: [8u8; 32],
            },
        );
        (state, event_rx)
    }

    #[test]
    fn stage_machine_follows_the_design_skeleton() {
        // 状态机只允许设计定义的阶段；不允许 RECONNECTING / DIRECT_UPGRADING /
        // PATH_REPAIRING（§11）。
        let stages = [
            OrchestratorState::Idle,
            OrchestratorState::Resolving,
            OrchestratorState::Resolved,
            OrchestratorState::Coordinating,
            OrchestratorState::DirectConnecting,
            OrchestratorState::ConnectedDirect,
            OrchestratorState::DirectFailed,
            OrchestratorState::RelayReserving,
            OrchestratorState::RelayConnecting,
            OrchestratorState::ConnectedRelay,
            OrchestratorState::Failed,
        ];
        for stage in stages {
            // 编译期保证不存在缺失的变体。
            match stage {
                OrchestratorState::Idle
                | OrchestratorState::Resolving
                | OrchestratorState::Resolved
                | OrchestratorState::Coordinating
                | OrchestratorState::DirectConnecting
                | OrchestratorState::ConnectedDirect
                | OrchestratorState::DirectFailed
                | OrchestratorState::RelayReserving
                | OrchestratorState::RelayConnecting
                | OrchestratorState::ConnectedRelay
                | OrchestratorState::Failed => {}
            }
        }
    }

    #[test]
    fn direct_window_constant_is_four_seconds() {
        assert_eq!(DIRECT_CONNECT_WINDOW, Duration::from_millis(4000));
    }

    #[test]
    fn direct_candidates_are_ranked_before_the_staggered_race() {
        let mut candidates = vec![
            Candidate::new(
                "198.51.100.4:41004".parse().unwrap(),
                CandidateKind::ServerReflexive,
                "srflx".into(),
            ),
            Candidate::new(
                "192.168.1.4:41001".parse().unwrap(),
                CandidateKind::Lan,
                "lan".into(),
            ),
            Candidate::new(
                "127.0.0.1:41000".parse().unwrap(),
                CandidateKind::Lan,
                "peer-configured".into(),
            ),
            Candidate::new(
                "[2001:db8::4]:41002".parse().unwrap(),
                CandidateKind::PublicIpv6,
                "ipv6".into(),
            ),
        ];
        candidates.sort_by(|left, right| {
            candidate_order(left)
                .cmp(&candidate_order(right))
                .then_with(|| right.priority.cmp(&left.priority))
                .then_with(|| left.candidate_id.cmp(&right.candidate_id))
        });
        assert_eq!(candidates[0].interface_name, "lan");
        assert_eq!(candidates[1].interface_name, "ipv6");
        assert_eq!(candidates[2].interface_name, "srflx");
        assert_eq!(candidates[3].interface_name, "peer-configured");
    }

    #[tokio::test]
    async fn connectivity_answer_merges_candidates_into_the_live_attempt() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.identity.write().await = Some(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "local-a".into(),
                [1u8; 32],
                [2u8; 32],
            ),
        ));
        let candidate = Candidate::new(
            "198.51.100.20:42020".parse().expect("candidate endpoint"),
            CandidateKind::Lan,
            "answer-lan".into(),
        )
        .with_generation(7);
        let snapshot = DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
            revision: 7,
            transport_capabilities: Vec::new(),
            candidate_bundle: Some(network_relay::v2::CandidateBundle {
                candidates: vec![serde_json::to_vec(&candidate.advertisement()).expect("candidate")],
            }),
            published_at_ms: 1,
        };
        let control =
            StubControl::with_connectivity_answer(network_relay::v2::ConnectivityAnswer {
                request_id: 1,
                attempt_id: "attempt-answer".into(),
                accepted: true,
                responder_device_id: "peer-b".into(),
                responder_runtime_epoch: snapshot.runtime_epoch.clone(),
                responder_revision: snapshot.revision,
                responder_snapshot: Some(snapshot),
            });
        let attempt = Arc::new(Mutex::new(ConnectivityAttempt::with_connect_window(
            "attempt-answer",
            "peer-b",
            1,
            SystemTime::now(),
            DIRECT_CONNECT_WINDOW,
        )));
        let orchestrator = ConnectionOrchestrator::new(state);
        let mut updates = orchestrator.spawn_coordination(
            control,
            "peer-b".into(),
            "attempt-answer".into(),
            RuntimeEpoch { high: 1, low: 2 },
            1,
            None,
            Arc::clone(&attempt),
            Vec::new(),
        );
        tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("candidate update timeout")
            .expect("coordination sender dropped");
        let updates = updates.borrow().clone().expect("candidate update");
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0].endpoint.port(), 42020);
        let attempt = attempt.lock().await;
        assert_eq!(attempt.remote_candidates().len(), 1);
        assert_eq!(attempt.remote_discovery_revision(), Some(7));
        assert_eq!(
            attempt.state(),
            network_nat::ConnectivityAttemptState::Connecting
        );
    }

    #[tokio::test]
    async fn new_orchestrator_starts_in_idle() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let orchestrator = ConnectionOrchestrator::new(state);
        assert_eq!(orchestrator.stage(), OrchestratorState::Idle);
    }

    #[test]
    fn resolved_runtime_epoch_is_read_from_ready_discovery() {
        let discovery = DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 7, low: 8 }),
            revision: 3,
            transport_capabilities: vec![],
            candidate_bundle: None,
            published_at_ms: 0,
        };
        let resolved = ResolvedPeer::Ready {
            discovery: Some(discovery),
        };
        assert_eq!(
            resolved_runtime_epoch(&resolved),
            Some(RuntimeEpoch { high: 7, low: 8 })
        );
        assert_eq!(resolved_runtime_epoch(&ResolvedPeer::Offline), None);
        assert_eq!(
            resolved_runtime_epoch(&ResolvedPeer::Ready { discovery: None }),
            None
        );
    }

    #[tokio::test]
    async fn resolve_is_the_authoritative_gate_before_connect() {
        // §10/§40：每次 connect 前先 Resolve；OFFLINE 且无本地配置 endpoint 时直接
        // 失败，不进入 Direct（fail-closed）。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let result = orchestrator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::PeerOffline as i32
        ));
    }

    #[tokio::test]
    async fn resolve_returns_local_direct_ready_without_control_plane() {
        // 无控制面（LAN / 显式 endpoint 直连）：退化为本地直连，remote_epoch = None。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let orchestrator = ConnectionOrchestrator::new(state);
        let resolved = orchestrator
            .resolve("peer-b", &peer_without_endpoint())
            .await
            .expect("local direct");
        assert_eq!(resolved_runtime_epoch(&resolved), None);
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test]
    async fn resolve_not_ready_maps_to_retriable_timeout() {
        // §10：NOT_READY 且无本地配置 endpoint → 可短暂重试（Timeout + RetryAfter）。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let result = orchestrator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert!(matches!(
            result,
            Err(error)
                if error.code == NetworkErrorCode::Timeout as i32
                    && error.retry_disposition
                        == network_protocol::RetryDisposition::RetryAfter as i32
        ));
    }

    #[tokio::test]
    async fn offline_resolve_with_configured_endpoint_falls_back_to_local_direct() {
        // §13：Resolve 仍是权威入口，但 OFFLINE + 本地配置直连 endpoint → 退化为本地
        // 直连（remote_epoch = None，候选 = 配置 endpoint），连接仍可经 Direct 成功。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
        };
        let resolved = orchestrator
            .resolve("peer-b", &peer)
            .await
            .expect("offline with configured endpoint should fall back to local direct");
        assert_eq!(resolved_runtime_epoch(&resolved), None);
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test]
    async fn not_ready_resolve_with_configured_endpoint_falls_back_to_local_direct() {
        // §13：NOT_READY + 本地配置直连 endpoint → 同样退化为一次有界本地直连。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
        };
        let resolved = orchestrator
            .resolve("peer-b", &peer)
            .await
            .expect("not-ready with configured endpoint should fall back to local direct");
        assert_eq!(resolved_runtime_epoch(&resolved), None);
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test]
    async fn resolve_transport_error_with_configured_endpoint_falls_back_to_local_direct() {
        // Resolve transport errors do not make a locally configured endpoint
        // unusable; they only remove authoritative discovery for this attempt.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay_control.write().await = Some(StubControl::error());
        let orchestrator = ConnectionOrchestrator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
        };
        let resolved = orchestrator
            .resolve("peer-b", &peer)
            .await
            .expect("transport error with configured endpoint should fall back");
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test(start_paused = true)]
    async fn resolve_timeout_with_configured_endpoint_falls_back_to_local_direct() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay_control.write().await = Some(StubControl::timeout());
        let orchestrator = ConnectionOrchestrator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
        };
        let task = tokio::spawn(async move { orchestrator.resolve("peer-b", &peer).await });
        tokio::task::yield_now().await;
        tokio::time::advance(RESOLVE_TIMEOUT + Duration::from_millis(1)).await;
        let resolved = task
            .await
            .expect("resolve task")
            .expect("timeout with configured endpoint should fall back");
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test(start_paused = true)]
    async fn resolve_timeout_without_endpoint_remains_a_timeout_error() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay_control.write().await = Some(StubControl::timeout());
        let orchestrator = ConnectionOrchestrator::new(state);
        let peer = peer_without_endpoint();
        let task = tokio::spawn(async move { orchestrator.resolve("peer-b", &peer).await });
        tokio::task::yield_now().await;
        tokio::time::advance(RESOLVE_TIMEOUT + Duration::from_millis(1)).await;
        let result = task.await.expect("resolve task");
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::Timeout as i32
        ));
    }

    #[tokio::test]
    async fn reused_session_uses_route_profile_and_emits_connected() {
        // §17/§40：Registry 重用路径依据已登记的实际 capability；后续
        // ReliableStream 请求复用同一条同时支持 message/stream 的 Relay route 时，
        // 不需要覆盖 Session 上的任何业务类别状态。
        let (state, mut event_rx) = configured_reuse_state().await;
        let peer_id = "peer-b";

        // 预置一条健康连接：ReliableMessage 会话 + 已登记（模拟先前 connect 建立）。
        let session_id = match state.sessions.begin_connect(peer_id).await {
            crate::session::ConnectDecision::Started(id) => id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        assert!(
            state
                .sessions
                .mark_relay_route_connected(peer_id, session_id, RouteType::Relay, None)
                .await
        );
        state.connection_registry.register(
            peer_id,
            None,
            DEFAULT_CONNECTION_CAPABILITY,
            session_id,
        );

        let orchestrator = ConnectionOrchestrator::new(Arc::clone(&state));
        let result = orchestrator
            .connect_with_class(peer_id, CommunicationClass::ReliableStream)
            .await;
        assert!(result.is_ok(), "reuse path should succeed: {result:?}");

        // 重用的 Relay route profile 支持 ReliableStream；Relay(None) 载体只会因
        // 未连接而失败，不能因为此前的业务类别阻止 open_stream。
        let stream_result = crate::stream::open_stream(
            &state,
            peer_id,
            1,
            "shell",
            crate::stream::StreamConsumer::Event,
        )
        .await;
        assert!(
            !matches!(
                stream_result,
                Err(crate::stream::StreamError::UnsupportedTransport)
            ),
            "reused ReliableStream session must not gate byte streams"
        );

        // 重用路径发布 Connected 终态（Dart connect() 的成功信号）。
        let event = event_rx
            .try_recv()
            .expect("Connected event must be emitted on the reuse path");
        match event.payload {
            Some(network_protocol::network_event::Payload::PeerState(peer_state)) => {
                assert_eq!(peer_state.peer_id, peer_id);
                assert_eq!(
                    peer_state.state,
                    network_protocol::PeerConnectionState::Connected as i32
                );
                assert_eq!(peer_state.active_route, RouteType::Relay as i32);
            }
            other => panic!("unexpected event payload: {other:?}"),
        }
    }

    /// 构造一个没有配置直连 endpoint 的 PeerConfig（测试 resolve 权威失败路径用）。
    fn peer_without_endpoint() -> crate::runtime::PeerConfig {
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [0u8; 32],
            e2e_public_key: [0u8; 32],
        }
    }

    /// 预置 Resolve 状态的 mock 控制面（测试用）。
    struct StubControl {
        status: network_relay::v2::ResolveStatus,
        discovery: Option<DiscoverySnapshot>,
        resolve_error: bool,
        resolve_never: bool,
        connectivity_answer: Option<network_relay::v2::ConnectivityAnswer>,
    }

    impl StubControl {
        fn new(
            status: network_relay::v2::ResolveStatus,
            discovery: Option<DiscoverySnapshot>,
        ) -> Arc<Self> {
            Arc::new(Self {
                status,
                discovery,
                resolve_error: false,
                resolve_never: false,
                connectivity_answer: None,
            })
        }

        fn error() -> Arc<Self> {
            Arc::new(Self {
                status: ResolveStatus::Unknown,
                discovery: None,
                resolve_error: true,
                resolve_never: false,
                connectivity_answer: None,
            })
        }

        fn timeout() -> Arc<Self> {
            Arc::new(Self {
                status: ResolveStatus::Unknown,
                discovery: None,
                resolve_error: false,
                resolve_never: true,
                connectivity_answer: None,
            })
        }

        fn with_connectivity_answer(answer: network_relay::v2::ConnectivityAnswer) -> Arc<Self> {
            Arc::new(Self {
                status: ResolveStatus::Unknown,
                discovery: None,
                resolve_error: false,
                resolve_never: false,
                connectivity_answer: Some(answer),
            })
        }
    }

    impl crate::discovery::DiscoveryControlPlane for StubControl {
        fn publish_discovery(
            &self,
            _request_id: u64,
            _snapshot: DiscoverySnapshot,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<network_relay::v2::DiscoveryAck, RelayError>,
                    > + Send
                    + '_,
            >,
        > {
            Box::pin(async { Err(RelayError::NotConnected) })
        }

        fn resolve_peer(
            &self,
            _target_device_id: &str,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<network_relay::v2::ResolvePeerResponse, RelayError>,
                    > + Send
                    + '_,
            >,
        > {
            if self.resolve_error {
                return Box::pin(async { Err(RelayError::NotConnected) });
            }
            if self.resolve_never {
                return Box::pin(async {
                    std::future::pending::<
                        Result<network_relay::v2::ResolvePeerResponse, RelayError>,
                    >()
                    .await
                });
            }
            let status = self.status;
            let discovery = self.discovery.clone();
            Box::pin(async move {
                Ok(network_relay::v2::ResolvePeerResponse {
                    request_id: 1,
                    status: status as i32,
                    discovery,
                    retry_after_ms: 500,
                })
            })
        }

        fn is_usable(
            &self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + '_>> {
            Box::pin(async { true })
        }

        fn start_connectivity_attempt(
            &self,
            _attempt_id: String,
            _target_device_id: String,
            _initiator_device_id: String,
            _initiator_runtime_epoch: RuntimeEpoch,
            _initiator_revision: u32,
            _initiator_snapshot: Option<DiscoverySnapshot>,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<network_relay::v2::ConnectivityAnswer, RelayError>,
                    > + Send
                    + '_,
            >,
        > {
            let answer = self.connectivity_answer.clone();
            Box::pin(async move { answer.ok_or(RelayError::NotConnected) })
        }
    }
}
