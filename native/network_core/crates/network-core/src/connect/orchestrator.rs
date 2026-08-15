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
//! 7. **Relay Data** → CONNECTED_RELAY。本轮 Relay 数据面复用 v1 Relay 数据路径
//!    （deprecated，Step 11 迁移到 `RelayDataClient` reservation 模型）。

use std::sync::Arc;
use std::time::SystemTime;

use network_nat::{
    Candidate, CandidateAdvertisement, ConnectivityAttempt, MAX_CANDIDATES_PER_SIGNAL,
};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
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

    /// 建连唯一入口（§37）。成功后返回 `()`；失败返回类型化错误（§33）。
    pub(crate) async fn connect(&self, peer_id: &str) -> Result<(), ProtocolError> {
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
        let resolved = self.resolve(peer_id).await?;
        self.set_stage(OrchestratorState::Resolved);

        let remote_epoch = resolved_runtime_epoch(&resolved);
        let capability = DEFAULT_CONNECTION_CAPABILITY;

        // -----------------------------------------------------------------
        // 2. Registry 重用（§34）。
        // -----------------------------------------------------------------
        if let Some(reused) = self.try_reuse(peer_id, &remote_epoch, capability).await? {
            tracing::info!(
                peer_id = %peer_id,
                session = ?reused,
                "reused existing healthy connection"
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
                self.register_current(
                    state.clone(),
                    peer_id,
                    &remote_epoch,
                    capability,
                    session_id,
                )
                .await;
                self.set_stage(OrchestratorState::ConnectedDirect);
                return Ok(());
            }
            ConnectDecision::InProgress(_) => {
                // 已有连接任务在途：合并，不做重复建连。
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
        let _attempt = ConnectivityAttempt::with_connect_window(
            attempt_id.clone(),
            peer_id.to_string(),
            0,
            SystemTime::now(),
            DIRECT_CONNECT_WINDOW,
        )
        .with_local_candidates(collect_local_candidates(state.clone()).await);
        let remote_candidates = resolved_candidates(&resolved, &peer);

        // 发 offer 的异步任务：不阻塞 Direct 窗口（§14 双方 simultaneous checks）。
        if let Some(control) = self.state.relay_control.read().await.clone() {
            self.spawn_coordination(
                control,
                peer_id.to_string(),
                attempt_id.clone(),
                local_epoch,
                local_revision,
                local_snapshot,
            );
        }

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
                let admission = self.attach_direct_route(peer_id, route).await?;
                self.register_current(
                    Arc::clone(&state),
                    peer_id,
                    &remote_epoch,
                    capability,
                    admission.session_id,
                )
                .await;
                state.finish_session_replacement(admission);
                self.set_stage(OrchestratorState::ConnectedDirect);
                Ok(())
            }
            // Direct 失败：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING（§15/§37）。
            Err(direct_error) => {
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
                            capability,
                            admission.session_id,
                        )
                        .await;
                        state.finish_session_replacement(admission);
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
    async fn resolve(&self, peer_id: &str) -> Result<ResolvedPeer, ProtocolError> {
        let Some(control) = self.state.relay_control.read().await.clone() else {
            tracing::debug!(peer_id = %peer_id, "no control plane; using local direct mode");
            return Ok(ResolvedPeer::Ready { discovery: None });
        };
        if !control.is_usable().await {
            tracing::debug!(peer_id = %peer_id, "control plane unusable; using local direct mode");
            return Ok(ResolvedPeer::Ready { discovery: None });
        }
        let resolver = DiscoveryResolver::new(control);
        match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
            Ok(Ok(resolved)) => match resolved {
                ResolvedPeer::Ready { .. } => Ok(resolved),
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
            },
            Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Resolve timed out",
                "connect",
                peer_id,
            )),
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

    /// 登记一条已建立的连接。
    async fn register_current(
        &self,
        state: Arc<RuntimeState>,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        capability: u8,
        session_id: SessionId,
    ) {
        state
            .connection_registry
            .register(peer_id, remote_epoch.clone(), capability, session_id);
    }

    /// 发送 ConnectivityOffer（异步任务，不阻塞 Direct 窗口）。
    fn spawn_coordination(
        &self,
        control: Arc<dyn crate::discovery::DiscoveryControlPlane>,
        peer_id: String,
        attempt_id: String,
        local_epoch: RuntimeEpoch,
        local_revision: u32,
        local_snapshot: Option<DiscoverySnapshot>,
    ) {
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
                    device_id,
                    local_epoch,
                    local_revision,
                    local_snapshot,
                )
                .await
            {
                Ok(answer) => {
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
    }

    /// Relay 回退：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY。
    ///
    /// - RELAY_RESERVING（§25/§31）：经 v2 控制面 `reserve_relay` 请求 reservation
    ///   （forward path 接线）。
    /// - RELAY_CONNECTING：本轮 Relay 数据面仍复用 v1 Relay 数据路径（deprecated，
    ///   Step 11 迁移到 `RelayDataClient` reservation 模型）。
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
        if let Some(control) = state.relay_control.read().await.clone() {
            if control.is_usable().await {
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
                    }
                    Ok(Err(error)) => {
                        tracing::warn!(
                            peer_id = %peer_id,
                            error = %error,
                            "relay reservation failed"
                        );
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
            }
        }

        // RELAY_CONNECTING：复用 v1 Relay 数据路径（deprecated，Step 11 迁移）。
        self.set_stage(OrchestratorState::RelayConnecting);
        let relay = state.relay.read().await.clone().ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay route completed without a Relay client",
                "connect",
                peer_id,
            )
        })?;
        if !relay.is_usable().await {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay data plane is not connected",
                "connect",
                peer_id,
            ));
        }
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
            Arc::clone(&relay),
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
            .mark_relay_route_connected(peer_id, session_id, RouteType::Relay, Some(relay))
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
        crate::channel::recover_session(Arc::clone(&state), peer_id.to_string(), session_id).await;
        if admission.decision != crate::session::SessionCryptoDecision::ReplaceWithNew {
            crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.to_string())
                .await;
        }
        Ok(admission)
    }

    /// Direct 成功后挂载 Session（连接 Session 同生命周期，§18）。
    async fn attach_direct_route(
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
                        admission.decision
                            == crate::session::SessionCryptoDecision::ContinueExisting,
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
                crate::channel::recover_session(
                    Arc::clone(&state),
                    peer_id.to_string(),
                    session_id,
                )
                .await;
                if admission.decision != crate::session::SessionCryptoDecision::ReplaceWithNew {
                    crate::transfer::resume_transfers_for_peer(
                        Arc::clone(&state),
                        peer_id.to_string(),
                    )
                    .await;
                }
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
                    .attach_generic_route_for_session(
                        peer_id,
                        Some(session_id),
                        &mut scope,
                        admission.decision
                            == crate::session::SessionCryptoDecision::ContinueExisting,
                    )
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
                crate::channel::recover_session(
                    Arc::clone(&state),
                    peer_id.to_string(),
                    session_id,
                )
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
    state.delivery.close_session(&session_id.wire_key()).await;
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
fn resolved_candidates(
    resolved: &ResolvedPeer,
    peer: &crate::runtime::PeerConfig,
) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    if let ResolvedPeer::Ready {
        discovery:
            Some(DiscoverySnapshot {
                candidate_bundle: Some(bundle),
                ..
            }),
    } = resolved
    {
        for bytes in &bundle.candidates {
            if let Ok(advertisement) = serde_json::from_slice::<CandidateAdvertisement>(bytes) {
                if let Ok(candidate) = Candidate::from_advertisement(advertisement) {
                    candidates.push(candidate);
                }
            }
        }
    }
    append_configured_endpoint(&mut candidates, peer);
    candidates
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
    use network_relay::v2::ResolveStatus;
    use std::time::Duration;

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
        // §10/§40：每次 connect 前先 Resolve；OFFLINE 直接失败，不进入 Direct。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let result = orchestrator.resolve("peer-b").await;
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
        let resolved = orchestrator.resolve("peer-b").await.expect("local direct");
        assert_eq!(resolved_runtime_epoch(&resolved), None);
        assert!(matches!(resolved, ResolvedPeer::Ready { discovery: None }));
    }

    #[tokio::test]
    async fn resolve_not_ready_maps_to_retriable_timeout() {
        // §10：NOT_READY → 可短暂重试（Timeout + RetryAfter）。
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay_control.write().await = Some(control);
        let orchestrator = ConnectionOrchestrator::new(state);
        let result = orchestrator.resolve("peer-b").await;
        assert!(matches!(
            result,
            Err(error)
                if error.code == NetworkErrorCode::Timeout as i32
                    && error.retry_disposition
                        == network_protocol::RetryDisposition::RetryAfter as i32
        ));
    }

    /// 预置 Resolve 状态的 mock 控制面（测试用）。
    struct StubControl {
        status: network_relay::v2::ResolveStatus,
        discovery: Option<DiscoverySnapshot>,
    }

    impl StubControl {
        fn new(
            status: network_relay::v2::ResolveStatus,
            discovery: Option<DiscoverySnapshot>,
        ) -> Arc<Self> {
            Arc::new(Self { status, discovery })
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
    }
}
