//! transport-network v2：唯一连接入口 `ConnectivityAttemptCoordinator`（设计 §11/§12/§14/§15/§37）。
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
//! 1. **Stage A**（§10）：先以 fresh cache + configured endpoint 做纯 Direct 尝试，
//!    并在进入控制面前复用已健康且 capability-compatible 的现有路径；只有找不到
//!    可复用路径才经 `DiscoveryResolver` 解析对端 4-state。
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
use std::time::{Duration, Instant, SystemTime};
use tokio::sync::{watch, Mutex};

use network_nat::{
    Candidate, CandidateAdvertisement, CandidateKind, CandidatePayloadV2, CandidateTransport,
    ConnectivityAttempt, ResolvedCandidateCache, ResolvedCandidateSnapshot,
    RuntimeEpoch as NatRuntimeEpoch, MAX_CANDIDATES_PER_SIGNAL,
};
use network_protocol::{
    CommunicationClass, NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState,
    RouteType,
};
use network_relay::v2::{
    ConnectivityAttemptStart, DiscoverySnapshot, ResolvePeerResponse, RuntimeEpoch,
};
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
use crate::runtime::ConnectDecision;
use crate::runtime::{ConnectionAdmissionLease, RuntimeState};
use crate::session::SessionId;

use super::{
    communication_class_capability, default_communication_class, profile_capability_mask,
    DIRECT_CONNECT_WINDOW, RELAY_RESERVE_TIMEOUT, RESOLVE_TIMEOUT, STAGE_A_CONNECT_BUDGET,
};

/// 编排器状态机的可观察状态（§11）。`Idle`/`Failed` 是诊断端点（初始/终态），
/// 当前不在 `set_stage` 中显式转换。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum ConnectivityAttemptState {
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
pub(crate) struct ConnectivityAttemptCoordinator {
    state: Arc<RuntimeState>,
    /// 当前状态机位置（诊断/测试）。
    stage: std::sync::atomic::AtomicU8,
}

/// Owns the local Session reserved at the Offer boundary until the
/// coordinator has attached a route successfully.  A timeout or task abort
/// drops this guard and asynchronously retires the exact Session, preventing
/// a cancelled attempt from poisoning the next connect admission.
struct SessionCleanupGuard {
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: Option<SessionId>,
}

impl SessionCleanupGuard {
    fn new(state: Arc<RuntimeState>, peer_id: &str, session_id: SessionId) -> Self {
        Self {
            state,
            peer_id: peer_id.to_string(),
            session_id: Some(session_id),
        }
    }

    fn disarm(&mut self) {
        self.session_id = None;
    }
}

impl Drop for SessionCleanupGuard {
    fn drop(&mut self) {
        let Some(session_id) = self.session_id.take() else {
            return;
        };
        let state = Arc::clone(&self.state);
        let peer_id = self.peer_id.clone();
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                state.fail_session(&peer_id, session_id).await;
            });
        }
    }
}

/// Inputs shared by the bounded Stage B Resolve transaction and its optional
/// NOT_READY retry. Keeping the request as one value also makes the retry
/// carry the exact same local discovery snapshot and identity binding.
struct StageBTransactionRequest {
    peer_id: String,
    initiator_device_id: String,
    initiator_runtime_epoch: RuntimeEpoch,
    initiator_revision: u32,
    initiator_snapshot: Option<DiscoverySnapshot>,
    connect_deadline: Instant,
}

/// Owns candidate snapshot decoding, cache projection, and deterministic
/// Direct target selection. It never starts a connection or mutates the
/// coordinator state machine.
struct CandidateSnapshotPolicy;

/// Owns the authoritative Stage B/Stage C admission gates. Keeping these
/// decisions pure prevents configured candidates from bypassing Relay status,
/// E2EE, capability, or connect-budget requirements.
struct ConnectivityStageEligibility;

impl ConnectivityAttemptCoordinator {
    pub(crate) fn new(state: Arc<RuntimeState>) -> Self {
        Self {
            state,
            stage: std::sync::atomic::AtomicU8::new(0),
        }
    }

    /// 当前状态机阶段。
    #[allow(dead_code)] // 诊断/测试查询面；生产路径通过日志观察状态机
    pub(crate) fn stage(&self) -> ConnectivityAttemptState {
        use ConnectivityAttemptState::*;
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

    fn set_stage(&self, state: ConnectivityAttemptState) {
        use ConnectivityAttemptState::*;
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

    /// Run only the bounded Direct stage for a recovery probe.  A healthy
    /// Relay path remains available while this operation runs; this method
    /// never enters Resolve or Relay fallback.
    pub(crate) async fn probe_direct(
        &self,
        peer_id: &str,
        class: CommunicationClass,
    ) -> Result<(), ProtocolError> {
        let endpoint = self
            .state
            .lifecycle
            .endpoint
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "direct_probe",
                    peer_id,
                )
            })?;
        let identity = self
            .state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "direct_probe",
                    peer_id,
                )
            })?;
        let peer = self
            .state
            .peers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "peer has no configured route",
                    "direct_probe",
                    peer_id,
                )
            })?;
        let capability = communication_class_capability(default_communication_class(class));
        if self
            .try_stage_a_direct(peer_id, &peer, endpoint, identity, capability)
            .await?
        {
            Ok(())
        } else {
            Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "direct recovery probe did not produce a path",
                "direct_probe",
                peer_id,
            ))
        }
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
        self.connect_with_capabilities(peer_id, communication_class_capability(class))
            .await
    }

    /// Internal connectivity entry point used by the peer supervisor when
    /// concurrent business requests have been merged into one capability mask.
    pub(crate) async fn connect_with_capabilities(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Result<(), ProtocolError> {
        match tokio::time::timeout(
            super::OVERALL_CONNECT_BUDGET,
            self.connect_with_capabilities_bounded(peer_id, capability),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "overall connectivity budget elapsed",
                "connect",
                peer_id,
            )),
        }
    }

    async fn connect_with_capabilities_bounded(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Result<(), ProtocolError> {
        let connect_deadline = Instant::now() + super::OVERALL_CONNECT_BUDGET;
        let state = Arc::clone(&self.state);
        // 配置/身份/对端校验。
        let endpoint = state
            .lifecycle
            .endpoint
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "connect",
                    peer_id,
                )
            })?;
        let identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
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

        // Stage A is deliberately independent of the Relay control plane.  A
        // fresh monotonic remote cache/configured endpoint is enough to start
        // the bounded direct race; an already healthy path is handled by the
        // pre-control reuse fast path below. Resolve/Offer are only entered after this
        // pre-control reuse fast path and after the uncoordinated attempt fails.
        if self
            .try_stage_a_direct(
                peer_id,
                &peer,
                endpoint.clone(),
                identity.clone(),
                capability,
            )
            .await?
        {
            return Ok(());
        }

        // Any healthy path is also a reuse fast path.  It must be
        // decided before Stage B opens the one-shot Resolve → Offer ticket:
        // the frozen ConnectivityOffer has no target field, so emitting an
        // Offer and then returning from reuse would leave an unsolicited
        // server-side coordination ticket (and possibly a leaked waiter).
        if let Some(reused) = self.try_reuse_before_control(peer_id, capability).await? {
            self.finish_reuse(peer_id, reused).await;
            return Ok(());
        }

        // -----------------------------------------------------------------
        // 1. RESOLVING（§10）：Stage B owns one atomic Resolve → Offer
        // coordination transaction. The control client holds its narrow gate
        // through the authoritative Resolve and Offer enqueue, then returns
        // the Resolve snapshot plus an answer waiter. This keeps the target
        // binding coherent on the target-less ConnectivityOffer wire frame.
        // -----------------------------------------------------------------
        let (control, ready_presence_ttl) = {
            let control = self
                .state
                .relay
                .control
                .read()
                .await
                .clone()
                .ok_or_else(|| {
                    protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        "authoritative Resolve is unavailable",
                        "connect",
                        peer_id,
                    )
                })?;
            if !control.is_usable().await {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "authoritative Resolve control plane is unavailable",
                    "connect",
                    peer_id,
                ));
            }
            let ready_presence_ttl = control.ready_presence_ttl();
            (control, ready_presence_ttl)
        };
        let (local_epoch, local_revision, local_snapshot) = {
            let manager = self.state.local_discovery.read().await;
            manager
                .as_ref()
                .map(|manager| {
                    (
                        manager.runtime_epoch(),
                        manager.revision(),
                        Some(manager.snapshot()),
                    )
                })
                .unwrap_or((RuntimeEpoch { high: 0, low: 0 }, 1, None))
        };

        // Reserve the local ConnectionSession before the atomic Resolve → Offer
        // transaction.  ConnectivityOffer carries no target, so every request
        // that reaches the Offer boundary must already have a local attempt
        // owner; reuse and concurrent-admission decisions must return before it.
        // A concurrent connect is observed rather than merged into the local
        // attempt. If that admission becomes stale or cannot retry, perform
        // one fresh ownership/Stage-B evaluation before returning failure.
        let mut re_evaluated_in_progress = false;
        let session_id = loop {
            match state.begin_connect(peer_id, capability).await {
                ConnectDecision::AlreadyConnected(session_id) => {
                    self.finish_reuse(peer_id, session_id).await;
                    return Ok(());
                }
                ConnectDecision::CapabilityMismatch(_) => {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "existing connection does not satisfy this path capability",
                        "connect",
                        peer_id,
                    ));
                }
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(session_id) => {
                    // Do not merge this request into Session state. Wait for
                    // the existing attempt, then evaluate this request against
                    // the route it actually produced. This branch is before
                    // Resolve/Offer, so it cannot orphan a coordination ticket.
                    let retry_admission = loop {
                        if state.connection_sessions.current_session_id(peer_id).await
                            != Some(session_id)
                        {
                            break true;
                        }
                        if state.path_is_connected(peer_id).await {
                            let supported =
                                state.path_supports_capability(peer_id, capability).await;
                            if !supported {
                                return Err(protocol_error_with_peer(
                                    NetworkErrorCode::NoRoute,
                                    "existing route does not satisfy this path capability",
                                    "connect",
                                    peer_id,
                                ));
                            }
                            self.finish_reuse(peer_id, session_id).await;
                            return Ok(());
                        }
                        if !state
                            .path_admission_can_retry(peer_id, Some(session_id))
                            .await
                        {
                            break true;
                        }
                        if Instant::now() >= connect_deadline {
                            return Err(protocol_error_with_peer(
                                NetworkErrorCode::Timeout,
                                "shared connection attempt exceeded the connect budget",
                                "connect",
                                peer_id,
                            ));
                        }
                        state.wait_for_path_change().await;
                    };
                    if retry_admission && !re_evaluated_in_progress {
                        re_evaluated_in_progress = true;
                        continue;
                    }
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "shared connection attempt did not produce a route",
                        "connect",
                        peer_id,
                    ));
                }
            }
        };
        let mut session_cleanup = SessionCleanupGuard::new(Arc::clone(&state), peer_id, session_id);

        self.set_stage(ConnectivityAttemptState::Resolving);
        let (attempt_id, coordination) = match self
            .begin_stage_b_transaction(
                Arc::clone(&control),
                StageBTransactionRequest {
                    peer_id: peer_id.to_string(),
                    initiator_device_id: identity.device_id.clone(),
                    initiator_runtime_epoch: local_epoch.clone(),
                    initiator_revision: local_revision,
                    initiator_snapshot: local_snapshot,
                    connect_deadline,
                },
            )
            .await
        {
            Ok(result) => result,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let resolved = match ConnectivityStageEligibility::ready_peer_from_coordination(
            &coordination.resolved,
            peer_id,
        ) {
            Ok(resolved) => resolved,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        self.set_stage(ConnectivityAttemptState::Resolved);
        CandidateSnapshotPolicy::update_remote_candidate_cache(
            &state,
            peer_id,
            CandidateSnapshotPolicy::resolved_snapshot(&resolved),
            ready_presence_ttl,
        )
        .await;

        let remote_epoch = CandidateSnapshotPolicy::resolved_runtime_epoch(&resolved);

        // Resolve remains authoritative for epoch/index reconciliation, but
        // the Offer is already committed and this coordinator owns a fresh
        // local Session. Never turn this point back into a reuse return path.
        if let Some(obsolete) = state
            .ready_session_index
            .take_obsolete(peer_id, &remote_epoch)
        {
            tracing::info!(
                peer_id = %peer_id,
                session = ?obsolete.session_id,
                "remote runtime epoch changed; retiring obsolete ready index entry"
            );
            // `Started(session_id)` means the current admission was empty when
            // ownership was acquired. Retire only an exact stale admission if
            // one still exists; do not close the current path or invalidate the
            // PeerSupervisor that owns this coordinator.
            if obsolete.session_id != session_id {
                state
                    .retire_session_without_transport(peer_id, obsolete.session_id)
                    .await;
            }
        }

        // -----------------------------------------------------------------
        // 2. Create ConnectivityAttempt（§12）+ COORDINATING（§14）。
        // -----------------------------------------------------------------
        self.set_stage(ConnectivityAttemptState::Coordinating);
        // 一次性 ConnectivityAttempt（§12）：candidate 完全 attempt-scoped。
        // - `local_candidates`：本端已 gather 的候选（用于信令/供对端直连）。
        // - `remote_candidates`：Resolve 返回的对端候选（§14 服务器附带 A 当前
        //   Discovery 给 B）+ 手工配置 endpoint。
        // Direct 的**连接目标**是 remote_candidates；本端候选绝不加入连接目标。
        let attempt_started_at = SystemTime::now();
        let mut attempt = ConnectivityAttempt::with_connect_window(
            attempt_id.clone(),
            peer_id.to_string(),
            CandidateSnapshotPolicy::nat_runtime_epoch(&local_epoch),
            attempt_started_at,
            DIRECT_CONNECT_WINDOW,
        )
        .with_local_candidates(
            CandidateSnapshotPolicy::collect_local_candidates(state.clone()).await,
        );
        let initial_remote_candidates =
            CandidateSnapshotPolicy::resolved_candidates(&resolved, &peer);
        if let Err(error) = attempt.apply_remote_candidates(
            CandidateSnapshotPolicy::resolved_snapshot(&resolved).and_then(|snapshot| {
                snapshot
                    .runtime_epoch
                    .as_ref()
                    .map(CandidateSnapshotPolicy::nat_runtime_epoch)
            }),
            CandidateSnapshotPolicy::resolved_snapshot(&resolved)
                .map(|snapshot| u64::from(snapshot.revision))
                .unwrap_or(0),
            initial_remote_candidates,
        ) {
            state.fail_session(peer_id, session_id).await;
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
        let candidate_updates = match self.spawn_coordination(
            coordination,
            peer_id.to_string(),
            attempt_id.clone(),
            Arc::clone(&attempt),
            preserved_direct_candidates,
            ready_presence_ttl,
        ) {
            Ok(candidate_updates) => candidate_updates,
            Err(error) => {
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let remote_candidates = attempt.lock().await.remote_candidates().to_vec();
        let _ = attempt
            .lock()
            .await
            .set_state(network_nat::ConnectivityAttemptState::Connecting);

        // -----------------------------------------------------------------
        // 5. DIRECT_CONNECTING（§15）：Direct First 4s。
        // -----------------------------------------------------------------
        self.set_stage(ConnectivityAttemptState::DirectConnecting);
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
                required_capabilities: capability,
                allow_websocket: capability == super::CAPABILITY_RELIABLE_MESSAGE,
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
                let admission = match self.attach_direct_route(peer_id, route).await {
                    Ok(admission) => admission,
                    Err(error) => {
                        state.fail_session(peer_id, session_id).await;
                        return Err(error);
                    }
                };
                let final_remote_epoch = attempt
                    .lock()
                    .await
                    .remote_runtime_epoch()
                    .map(CandidateSnapshotPolicy::runtime_epoch_from_nat)
                    .or_else(|| remote_epoch.clone());
                self.register_current(
                    Arc::clone(&state),
                    peer_id,
                    &final_remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(ConnectivityAttemptState::ConnectedDirect);
                session_cleanup.disarm();
                Ok(())
            }
            // Direct 失败：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING（§15/§37）。
            Err(direct_error) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Expired);
                self.set_stage(ConnectivityAttemptState::DirectFailed);
                if !ConnectivityStageEligibility::relay_fallback_is_eligible(
                    &resolved,
                    capability,
                    peer.e2ee_policy,
                    connect_deadline,
                ) {
                    state.fail_session(peer_id, session_id).await;
                    return Err(direct_error);
                }
                match self
                    .connect_relay_fallback(
                        peer_id,
                        session_id,
                        &peer,
                        &attempt_id,
                        capability,
                        connect_deadline,
                    )
                    .await
                {
                    Ok(admission) => {
                        let final_remote_epoch = attempt
                            .lock()
                            .await
                            .remote_runtime_epoch()
                            .map(CandidateSnapshotPolicy::runtime_epoch_from_nat)
                            .or_else(|| remote_epoch.clone());
                        self.register_current(
                            Arc::clone(&state),
                            peer_id,
                            &final_remote_epoch,
                            admission.session_id,
                        )
                        .await;
                        self.set_stage(ConnectivityAttemptState::ConnectedRelay);
                        session_cleanup.disarm();
                        Ok(())
                    }
                    Err(relay_error) => {
                        state.fail_session(peer_id, session_id).await;
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

    /// Begin the Stage B control transaction, retrying NOT_READY exactly once.
    /// A non-READY transaction never enqueues an Offer, so replacing its
    /// attempt id on retry cannot leave a server-side waiter behind. READY is
    /// returned with the same id that will be used by the following attempt.
    async fn begin_stage_b_transaction(
        &self,
        control: Arc<dyn crate::discovery::DiscoveryControlPlane>,
        request: StageBTransactionRequest,
    ) -> Result<(String, ConnectivityAttemptStart), ProtocolError> {
        let mut attempt_id = new_attempt_id();
        let mut coordination = control
            .begin_connectivity_attempt(
                attempt_id.clone(),
                request.peer_id.clone(),
                request.initiator_device_id.clone(),
                request.initiator_runtime_epoch.clone(),
                request.initiator_revision,
                request.initiator_snapshot.clone(),
            )
            .await
            .map_err(|error| relay_resolve_error(&error, &request.peer_id))?;

        if network_relay::v2::ResolveStatus::try_from(coordination.resolved.status)
            != Ok(network_relay::v2::ResolveStatus::NotReady)
        {
            return Ok((attempt_id, coordination));
        }

        // Bound the retry wait by the public connect budget. If no budget
        // remains, return the authoritative first NOT_READY response so the
        // normal status mapper reports PeerNotReady instead of fabricating a
        // READY result or extending the operation beyond its deadline.
        let retry = Duration::from_millis(u64::from(coordination.resolved.retry_after_ms))
            .min(super::NOT_READY_WAIT);
        let remaining = request
            .connect_deadline
            .saturating_duration_since(Instant::now());
        if retry >= remaining {
            return Ok((attempt_id, coordination));
        }
        tokio::time::sleep(retry).await;
        if Instant::now() >= request.connect_deadline {
            return Ok((attempt_id, coordination));
        }

        // The first NOT_READY path has no Offer and therefore no active
        // server-side coordination ticket. A fresh attempt id keeps each
        // ConnectivityAttempt independently scoped on the retry.
        attempt_id = new_attempt_id();
        let retry_peer_id = request.peer_id.clone();
        coordination = control
            .begin_connectivity_attempt(
                attempt_id.clone(),
                retry_peer_id,
                request.initiator_device_id,
                request.initiator_runtime_epoch,
                request.initiator_revision,
                request.initiator_snapshot,
            )
            .await
            .map_err(|error| relay_resolve_error(&error, &request.peer_id))?;
        Ok((attempt_id, coordination))
    }

    /// Run the frozen pure-direct Stage A.  The method returns `true` only after
    /// a route has been attached and registered; a failed race retires its
    /// temporary Session and lets the caller enter Stage B.
    async fn try_stage_a_direct(
        &self,
        peer_id: &str,
        peer: &crate::runtime::PeerConfig,
        endpoint: quinn::Endpoint,
        identity: Arc<network_identity::DeviceIdentity>,
        capability: u8,
    ) -> Result<bool, ProtocolError> {
        if self
            .state
            .has_ready_direct_path_for_capability(peer_id, capability)
            .await
        {
            return Ok(true);
        }

        let (candidates, remote_epoch) = {
            let caches = self.state.remote_candidate_cache.read().await;
            CandidateSnapshotPolicy::stage_a_direct_candidates(
                caches.get(peer_id),
                peer,
                Instant::now(),
            )
        };
        if candidates.is_empty() {
            return Ok(false);
        }

        let (session_id, owns_session) = match self
            .state
            .connection_sessions
            .current_session_id(peer_id)
            .await
        {
            Some(session_id) => (session_id, false),
            None => match self.state.begin_connect(peer_id, capability).await {
                ConnectDecision::Started(session_id) => (session_id, true),
                ConnectDecision::AlreadyConnected(session_id) => (session_id, false),
                ConnectDecision::CapabilityMismatch(_) => return Ok(false),
                ConnectDecision::InProgress(_) => return Ok(false),
            },
        };
        self.set_stage(ConnectivityAttemptState::DirectConnecting);
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        drop(candidate_update_tx);
        let attempt_id = new_attempt_id();
        let direct_result = tokio::time::timeout(
            STAGE_A_CONNECT_BUDGET,
            connect_direct_or_generic(DirectRouteAttempt {
                state: Arc::clone(&self.state),
                endpoint,
                candidates,
                identity,
                expected_peer_public_key: peer.identity_public_key,
                peer_id: peer_id.to_string(),
                session_binding: session_id.wire_key(),
                session_id,
                attempt_id,
                connect_window: STAGE_A_CONNECT_BUDGET,
                required_capabilities: capability,
                allow_websocket: capability == super::CAPABILITY_RELIABLE_MESSAGE,
                candidate_updates,
            }),
        )
        .await;
        match direct_result {
            Ok(Ok(route)) => {
                let admission = match self.attach_direct_route(peer_id, route).await {
                    Ok(admission) => admission,
                    Err(error) => {
                        if owns_session {
                            self.state.fail_session(peer_id, session_id).await;
                        }
                        return Err(error);
                    }
                };
                self.register_current(
                    Arc::clone(&self.state),
                    peer_id,
                    &remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(ConnectivityAttemptState::ConnectedDirect);
                Ok(true)
            }
            Ok(Err(error)) => {
                if owns_session {
                    self.state.fail_session(peer_id, session_id).await;
                }
                tracing::debug!(peer_id = %peer_id, error = %error.message, "pure direct Stage A failed");
                Ok(false)
            }
            Err(_) => {
                if owns_session {
                    self.state.fail_session(peer_id, session_id).await;
                }
                tracing::debug!(peer_id = %peer_id, "pure direct Stage A window elapsed");
                Ok(false)
            }
        }
    }

    /// Resolve 阶段：控制面可用时走服务器权威解析（§10）。Configured/local
    /// candidates belong only to Stage A; a non-READY Resolve result never
    /// becomes a synthetic READY and therefore cannot unlock Stage C Relay.
    #[allow(dead_code)] // compatibility seam for resolver-focused unit tests
    async fn resolve(
        &self,
        peer_id: &str,
        _peer: &crate::runtime::PeerConfig,
    ) -> Result<ResolvedPeer, ProtocolError> {
        let Some(control) = self.state.relay.control.read().await.clone() else {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "authoritative Resolve is unavailable",
                "connect",
                peer_id,
            ));
        };
        if !control.is_usable().await {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "authoritative Resolve control plane is unavailable",
                "connect",
                peer_id,
            ));
        }
        let resolver = DiscoveryResolver::new(control);
        let result = match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
            Ok(Ok(ResolvedPeer::NotReady { retry_after_ms })) => {
                // NOT_READY is the only status with a bounded retry. A second
                // NOT_READY remains authoritative and must not become READY.
                let retry =
                    Duration::from_millis(u64::from(retry_after_ms)).min(super::NOT_READY_WAIT);
                tokio::time::sleep(retry).await;
                match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
                    Ok(Ok(resolved)) => Ok(resolved),
                    Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
                    Err(_) => Err(protocol_error_with_peer(
                        NetworkErrorCode::Timeout,
                        "Resolve retry timed out",
                        "connect",
                        peer_id,
                    )),
                }
            }
            Ok(Ok(resolved)) => Ok(resolved),
            Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Resolve timed out",
                "connect",
                peer_id,
            )),
        };
        ConnectivityStageEligibility::authoritative_resolve_or_error(peer_id, result)
    }

    /// Reuse an already healthy path before opening the Stage B Resolve →
    /// Offer transaction.  The physical path owner is authoritative for this
    /// fast path: a connected session with the requested capability is already
    /// usable, while an absent/unhealthy path falls through to the
    /// authoritative Resolve and the normal epoch/index checks.
    async fn try_reuse_before_control(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Result<Option<SessionId>, ProtocolError> {
        let state = Arc::clone(&self.state);
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return Ok(None);
        };
        if !state.path_is_connected(peer_id).await
            || !state.path_supports_capability(peer_id, capability).await
        {
            return Ok(None);
        }

        // A control-plane epoch hint fences the old authenticated transport
        // before this fast path can reuse it.  Normal TTL expiry does not
        // retire a healthy route; a pending/new epoch does, and the regular
        // Stage B Resolve will establish the replacement authority.
        if let Some(registered) = state
            .ready_session_index
            .lookup_registered(peer_id, capability)
        {
            if registered.session_id == session_id {
                let epoch_changed =
                    if let Some(registered_epoch) = registered.remote_runtime_epoch.as_ref() {
                        let cache = state.remote_candidate_cache.read().await;
                        cache.get(peer_id).is_some_and(|entry| {
                            entry.pending_remote_epoch().is_some() || {
                                Some(CandidateSnapshotPolicy::runtime_epoch_from_nat(
                                    entry.runtime_epoch,
                                ))
                            } != Some(
                                registered_epoch.clone(),
                            )
                        })
                    } else {
                        false
                    };
                if epoch_changed {
                    // This coordinator runs under the peer supervisor's
                    // generation. Retire the attempt-local session and path
                    // without disconnecting that supervisor from inside its
                    // own connectivity task.
                    state.fail_session(peer_id, session_id).await;
                    return Ok(None);
                }
            }
        }
        Ok(Some(session_id))
    }

    /// Publish the single success signal for a pre-control or shared
    /// in-progress admission reuse.
    async fn finish_reuse(&self, peer_id: &str, session_id: SessionId) {
        let state = Arc::clone(&self.state);
        tracing::info!(
            peer_id = %peer_id,
            session = ?session_id,
            "reused existing healthy connection"
        );
        // 重用成功同样发布 Connected 终态：Dart connect() 把该事件当作成功信号
        // （失败才由命令面发 Failed），不发布会令其等待超时。
        let route = state
            .path_route(peer_id)
            .await
            .unwrap_or(RouteType::Unspecified);
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Connected,
            route,
            None,
        );
        self.set_stage(ConnectivityAttemptState::ConnectedDirect);
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
        let Some(capability) = state
            .path_profile(peer_id)
            .await
            .map(profile_capability_mask)
        else {
            return;
        };
        state
            .ready_session_index
            .register(peer_id, remote_epoch.clone(), capability, session_id);
    }

    /// Wait for the answer from the already-enqueued ConnectivityOffer
    /// without blocking the Direct window.
    fn spawn_coordination(
        &self,
        coordination: ConnectivityAttemptStart,
        peer_id: String,
        attempt_id: String,
        attempt: Arc<Mutex<ConnectivityAttempt>>,
        preserved_direct_candidates: Vec<Candidate>,
        ready_presence_ttl: Option<Duration>,
    ) -> Result<watch::Receiver<Option<Vec<Candidate>>>, ProtocolError> {
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        let state = Arc::clone(&self.state);
        let supervisor = Arc::clone(&state.task_supervisor);
        let error_peer_id = peer_id.clone();
        let task = supervisor.spawn_runtime("connectivity-coordination", async move {
            match coordination.wait_for_answer().await {
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
                            CandidateSnapshotPolicy::update_remote_candidate_cache(
                                &state,
                                &peer_id,
                                Some(snapshot),
                                ready_presence_ttl,
                            )
                            .await;
                            let mut candidates =
                                CandidateSnapshotPolicy::discovery_snapshot_candidates(snapshot);
                            candidates.extend(preserved_direct_candidates.iter().cloned());
                            let result = {
                                let mut attempt = attempt.lock().await;
                                let result = attempt.apply_remote_candidates(
                                    snapshot
                                        .runtime_epoch
                                        .as_ref()
                                        .map(CandidateSnapshotPolicy::nat_runtime_epoch),
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
        if task.is_none() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "connectivity coordination task could not be started",
                "connect",
                &error_peer_id,
            ));
        }
        Ok(candidate_updates)
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
        capability: u8,
        connect_deadline: Instant,
    ) -> Result<ConnectionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);

        let reserve_budget = connect_deadline
            .saturating_duration_since(Instant::now())
            .min(RELAY_RESERVE_TIMEOUT);
        if reserve_budget.is_zero() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Relay reservation budget elapsed",
                "connect",
                peer_id,
            ));
        }

        // RELAY_RESERVING：reserve_relay 经 v2 控制面路由（§31 reserveRelay）。
        self.set_stage(ConnectivityAttemptState::RelayReserving);
        let reservation = {
            let control = state.relay.control.read().await.clone().ok_or_else(|| {
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
                reserve_budget,
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
        self.set_stage(ConnectivityAttemptState::RelayConnecting);
        let data =
            match crate::relay::connect_initiator_relay_data(&state, peer_id, reservation).await {
                Ok(data) => data,
                Err(error) => {
                    state.fail_session(peer_id, session_id).await;
                    return Err(error);
                }
            };
        let crypto_identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
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
                state.fail_session(peer_id, session_id).await;
                return Err(error);
            }
        };
        let session_id = admission.session_id;
        let relay_profile = crate::connection::ConnectionProfile::for_route(RouteType::Relay)
            .expect("Relay route has a composed profile");
        if !state
            .candidate_supports(peer_id, session_id, relay_profile, capability)
            .await
        {
            state
                .connection_sessions
                .release_authenticated_session(peer_id, session_id, &crypto.remote_session_binding)
                .await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "Relay route does not satisfy the requested capability",
                "connect",
                peer_id,
            ));
        }
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
        let attached = state
            .mark_relay_route_connected(peer_id, session_id, Some(data))
            .await;
        if !attached {
            state.crypto.remove_session(peer_id, &session_id.wire_key());
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "Relay route completed after Session was closed",
                "connect",
                peer_id,
            ));
        }
        // PathHandshakeV2 may have completed while the Relay event loop was
        // still able to receive frames. Publish business admission only after
        // the initiator's Relay route is attached to its Session.
        state
            .relay
            .relay_path_ready
            .write()
            .await
            .insert(peer_id.to_string());
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
    ) -> Result<ConnectionAdmissionLease, ProtocolError> {
        let state = Arc::clone(&self.state);
        match route {
            ConnectedRoute::Quic {
                connection,
                crypto,
                admission,
            } => {
                let session_id = admission.session_id;
                let profile =
                    crate::connection::ConnectionProfile::for_route(RouteType::QuicDirect)
                        .expect("QUIC direct route has a composed profile");
                if !state
                    .candidate_supports_required(peer_id, session_id, profile)
                    .await
                {
                    connection.close(VarInt::from_u32(0), b"candidate lacks requested capability");
                    state
                        .connection_sessions
                        .release_authenticated_session(
                            peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "QUIC route does not satisfy the requested capability",
                        "connect",
                        peer_id,
                    ));
                }
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
                let _previous_route = match state
                    .attach_connection_for_session(
                        peer_id,
                        Some(session_id),
                        connection.clone(),
                        RouteType::QuicDirect,
                    )
                    .await
                {
                    Ok(previous_route) => previous_route,
                    Err(_) => {
                        state.crypto.remove_session(peer_id, &session_id.wire_key());
                        state
                            .connection_sessions
                            .release_authenticated_session(
                                peer_id,
                                session_id,
                                &crypto.remote_session_binding,
                            )
                            .await;
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "connection completed after Session was closed",
                            "connect",
                            peer_id,
                        ));
                    }
                };
                if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
                    state.crypto.remove_session(peer_id, &session_id.wire_key());
                    state
                        .connection_sessions
                        .release_authenticated_session(
                            peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
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
                crate::peer::ConnectionReceiverSupervisor::spawn_session_receivers(
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
                if !state
                    .candidate_supports_required(peer_id, session_id, profile)
                    .await
                {
                    scope.close().await;
                    state
                        .connection_sessions
                        .release_authenticated_session(
                            peer_id,
                            session_id,
                            &generic.crypto.remote_session_binding,
                        )
                        .await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::NoRoute,
                        "generic route does not satisfy the requested capability",
                        "connect",
                        peer_id,
                    ));
                }
                if install_admitted_crypto(&state, peer_id, &admission, &generic.crypto)
                    .await
                    .is_err()
                {
                    scope.close().await;
                    state.fail_session(peer_id, session_id).await;
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::AuthenticationFailed,
                        "application E2EE handshake was not accepted",
                        "connect",
                        peer_id,
                    ));
                }
                let _previous_route = match state
                    .attach_generic_route_for_session(peer_id, Some(session_id), &mut scope)
                    .await
                {
                    Ok(previous_route) => previous_route,
                    Err(_) => {
                        scope.close().await;
                        state.crypto.remove_session(peer_id, &session_id.wire_key());
                        state
                            .connection_sessions
                            .release_authenticated_session(
                                peer_id,
                                session_id,
                                &generic.crypto.remote_session_binding,
                            )
                            .await;
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::Cancelled,
                            "generic connection completed after Session was closed",
                            "connect",
                            peer_id,
                        ));
                    }
                };
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

/// 关闭一个已登记的 connection for the lifecycle regression harness.
///
/// Production coordination retires stale admissions through `RuntimeState`
/// without disconnecting the owning `PeerSupervisor`; this legacy helper is
/// retained only by the transfer-resume test fixture.
#[cfg(test)]
pub(crate) async fn close_session_and_unregister(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
) {
    let _ = state.close_transport_path(&peer_id).await;
    state
        .connection_sessions
        .retire_session(&peer_id, session_id)
        .await;
    state.cancel_session_tasks(&peer_id, session_id).await;
    state
        .ready_session_index
        .unregister_if_session(&peer_id, session_id);
    // Keep the peer-owned lifecycle coordinator aligned with the destroyed
    // ConnectionSession. Otherwise a later explicit ConnectPeer would join
    // the stale Online generation and never start a fresh attempt_coordinator run.
    let _ = state.peer_supervisors.disconnect(&peer_id);
    // 显式关闭连接（§34 Close old）时清理接收端 dedup/ordered 状态；transport
    // 丢失路径不清理（§20 需要跨连接去重）。
    state.delivery.close_peer(&peer_id).await;
}

/// 生成一次独立的 attempt_id（§12：每次建连独立 attempt）。
fn new_attempt_id() -> String {
    hex::encode(rand::random::<[u8; 16]>())
}

/// 从 Resolve 结果提取对端 runtime_epoch。
impl CandidateSnapshotPolicy {
    fn nat_runtime_epoch(epoch: &RuntimeEpoch) -> NatRuntimeEpoch {
        NatRuntimeEpoch {
            high: epoch.high,
            low: epoch.low,
        }
    }

    fn runtime_epoch_from_nat(epoch: NatRuntimeEpoch) -> RuntimeEpoch {
        RuntimeEpoch {
            high: epoch.high,
            low: epoch.low,
        }
    }

    fn resolved_runtime_epoch(resolved: &ResolvedPeer) -> Option<RuntimeEpoch> {
        match resolved {
            ResolvedPeer::Ready { discovery } => discovery
                .as_ref()
                .and_then(|snapshot| snapshot.runtime_epoch.clone()),
            _ => None,
        }
    }
}

/// Convert the control transaction's Resolve response into the coordinator's
/// typed resolver result. Keep the status mapping here so test control planes
/// and future implementations cannot turn a non-READY response into a
/// synthetic usable peer.
impl ConnectivityStageEligibility {
    fn ready_peer_from_coordination(
        response: &ResolvePeerResponse,
        peer_id: &str,
    ) -> Result<ResolvedPeer, ProtocolError> {
        match network_relay::v2::ResolveStatus::try_from(response.status) {
            Ok(network_relay::v2::ResolveStatus::Ready) => {
                let Some(discovery) = response.discovery.clone() else {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        "Relay coordination returned READY without discovery",
                        "connect",
                        peer_id,
                    ));
                };
                Ok(ResolvedPeer::Ready {
                    discovery: Some(discovery),
                })
            }
            Ok(network_relay::v2::ResolveStatus::Offline) => Err(protocol_error_with_peer(
                NetworkErrorCode::PeerOffline,
                "Relay peer is offline",
                "connect",
                peer_id,
            )),
            Ok(network_relay::v2::ResolveStatus::NotReady) => Err(protocol_error_with_retry(
                NetworkErrorCode::PeerNotReady,
                "Relay peer discovery is not ready",
                "connect",
                Some(peer_id),
                network_protocol::RetryDisposition::RetryAfter,
                (response.retry_after_ms / 1000).max(1),
            )),
            Ok(network_relay::v2::ResolveStatus::Unknown)
            | Ok(network_relay::v2::ResolveStatus::Unspecified)
            | Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay peer resolution is unavailable",
                "connect",
                peer_id,
            )),
        }
    }
}

/// 从 Resolve 结果解码远端候选（opaque JSON → Candidate）。
impl CandidateSnapshotPolicy {
    fn resolved_snapshot(resolved: &ResolvedPeer) -> Option<&DiscoverySnapshot> {
        match resolved {
            ResolvedPeer::Ready { discovery } => discovery.as_ref(),
            ResolvedPeer::Offline
            | ResolvedPeer::NotReady { .. }
            | ResolvedPeer::Unknown { .. } => None,
        }
    }

    fn snapshot_candidate_transports(snapshot: &DiscoverySnapshot) -> Vec<CandidateTransport> {
        snapshot
            .transport_capabilities
            .iter()
            .filter_map(|value| network_relay::v2::TransportCapability::try_from(*value).ok())
            .filter_map(|capability| match capability {
                network_relay::v2::TransportCapability::Quic => Some(CandidateTransport::Quic),
                network_relay::v2::TransportCapability::Tcp => Some(CandidateTransport::Tcp),
                network_relay::v2::TransportCapability::UdpDatagram => {
                    Some(CandidateTransport::UdpDatagram)
                }
                network_relay::v2::TransportCapability::Websocket => {
                    Some(CandidateTransport::Websocket)
                }
                network_relay::v2::TransportCapability::RelayData => {
                    Some(CandidateTransport::Relay)
                }
                network_relay::v2::TransportCapability::Unspecified
                | network_relay::v2::TransportCapability::Webrtc => None,
            })
            .collect()
    }

    fn snapshot_candidate_payloads(snapshot: &DiscoverySnapshot) -> Vec<CandidatePayloadV2> {
        let advertised_transports = Self::snapshot_candidate_transports(snapshot);
        snapshot
            .candidate_bundle
            .as_ref()
            .into_iter()
            .flat_map(|bundle| bundle.candidates.iter())
            .filter_map(|bytes| serde_json::from_slice::<CandidateAdvertisement>(bytes).ok())
            .filter_map(|advertisement| {
                let mut transports = match advertisement.kind {
                    // STUN mappings are shared by QUIC and UDP datagrams. Never
                    // let a global TCP/WS capability turn them into TCP/WS probes.
                    CandidateKind::ServerReflexive => network_nat::STUN_SRFLX_TRANSPORTS.to_vec(),
                    CandidateKind::Relay => vec![CandidateTransport::Relay],
                    _ => advertised_transports
                        .iter()
                        .copied()
                        .filter(|transport| *transport != CandidateTransport::Relay)
                        .collect(),
                };
                // Empty capability lists are tolerated only for older local test
                // fixtures that predate the capability field. A RelayData-only
                // advertisement must not be turned into a synthetic QUIC direct
                // candidate.
                if transports.is_empty() && advertised_transports.is_empty() {
                    transports.push(CandidateTransport::Quic);
                }
                if transports.is_empty() {
                    return None;
                }
                let candidate = CandidatePayloadV2 {
                    version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                    candidate_id: advertisement.candidate_id,
                    endpoint: advertisement.endpoint,
                    kind: advertisement.kind,
                    transport_capabilities: transports,
                    priority: advertisement.priority,
                    interface: advertisement.interface,
                    generation: advertisement.generation,
                };
                candidate.validate().ok().map(|_| candidate)
            })
            .take(network_nat::MAX_CANDIDATE_PAYLOAD_ENTRIES)
            .collect()
    }

    fn candidate_from_v2(candidate: &CandidatePayloadV2) -> Option<Candidate> {
        if !candidate.is_direct_probe_eligible() {
            return None;
        }
        let mut direct = Candidate::new(
            candidate.endpoint,
            candidate.kind,
            candidate.interface.clone(),
        );
        direct.candidate_id = candidate.candidate_id.clone();
        direct.priority = candidate.priority;
        direct.generation = candidate.generation;
        Some(direct)
    }

    /// Build the complete uncoordinated Stage A target set. Only a fresh remote
    /// cache entry is read; configured endpoints are local operator input and are
    /// always appended. The cache carries the remote LAN/STUN candidates gathered
    /// from the peer, while Relay candidates are excluded before the Direct race.
    fn stage_a_direct_candidates(
        cache: Option<&ResolvedCandidateCache>,
        peer: &crate::runtime::PeerConfig,
        now: Instant,
    ) -> (Vec<Candidate>, Option<RuntimeEpoch>) {
        let (mut candidates, remote_epoch) = match cache {
            Some(cache) => {
                let fresh = cache.stage_a_candidates_at(now);
                let candidates = fresh
                    .unwrap_or_default()
                    .iter()
                    .filter_map(Self::candidate_from_v2)
                    .collect::<Vec<_>>();
                let remote_epoch = fresh.map(|_| RuntimeEpoch {
                    high: cache.runtime_epoch.high,
                    low: cache.runtime_epoch.low,
                });
                (candidates, remote_epoch)
            }
            None => (Vec::new(), None),
        };
        Self::append_configured_endpoint(&mut candidates, peer);
        candidates.retain(|candidate| candidate.kind != CandidateKind::Relay);
        candidates.sort_by(|left, right| {
            Self::candidate_order(left)
                .cmp(&Self::candidate_order(right))
                .then_with(|| right.priority.cmp(&left.priority))
                .then_with(|| left.candidate_id.cmp(&right.candidate_id))
        });
        (candidates, remote_epoch)
    }

    async fn update_remote_candidate_cache(
        state: &RuntimeState,
        peer_id: &str,
        snapshot: Option<&DiscoverySnapshot>,
        ready_presence_ttl: Option<Duration>,
    ) {
        let Some(snapshot) = snapshot else {
            return;
        };
        let Some(runtime_epoch) = snapshot.runtime_epoch.as_ref() else {
            return;
        };
        let candidate_snapshot = ResolvedCandidateSnapshot {
            runtime_epoch: Self::nat_runtime_epoch(runtime_epoch),
            revision: u64::from(snapshot.revision),
            candidates: Self::snapshot_candidate_payloads(snapshot),
            server_presence_ttl: ready_presence_ttl,
        };
        let learned_at = Instant::now();
        let mut cache = state.remote_candidate_cache.write().await;
        match cache.get_mut(peer_id) {
            Some(existing) => {
                if let Err(error) = existing.apply(candidate_snapshot, learned_at) {
                    tracing::debug!(%peer_id, error = %error, "ignored inconsistent remote candidate cache snapshot");
                }
            }
            None => match ResolvedCandidateCache::from_snapshot(candidate_snapshot, learned_at) {
                Ok(value) => {
                    cache.insert(peer_id.to_string(), value);
                }
                Err(error) => {
                    tracing::debug!(%peer_id, error = %error, "ignored invalid remote candidate cache snapshot");
                }
            },
        }
    }

    fn discovery_snapshot_candidates(snapshot: &DiscoverySnapshot) -> Vec<Candidate> {
        Self::snapshot_candidate_payloads(snapshot)
            .into_iter()
            .filter_map(|candidate| Self::candidate_from_v2(&candidate))
            .collect()
    }

    fn resolved_candidates(
        resolved: &ResolvedPeer,
        peer: &crate::runtime::PeerConfig,
    ) -> Vec<Candidate> {
        let mut candidates = Vec::new();
        if let Some(snapshot) = Self::resolved_snapshot(resolved) {
            candidates.extend(Self::discovery_snapshot_candidates(snapshot));
        }
        Self::append_configured_endpoint(&mut candidates, peer);
        candidates.sort_by(|left, right| {
            Self::candidate_order(left)
                .cmp(&Self::candidate_order(right))
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
    fn append_configured_endpoint(
        candidates: &mut Vec<Candidate>,
        peer: &crate::runtime::PeerConfig,
    ) {
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
}

/// Stage C is a closed gate: the resolver must have returned an authoritative
/// READY snapshot, the peer must advertise the frozen RelayData capability,
/// the requested business capability must be carried by the Relay profile,
/// the Relay path must use Required E2EE, and the overall connect budget must
/// still have time for reservation admission.
impl ConnectivityStageEligibility {
    /// Preserve the authoritative Resolve status after Stage A has already tried
    /// configured/fresh direct candidates. A configured endpoint cannot turn an
    /// OFFLINE/NOT_READY/UNKNOWN result into a synthetic READY peer.
    #[allow(dead_code)]
    fn authoritative_resolve_or_error(
        peer_id: &str,
        result: Result<ResolvedPeer, ProtocolError>,
    ) -> Result<ResolvedPeer, ProtocolError> {
        match result {
            Ok(ResolvedPeer::Ready {
                discovery: Some(discovery),
            }) => Ok(ResolvedPeer::Ready {
                discovery: Some(discovery),
            }),
            Ok(ResolvedPeer::Ready { discovery: None }) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay returned READY without an authoritative discovery snapshot",
                "connect",
                peer_id,
            )),
            Ok(ResolvedPeer::Offline) => Err(protocol_error_with_peer(
                NetworkErrorCode::PeerOffline,
                "Relay peer is offline",
                "connect",
                peer_id,
            )),
            Ok(ResolvedPeer::NotReady { retry_after_ms }) => Err(protocol_error_with_retry(
                NetworkErrorCode::PeerNotReady,
                "Relay peer discovery is not ready",
                "connect",
                Some(peer_id),
                network_protocol::RetryDisposition::RetryAfter,
                (retry_after_ms / 1000).max(1),
            )),
            Ok(ResolvedPeer::Unknown { .. }) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay peer resolution is unavailable",
                "connect",
                peer_id,
            )),
            Err(error) => Err(error),
        }
    }

    fn relay_fallback_is_eligible(
        resolved: &ResolvedPeer,
        requested_capability: u8,
        e2ee_policy: network_protocol::E2eePolicy,
        connect_deadline: Instant,
    ) -> bool {
        if Instant::now() >= connect_deadline
            || e2ee_policy != network_protocol::E2eePolicy::Required
        {
            return false;
        }
        let ResolvedPeer::Ready {
            discovery: Some(discovery),
        } = resolved
        else {
            return false;
        };
        if discovery.runtime_epoch.is_none() || discovery.revision == 0 {
            return false;
        }
        let relay_advertised = discovery
            .transport_capabilities
            .iter()
            .filter_map(|value| network_relay::v2::TransportCapability::try_from(*value).ok())
            .any(|capability| capability == network_relay::v2::TransportCapability::RelayData);
        let relay_supports_request = crate::connection::ConnectionProfile::for_route(
            RouteType::Relay,
        )
        .is_some_and(|profile| {
            profile_capability_mask(profile) & requested_capability == requested_capability
        });
        relay_advertised && relay_supports_request
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
#[path = "../tests/connectivity_attempt.rs"]
mod tests;
