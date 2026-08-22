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
        self.set_stage(ConnectivityAttemptState::Resolving);
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
        let (attempt_id, coordination) = self
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
            .await?;
        let resolved = ready_peer_from_coordination(&coordination.resolved, peer_id)?;
        self.set_stage(ConnectivityAttemptState::Resolved);
        update_remote_candidate_cache(
            &state,
            peer_id,
            resolved_snapshot(&resolved),
            ready_presence_ttl,
        )
        .await;

        let remote_epoch = resolved_runtime_epoch(&resolved);

        // -----------------------------------------------------------------
        // 2. Registry 重用（§34）。
        // -----------------------------------------------------------------
        if let Some(reused) = self.try_reuse(peer_id, &remote_epoch, capability).await? {
            self.finish_reuse(peer_id, reused).await;
            return Ok(());
        }

        // -----------------------------------------------------------------
        // 3. Session 门控：同 peer 并发 connect 合并（§40 Concurrency）。
        // -----------------------------------------------------------------
        let session_id = match state.begin_connect(peer_id, capability).await {
            ConnectDecision::AlreadyConnected(session_id) => {
                // 有健康连接但未登记（例如被动端 accept 建立的 Session）→ 登记并重用。
                self.register_current(state.clone(), peer_id, &remote_epoch, session_id)
                    .await;
                // 已连接会话满足一次新的 connect()：同样发布 Connected 终态，
                // 否则 Dart connect() 的成功信号会缺失。
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
            ConnectDecision::InProgress(session_id) => {
                // Do not merge this request into Session state. Wait for the
                // existing attempt, then evaluate this request against the
                // route it actually produced.
                loop {
                    if state.connection_sessions.current_session_id(peer_id).await
                        != Some(session_id)
                    {
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "shared connection attempt became stale",
                            "connect",
                            peer_id,
                        ));
                    }
                    if state.path_is_connected(peer_id).await {
                        let supported = state.path_supports_capability(peer_id, capability).await;
                        if !supported {
                            return Err(protocol_error_with_peer(
                                NetworkErrorCode::NoRoute,
                                "existing route does not satisfy this path capability",
                                "connect",
                                peer_id,
                            ));
                        }
                        break;
                    }
                    if !state
                        .path_admission_can_retry(peer_id, Some(session_id))
                        .await
                    {
                        return Err(protocol_error_with_peer(
                            NetworkErrorCode::NoRoute,
                            "shared connection attempt did not produce a route",
                            "connect",
                            peer_id,
                        ));
                    }
                    state.wait_for_path_change().await;
                }
                self.register_current(state.clone(), peer_id, &remote_epoch, session_id)
                    .await;
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
                return Ok(());
            }
            ConnectDecision::Started(session_id) => session_id,
        };

        // -----------------------------------------------------------------
        // 4. Create ConnectivityAttempt（§12）+ COORDINATING（§14）。
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
            nat_runtime_epoch(&local_epoch),
            attempt_started_at,
            DIRECT_CONNECT_WINDOW,
        )
        .with_local_candidates(collect_local_candidates(state.clone()).await);
        let initial_remote_candidates = resolved_candidates(&resolved, &peer);
        if let Err(error) = attempt.apply_remote_candidates(
            resolved_snapshot(&resolved)
                .and_then(|snapshot| snapshot.runtime_epoch.as_ref().map(nat_runtime_epoch)),
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
        let candidate_updates = self.spawn_coordination(
            coordination,
            peer_id.to_string(),
            attempt_id.clone(),
            Arc::clone(&attempt),
            preserved_direct_candidates,
            ready_presence_ttl,
        );
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
                let admission = self.attach_direct_route(peer_id, route).await?;
                let final_remote_epoch = attempt
                    .lock()
                    .await
                    .remote_runtime_epoch()
                    .map(runtime_epoch_from_nat)
                    .or_else(|| remote_epoch.clone());
                self.register_current(
                    Arc::clone(&state),
                    peer_id,
                    &final_remote_epoch,
                    admission.session_id,
                )
                .await;
                self.set_stage(ConnectivityAttemptState::ConnectedDirect);
                Ok(())
            }
            // Direct 失败：DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING（§15/§37）。
            Err(direct_error) => {
                let _ = attempt
                    .lock()
                    .await
                    .set_state(network_nat::ConnectivityAttemptState::Expired);
                self.set_stage(ConnectivityAttemptState::DirectFailed);
                if !relay_fallback_is_eligible(
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
                            .map(runtime_epoch_from_nat)
                            .or_else(|| remote_epoch.clone());
                        self.register_current(
                            Arc::clone(&state),
                            peer_id,
                            &final_remote_epoch,
                            admission.session_id,
                        )
                        .await;
                        self.set_stage(ConnectivityAttemptState::ConnectedRelay);
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
            stage_a_direct_candidates(caches.get(peer_id), peer, Instant::now())
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
                let admission = self.attach_direct_route(peer_id, route).await?;
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
        peer: &crate::runtime::PeerConfig,
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
        self.authoritative_resolve_or_error(peer_id, peer, result)
    }

    /// Preserve the authoritative Resolve status after Stage A has already
    /// tried configured/fresh direct candidates. In particular, a configured
    /// endpoint cannot turn OFFLINE/NOT_READY/UNKNOWN into a synthetic READY.
    #[allow(dead_code)] // compatibility seam for resolver-focused unit tests
    fn authoritative_resolve_or_error(
        &self,
        peer_id: &str,
        _peer: &crate::runtime::PeerConfig,
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
            .ready_session_index
            .take_obsolete(peer_id, remote_epoch)
        {
            tracing::info!(
                peer_id = %peer_id,
                session = ?obsolete.session_id,
                "remote runtime epoch changed; closing obsolete connection"
            );
            close_session_and_unregister(
                Arc::clone(&state),
                peer_id.to_string(),
                obsolete.session_id,
            )
            .await;
        }
        let Some(registered) = state
            .ready_session_index
            .lookup(peer_id, remote_epoch, capability)
        else {
            return Ok(None);
        };
        if state.path_is_connected(peer_id).await
            && state.connection_sessions.current_session_id(peer_id).await
                == Some(registered.session_id)
            && state.path_supports_capability(peer_id, capability).await
        {
            return Ok(Some(registered.session_id));
        }
        // 登记存在但连接已不健康：移除登记，走新建。
        state
            .ready_session_index
            .unregister_if_session(peer_id, registered.session_id);
        Ok(None)
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
                            entry.pending_remote_epoch().is_some()
                                || Some(runtime_epoch_from_nat(entry.runtime_epoch))
                                    != Some(registered_epoch.clone())
                        })
                    } else {
                        false
                    };
                if epoch_changed {
                    close_session_and_unregister(
                        Arc::clone(&state),
                        peer_id.to_string(),
                        session_id,
                    )
                    .await;
                    return Ok(None);
                }
            }
        }
        Ok(Some(session_id))
    }

    /// Publish the single success signal for either pre-control or
    /// post-Resolve registry reuse.
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
    ) -> watch::Receiver<Option<Vec<Candidate>>> {
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        let state = Arc::clone(&self.state);
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_runtime("connectivity-coordination", async move {
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
                            update_remote_candidate_cache(
                                &state,
                                &peer_id,
                                Some(snapshot),
                                ready_presence_ttl,
                            )
                            .await;
                            let mut candidates = discovery_snapshot_candidates(snapshot);
                            candidates.extend(preserved_direct_candidates.iter().cloned());
                            let result = {
                                let mut attempt = attempt.lock().await;
                                let result = attempt.apply_remote_candidates(
                                    snapshot.runtime_epoch.as_ref().map(nat_runtime_epoch),
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

/// 关闭一个已登记的连接（§34 Close old）。
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

/// Convert the control transaction's Resolve response into the coordinator's
/// typed resolver result. Keep the status mapping here so test control planes
/// and future implementations cannot turn a non-READY response into a
/// synthetic usable peer.
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

/// 从 Resolve 结果解码远端候选（opaque JSON → Candidate）。
fn resolved_snapshot(resolved: &ResolvedPeer) -> Option<&DiscoverySnapshot> {
    match resolved {
        ResolvedPeer::Ready { discovery } => discovery.as_ref(),
        ResolvedPeer::Offline | ResolvedPeer::NotReady { .. } | ResolvedPeer::Unknown { .. } => {
            None
        }
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
            network_relay::v2::TransportCapability::RelayData => Some(CandidateTransport::Relay),
            network_relay::v2::TransportCapability::Unspecified
            | network_relay::v2::TransportCapability::Webrtc => None,
        })
        .collect()
}

fn snapshot_candidate_payloads(snapshot: &DiscoverySnapshot) -> Vec<CandidatePayloadV2> {
    let advertised_transports = snapshot_candidate_transports(snapshot);
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
                .filter_map(candidate_from_v2)
                .collect::<Vec<_>>();
            let remote_epoch = fresh.map(|_| RuntimeEpoch {
                high: cache.runtime_epoch.high,
                low: cache.runtime_epoch.low,
            });
            (candidates, remote_epoch)
        }
        None => (Vec::new(), None),
    };
    append_configured_endpoint(&mut candidates, peer);
    candidates.retain(|candidate| candidate.kind != CandidateKind::Relay);
    candidates.sort_by(|left, right| {
        candidate_order(left)
            .cmp(&candidate_order(right))
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
        runtime_epoch: nat_runtime_epoch(runtime_epoch),
        revision: u64::from(snapshot.revision),
        candidates: snapshot_candidate_payloads(snapshot),
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
    snapshot_candidate_payloads(snapshot)
        .into_iter()
        .filter_map(|candidate| candidate_from_v2(&candidate))
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

/// Stage C is a closed gate: the resolver must have returned an authoritative
/// READY snapshot, the peer must advertise the frozen RelayData capability,
/// the requested business capability must be carried by the Relay profile,
/// the Relay path must use Required E2EE, and the overall connect budget must
/// still have time for reservation admission.
fn relay_fallback_is_eligible(
    resolved: &ResolvedPeer,
    requested_capability: u8,
    e2ee_policy: network_protocol::E2eePolicy,
    connect_deadline: Instant,
) -> bool {
    if Instant::now() >= connect_deadline || e2ee_policy != network_protocol::E2eePolicy::Required {
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
    let relay_supports_request = crate::connection::ConnectionProfile::for_route(RouteType::Relay)
        .is_some_and(|profile| {
            profile_capability_mask(profile) & requested_capability == requested_capability
        });
    relay_advertised && relay_supports_request
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
    use crate::connect::{PeerId, PeerPathManager, DEFAULT_CONNECTION_CAPABILITY};
    use crate::connection::{ConnectionProfile, Route, RouteTransport};
    use network_nat::PathManager;
    use network_relay::v2::ResolveStatus;
    use std::time::Duration;

    /// 构造一个可跑通 `connect_with_class` 前段（配置校验 + Resolve + try_reuse）
    /// 的 RuntimeState：配置了 endpoint/identity/peer，并注入权威 READY mock。
    async fn configured_reuse_state() -> (
        Arc<RuntimeState>,
        tokio::sync::mpsc::UnboundedReceiver<network_protocol::NetworkEvent>,
        Arc<StubControl>,
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
        *state.lifecycle.endpoint.write().await = Some(manager.endpoint);
        *state.lifecycle.identity.write().await = Some(Arc::new(
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
                e2ee_policy: network_protocol::E2eePolicy::Required,
            },
        );
        let control = StubControl::new(
            ResolveStatus::Ready,
            Some(DiscoverySnapshot {
                runtime_epoch: None,
                revision: 1,
                transport_capabilities: Vec::new(),
                candidate_bundle: None,
                published_at_ms: 0,
            }),
        );
        *state.relay.control.write().await = Some(control.clone());
        (state, event_rx, control)
    }

    async fn install_ready_direct_path(
        state: &RuntimeState,
        peer_id: &str,
        transport: RouteTransport,
    ) {
        let mut manager = PeerPathManager::new(
            PeerId::new(peer_id).expect("peer id"),
            Arc::clone(&state.ready_paths),
        );
        manager
            .publish_ready(ConnectionProfile::new(Route::direct(transport)))
            .expect("publish ready direct path");
        state.peer_path_managers.write().await.insert(
            peer_id.to_string(),
            Arc::new(std::sync::Mutex::new(manager)),
        );
    }

    #[test]
    fn stage_machine_follows_the_design_skeleton() {
        // 状态机只允许设计定义的阶段；不允许 RECONNECTING / DIRECT_UPGRADING /
        // PATH_REPAIRING（§11）。
        let stages = [
            ConnectivityAttemptState::Idle,
            ConnectivityAttemptState::Resolving,
            ConnectivityAttemptState::Resolved,
            ConnectivityAttemptState::Coordinating,
            ConnectivityAttemptState::DirectConnecting,
            ConnectivityAttemptState::ConnectedDirect,
            ConnectivityAttemptState::DirectFailed,
            ConnectivityAttemptState::RelayReserving,
            ConnectivityAttemptState::RelayConnecting,
            ConnectivityAttemptState::ConnectedRelay,
            ConnectivityAttemptState::Failed,
        ];
        for stage in stages {
            // 编译期保证不存在缺失的变体。
            match stage {
                ConnectivityAttemptState::Idle
                | ConnectivityAttemptState::Resolving
                | ConnectivityAttemptState::Resolved
                | ConnectivityAttemptState::Coordinating
                | ConnectivityAttemptState::DirectConnecting
                | ConnectivityAttemptState::ConnectedDirect
                | ConnectivityAttemptState::DirectFailed
                | ConnectivityAttemptState::RelayReserving
                | ConnectivityAttemptState::RelayConnecting
                | ConnectivityAttemptState::ConnectedRelay
                | ConnectivityAttemptState::Failed => {}
            }
        }
    }

    #[test]
    fn direct_window_constant_is_four_seconds() {
        assert_eq!(DIRECT_CONNECT_WINDOW, Duration::from_millis(4000));
    }

    #[tokio::test]
    async fn stage_a_reuses_only_a_compatible_ready_direct_path() {
        let (state, _event_rx, _ready_control) = configured_reuse_state().await;
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay.control.write().await = Some(control.clone());
        install_ready_direct_path(&state, "peer-b", RouteTransport::Tcp).await;

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::UnreliableDatagram)
            .await;

        assert!(
            matches!(result, Err(ref error) if error.code == NetworkErrorCode::PeerOffline as i32),
            "an incompatible ready Direct path must not satisfy the request: {result:?}"
        );
        assert_eq!(control.resolve_calls(), 1);
        assert_eq!(control.connectivity_calls(), 0);
        assert_eq!(control.reserve_calls(), 0);
    }

    #[tokio::test]
    async fn stage_a_compatible_ready_direct_path_makes_no_control_plane_calls() {
        let (state, _event_rx, control) = configured_reuse_state().await;
        install_ready_direct_path(&state, "peer-b", RouteTransport::Tcp).await;

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::ReliableStream)
            .await;

        assert!(
            result.is_ok(),
            "compatible Stage A reuse should succeed: {result:?}"
        );
        assert_eq!(control.resolve_calls(), 0);
        assert_eq!(control.connectivity_calls(), 0);
        assert_eq!(control.reserve_calls(), 0);
    }

    #[tokio::test]
    async fn stage_b_resolves_and_offers_before_relay_reservation() {
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        let stage_b_candidate = Candidate::new(
            "127.0.0.1:9".parse().expect("candidate endpoint"),
            CandidateKind::Lan,
            "stage-b-candidate".into(),
        )
        .with_generation(1);
        let stale_cache = ResolvedCandidateCache::from_snapshot(
            ResolvedCandidateSnapshot {
                runtime_epoch: NatRuntimeEpoch { high: 1, low: 1 },
                revision: 1,
                candidates: vec![CandidatePayloadV2::from_candidate(
                    &stage_b_candidate,
                    vec![CandidateTransport::Quic],
                )],
                server_presence_ttl: Some(Duration::from_secs(1)),
            },
            Instant::now() - Duration::from_secs(10),
        )
        .expect("valid stale Stage A cache");
        state
            .remote_candidate_cache
            .write()
            .await
            .insert("peer-b".into(), stale_cache);
        let control = StubControl::new(
            ResolveStatus::Ready,
            Some(DiscoverySnapshot {
                runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
                revision: 1,
                transport_capabilities: vec![
                    network_relay::v2::TransportCapability::Quic as i32,
                    network_relay::v2::TransportCapability::RelayData as i32,
                ],
                candidate_bundle: Some(network_relay::v2::CandidateBundle {
                    candidates: vec![serde_json::to_vec(&stage_b_candidate.advertisement())
                        .expect("candidate advertisement")],
                }),
                published_at_ms: 0,
            }),
        );
        *state.relay.control.write().await = Some(control.clone());

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await;
        assert!(result.is_err(), "test control has no usable transport");
        assert_eq!(
            control.call_order(),
            vec!["resolve", "offer", "reserve"],
            "Stage B must complete Resolve → Offer/Answer coordination before Stage C reserve"
        );
        assert_eq!(
            control.resolve_calls(),
            1,
            "Stage B must issue exactly one authoritative Resolve"
        );
        assert_eq!(
            control.connectivity_calls(),
            1,
            "Stage B must enqueue exactly one ConnectivityOffer"
        );
        let cache = state
            .remote_candidate_cache
            .read()
            .await
            .get("peer-b")
            .cloned()
            .expect("Stage B must refresh the remote candidate cache");
        assert_eq!(cache.runtime_epoch, NatRuntimeEpoch { high: 3, low: 4 });
        assert_eq!(cache.revision, 1);
        assert!(
            cache.stage_a_candidates_at(Instant::now()).is_some(),
            "refreshed cache is not fresh: candidates={}, ttl={:?}, age={:?}",
            cache.candidates.len(),
            cache.ttl(),
            cache.age_at(Instant::now())
        );
    }

    #[test]
    fn direct_candidates_are_ranked_before_the_staggered_race() {
        let mut candidates = [
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

    #[test]
    fn stage_a_uses_fresh_cache_and_configured_direct_candidates_only() {
        let learned_at = Instant::now();
        let cache = ResolvedCandidateCache::from_snapshot(
            ResolvedCandidateSnapshot {
                runtime_epoch: NatRuntimeEpoch { high: 11, low: 12 },
                revision: 4,
                candidates: vec![
                    CandidatePayloadV2 {
                        version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                        candidate_id: "lan-remote".into(),
                        endpoint: "192.168.1.10:41001".parse().unwrap(),
                        kind: CandidateKind::Lan,
                        transport_capabilities: vec![CandidateTransport::Quic],
                        priority: 100,
                        interface: "wifi".into(),
                        generation: 1,
                    },
                    CandidatePayloadV2 {
                        version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                        candidate_id: "srflx-remote".into(),
                        endpoint: "198.51.100.10:41002".parse().unwrap(),
                        kind: CandidateKind::ServerReflexive,
                        transport_capabilities: network_nat::STUN_SRFLX_TRANSPORTS.to_vec(),
                        priority: 40,
                        interface: "stun".into(),
                        generation: 7,
                    },
                ],
                server_presence_ttl: Some(Duration::from_secs(5)),
            },
            learned_at,
        )
        .expect("valid Stage A cache");
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("192.168.1.20:41003".parse().unwrap()),
            identity_public_key: [0u8; 32],
            e2e_public_key: [1u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        };

        let (fresh, remote_epoch) =
            stage_a_direct_candidates(Some(&cache), &peer, learned_at + Duration::from_secs(4));
        assert_eq!(remote_epoch, Some(RuntimeEpoch { high: 11, low: 12 }));
        assert_eq!(
            fresh
                .iter()
                .map(|candidate| candidate.interface_name.as_str())
                .collect::<Vec<_>>(),
            vec!["wifi", "stun", "peer-configured"]
        );
        assert_eq!(fresh[1].generation, 7);
        assert!(fresh
            .iter()
            .all(|candidate| candidate.kind != CandidateKind::Relay));

        let (stale, stale_epoch) = stage_a_direct_candidates(
            Some(&cache),
            &peer,
            learned_at + Duration::from_secs(5) + Duration::from_nanos(1),
        );
        assert_eq!(stale_epoch, None);
        assert_eq!(stale.len(), 1);
        assert_eq!(stale[0].interface_name, "peer-configured");
    }

    #[test]
    fn snapshot_candidate_capabilities_keep_srflx_udp_only_and_drop_relay_from_direct() {
        let lan = Candidate::new(
            "192.168.1.30:41004".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        )
        .with_generation(1);
        let srflx = Candidate::new(
            "198.51.100.30:41005".parse().unwrap(),
            CandidateKind::ServerReflexive,
            "stun".into(),
        )
        .with_generation(1);
        let snapshot = DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 13, low: 14 }),
            revision: 2,
            transport_capabilities: vec![
                network_relay::v2::TransportCapability::Quic as i32,
                network_relay::v2::TransportCapability::Tcp as i32,
                network_relay::v2::TransportCapability::Websocket as i32,
                network_relay::v2::TransportCapability::UdpDatagram as i32,
                network_relay::v2::TransportCapability::RelayData as i32,
            ],
            candidate_bundle: Some(network_relay::v2::CandidateBundle {
                candidates: vec![
                    serde_json::to_vec(&lan.advertisement()).unwrap(),
                    serde_json::to_vec(&srflx.advertisement()).unwrap(),
                ],
            }),
            published_at_ms: 0,
        };

        let payloads = snapshot_candidate_payloads(&snapshot);
        let lan_payload = payloads
            .iter()
            .find(|candidate| candidate.kind == CandidateKind::Lan)
            .expect("LAN payload");
        assert!(!lan_payload
            .transport_capabilities
            .contains(&CandidateTransport::Relay));
        let srflx_payload = payloads
            .iter()
            .find(|candidate| candidate.kind == CandidateKind::ServerReflexive)
            .expect("STUN payload");
        assert_eq!(
            srflx_payload.transport_capabilities,
            network_nat::STUN_SRFLX_TRANSPORTS.to_vec()
        );
    }

    #[test]
    fn relay_fallback_gate_requires_ready_relay_policy_and_budget() {
        let ready = ResolvedPeer::Ready {
            discovery: Some(DiscoverySnapshot {
                runtime_epoch: Some(RuntimeEpoch { high: 15, low: 16 }),
                revision: 3,
                transport_capabilities: vec![
                    network_relay::v2::TransportCapability::RelayData as i32,
                ],
                candidate_bundle: None,
                published_at_ms: 0,
            }),
        };
        let deadline = Instant::now() + Duration::from_secs(1);
        assert!(relay_fallback_is_eligible(
            &ready,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            network_protocol::E2eePolicy::Required,
            deadline,
        ));
        assert!(!relay_fallback_is_eligible(
            &ready,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            network_protocol::E2eePolicy::Disabled,
            deadline,
        ));
        assert!(!relay_fallback_is_eligible(
            &ready,
            crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM,
            network_protocol::E2eePolicy::Required,
            deadline,
        ));
        let no_relay_capability = ResolvedPeer::Ready {
            discovery: Some(DiscoverySnapshot {
                runtime_epoch: Some(RuntimeEpoch { high: 17, low: 18 }),
                revision: 4,
                transport_capabilities: Vec::new(),
                candidate_bundle: None,
                published_at_ms: 0,
            }),
        };
        assert!(!relay_fallback_is_eligible(
            &no_relay_capability,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            network_protocol::E2eePolicy::Required,
            deadline,
        ));
        assert!(!relay_fallback_is_eligible(
            &ResolvedPeer::NotReady { retry_after_ms: 0 },
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            network_protocol::E2eePolicy::Required,
            deadline,
        ));
        assert!(!relay_fallback_is_eligible(
            &ready,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            network_protocol::E2eePolicy::Required,
            Instant::now() - Duration::from_secs(1),
        ));
    }

    #[tokio::test]
    async fn connectivity_answer_merges_candidates_into_the_live_attempt() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.lifecycle.identity.write().await = Some(Arc::new(
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
        let answer = network_relay::v2::ConnectivityAnswer {
            request_id: 1,
            attempt_id: "attempt-answer".into(),
            accepted: true,
            responder_device_id: "peer-b".into(),
            responder_runtime_epoch: snapshot.runtime_epoch.clone(),
            responder_revision: snapshot.revision,
            responder_snapshot: Some(snapshot.clone()),
        };
        let coordination = ConnectivityAttemptStart::new(
            ResolvePeerResponse {
                request_id: 1,
                status: network_relay::v2::ResolveStatus::Ready as i32,
                discovery: Some(snapshot),
                retry_after_ms: 0,
            },
            async move { Ok(answer) },
        );
        let attempt = Arc::new(Mutex::new(ConnectivityAttempt::with_connect_window(
            "attempt-answer",
            "peer-b",
            nat_runtime_epoch(&RuntimeEpoch { high: 1, low: 2 }),
            SystemTime::now(),
            DIRECT_CONNECT_WINDOW,
        )));
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let mut updates = attempt_coordinator.spawn_coordination(
            coordination,
            "peer-b".into(),
            "attempt-answer".into(),
            Arc::clone(&attempt),
            Vec::new(),
            Some(Duration::from_secs(60)),
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
            attempt.remote_runtime_epoch(),
            Some(nat_runtime_epoch(&RuntimeEpoch { high: 3, low: 4 })),
        );
        assert_eq!(
            attempt.state(),
            network_nat::ConnectivityAttemptState::Connecting
        );
    }

    #[tokio::test]
    async fn new_attempt_coordinator_starts_in_idle() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        assert_eq!(attempt_coordinator.stage(), ConnectivityAttemptState::Idle);
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
        // Legacy resolver seam: an authoritative OFFLINE result with no local
        // configured endpoint fails closed and never fabricates a Direct path.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay.control.write().await = Some(control);
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let result = attempt_coordinator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::PeerOffline as i32
        ));
    }

    #[tokio::test]
    async fn resolve_without_control_plane_fails_closed() {
        // Stage A owns local LAN/configured direct probing. Once it fails, the
        // authoritative Stage B Resolve cannot be replaced by local candidate
        // availability or a synthetic READY.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let result = attempt_coordinator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::RelayError as i32
        ));
    }

    #[tokio::test]
    async fn resolve_not_ready_retries_once_then_maps_to_peer_not_ready() {
        // §10：NOT_READY gets one bounded retry; a second NOT_READY remains
        // authoritative and maps to PeerNotReady, never READY or Timeout.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay.control.write().await = Some(control.clone());
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let result = attempt_coordinator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert_eq!(control.resolve_calls(), 2);
        assert!(matches!(
            result,
            Err(error)
                if error.code == NetworkErrorCode::PeerNotReady as i32
                    && error.retry_disposition
                        == network_protocol::RetryDisposition::RetryAfter as i32
        ));
    }

    #[tokio::test]
    async fn active_connect_not_ready_retries_once_then_maps_to_peer_not_ready() {
        // The production connect path must apply the same bounded retry as the
        // legacy resolver seam, while never enqueueing an Offer for either
        // non-READY transaction.
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay.control.write().await = Some(control.clone());

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await;

        assert!(matches!(
            result,
            Err(error)
                if error.code == NetworkErrorCode::PeerNotReady as i32
                    && error.retry_disposition
                        == network_protocol::RetryDisposition::RetryAfter as i32
        ));
        assert_eq!(control.resolve_calls(), 2);
        assert_eq!(
            control.connectivity_calls(),
            0,
            "NOT_READY transactions must not enqueue ConnectivityOffer"
        );
    }

    #[tokio::test]
    async fn resolve_unknown_fails_closed_without_retry() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Unknown, None);
        *state.relay.control.write().await = Some(control.clone());
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let result = attempt_coordinator
            .resolve("peer-b", &peer_without_endpoint())
            .await;
        assert_eq!(control.resolve_calls(), 1);
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::RelayError as i32
        ));
    }

    #[tokio::test]
    async fn offline_resolve_with_configured_endpoint_remains_authoritative() {
        // Stage A already owns configured-endpoint direct probing. Once it
        // fails, OFFLINE must not be converted into a synthetic READY.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::Offline, None);
        *state.relay.control.write().await = Some(control);
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        };
        let result = attempt_coordinator.resolve("peer-b", &peer).await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::PeerOffline as i32
        ));
    }

    #[tokio::test]
    async fn not_ready_resolve_with_configured_endpoint_remains_authoritative() {
        // A configured endpoint cannot make NOT_READY eligible for Relay
        // fallback or fabricate an authoritative discovery snapshot.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let control = StubControl::new(ResolveStatus::NotReady, None);
        *state.relay.control.write().await = Some(control);
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        };
        let result = attempt_coordinator.resolve("peer-b", &peer).await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::PeerNotReady as i32
        ));
    }

    #[tokio::test]
    async fn resolve_transport_error_with_configured_endpoint_does_not_fail_open() {
        // A transport error is not permission to fabricate a peer discovery
        // result from a configured endpoint.
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay.control.write().await = Some(StubControl::error());
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        };
        let result = attempt_coordinator.resolve("peer-b", &peer).await;
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::RelayError as i32
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn resolve_timeout_with_configured_endpoint_does_not_fail_open() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay.control.write().await = Some(StubControl::timeout());
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let peer = crate::runtime::PeerConfig {
            endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
            identity_public_key: [7u8; 32],
            e2e_public_key: [8u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        };
        let task = tokio::spawn(async move { attempt_coordinator.resolve("peer-b", &peer).await });
        tokio::task::yield_now().await;
        tokio::time::advance(RESOLVE_TIMEOUT + Duration::from_millis(1)).await;
        let result = task.await.expect("resolve task");
        assert!(matches!(
            result,
            Err(error) if error.code == NetworkErrorCode::Timeout as i32
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn resolve_timeout_without_endpoint_remains_a_timeout_error() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.relay.control.write().await = Some(StubControl::timeout());
        let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
        let peer = peer_without_endpoint();
        let task = tokio::spawn(async move { attempt_coordinator.resolve("peer-b", &peer).await });
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
        let (state, mut event_rx, control) = configured_reuse_state().await;
        let peer_id = "peer-b";

        // 预置一条健康连接：ReliableMessage 会话 + 已登记（模拟先前 connect 建立）。
        let session_id = match state
            .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
            .await
        {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        assert!(
            state
                .mark_relay_route_connected(peer_id, session_id, None)
                .await
        );
        state.ready_session_index.register(
            peer_id,
            None,
            DEFAULT_CONNECTION_CAPABILITY,
            session_id,
        );

        let attempt_coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
        let result = attempt_coordinator
            .connect_with_class(peer_id, CommunicationClass::ReliableStream)
            .await;
        assert!(result.is_ok(), "reuse path should succeed: {result:?}");
        assert_eq!(
            control.resolve_calls(),
            0,
            "healthy Relay reuse must not open a new Resolve transaction"
        );
        assert_eq!(
            control.connectivity_calls(),
            0,
            "healthy Relay reuse must not emit an unsolicited ConnectivityOffer"
        );
        assert_eq!(control.reserve_calls(), 0);

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
                assert_eq!(peer_state.route_type, RouteType::Relay as i32);
            }
            other => panic!("unexpected event payload: {other:?}"),
        }
    }

    #[tokio::test]
    async fn healthy_reuse_retires_path_after_remote_epoch_hint() {
        let (state, _event_rx, _control) = configured_reuse_state().await;
        let peer_id = "peer-b";
        let session_id = match state
            .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
            .await
        {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        assert!(
            state
                .mark_relay_route_connected(peer_id, session_id, None)
                .await
        );
        let remote_epoch = RuntimeEpoch { high: 3, low: 4 };
        state.ready_session_index.register(
            peer_id,
            Some(remote_epoch.clone()),
            DEFAULT_CONNECTION_CAPABILITY,
            session_id,
        );
        let candidate = Candidate::new(
            "127.0.0.1:41020".parse().expect("candidate endpoint"),
            CandidateKind::Lan,
            "epoch-fence".into(),
        )
        .with_generation(1);
        let cache = ResolvedCandidateCache::from_snapshot(
            ResolvedCandidateSnapshot {
                runtime_epoch: nat_runtime_epoch(&remote_epoch),
                revision: 1,
                candidates: vec![CandidatePayloadV2::from_candidate(
                    &candidate,
                    vec![CandidateTransport::Quic],
                )],
                server_presence_ttl: Some(Duration::from_secs(60)),
            },
            Instant::now(),
        )
        .expect("cache");
        state
            .remote_candidate_cache
            .write()
            .await
            .insert(peer_id.into(), cache);
        state
            .remote_candidate_cache
            .write()
            .await
            .get_mut(peer_id)
            .expect("cache entry")
            .invalidate_for_remote_epoch(NatRuntimeEpoch { high: 5, low: 6 }, Instant::now());

        let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
        assert_eq!(
            coordinator
                .try_reuse_before_control(peer_id, DEFAULT_CONNECTION_CAPABILITY)
                .await
                .expect("reuse check"),
            None,
            "an epoch hint must fence pre-control reuse"
        );
        assert!(!state.path_is_connected(peer_id).await);
        assert_eq!(
            state.connection_sessions.current_session_id(peer_id).await,
            None
        );
    }

    /// 构造一个没有配置直连 endpoint 的 PeerConfig（测试 resolve 权威失败路径用）。
    fn peer_without_endpoint() -> crate::runtime::PeerConfig {
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [0u8; 32],
            e2e_public_key: [0u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        }
    }

    /// 预置 Resolve 状态的 mock 控制面（测试用）。
    struct StubControl {
        status: network_relay::v2::ResolveStatus,
        discovery: Option<DiscoverySnapshot>,
        resolve_calls: std::sync::atomic::AtomicUsize,
        connectivity_calls: std::sync::atomic::AtomicUsize,
        reserve_calls: std::sync::atomic::AtomicUsize,
        resolve_error: bool,
        resolve_never: bool,
        connectivity_answer: Option<network_relay::v2::ConnectivityAnswer>,
        calls: std::sync::Mutex<Vec<&'static str>>,
    }

    impl StubControl {
        fn new(
            status: network_relay::v2::ResolveStatus,
            discovery: Option<DiscoverySnapshot>,
        ) -> Arc<Self> {
            Arc::new(Self {
                status,
                discovery,
                resolve_calls: std::sync::atomic::AtomicUsize::new(0),
                connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
                reserve_calls: std::sync::atomic::AtomicUsize::new(0),
                resolve_error: false,
                resolve_never: false,
                connectivity_answer: None,
                calls: std::sync::Mutex::new(Vec::new()),
            })
        }

        fn error() -> Arc<Self> {
            Arc::new(Self {
                status: ResolveStatus::Unknown,
                discovery: None,
                resolve_calls: std::sync::atomic::AtomicUsize::new(0),
                connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
                reserve_calls: std::sync::atomic::AtomicUsize::new(0),
                resolve_error: true,
                resolve_never: false,
                connectivity_answer: None,
                calls: std::sync::Mutex::new(Vec::new()),
            })
        }

        fn timeout() -> Arc<Self> {
            Arc::new(Self {
                status: ResolveStatus::Unknown,
                discovery: None,
                resolve_calls: std::sync::atomic::AtomicUsize::new(0),
                connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
                reserve_calls: std::sync::atomic::AtomicUsize::new(0),
                resolve_error: false,
                resolve_never: true,
                connectivity_answer: None,
                calls: std::sync::Mutex::new(Vec::new()),
            })
        }

        fn resolve_calls(&self) -> usize {
            self.resolve_calls.load(std::sync::atomic::Ordering::SeqCst)
        }

        fn connectivity_calls(&self) -> usize {
            self.connectivity_calls
                .load(std::sync::atomic::Ordering::SeqCst)
        }

        fn reserve_calls(&self) -> usize {
            self.reserve_calls.load(std::sync::atomic::Ordering::SeqCst)
        }

        fn call_order(&self) -> Vec<&'static str> {
            self.calls.lock().expect("stub call log lock").clone()
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
            self.calls
                .lock()
                .expect("stub call log lock")
                .push("resolve");
            self.resolve_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
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

        fn begin_connectivity_attempt(
            &self,
            _attempt_id: String,
            target_device_id: String,
            _initiator_device_id: String,
            _initiator_runtime_epoch: RuntimeEpoch,
            _initiator_revision: u32,
            _initiator_snapshot: Option<DiscoverySnapshot>,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<network_relay::v2::ConnectivityAttemptStart, RelayError>,
                    > + Send
                    + '_,
            >,
        > {
            let answer = self.connectivity_answer.clone();
            Box::pin(async move {
                let resolved = self.resolve_peer(&target_device_id).await?;
                let status = resolved.status;
                let retry_after_ms = resolved.retry_after_ms;
                if resolved.status != ResolveStatus::Ready as i32 {
                    return Ok(network_relay::v2::ConnectivityAttemptStart::new(
                        resolved,
                        async move {
                            Err(RelayError::Protocol(format!(
                                "connectivity attempt not started: resolve status={status} retry_after_ms={retry_after_ms}"
                            )))
                        },
                    ));
                }
                self.calls.lock().expect("stub call log lock").push("offer");
                self.connectivity_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(network_relay::v2::ConnectivityAttemptStart::new(
                    resolved,
                    async move { answer.ok_or(RelayError::NotConnected) },
                ))
            })
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
            self.calls.lock().expect("stub call log lock").push("offer");
            self.connectivity_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let answer = self.connectivity_answer.clone();
            Box::pin(async move { answer.ok_or(RelayError::NotConnected) })
        }

        fn reserve_relay(
            &self,
            _attempt_id: String,
            _target_device_id: String,
            _desired_lifetime_s: u32,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<network_relay::v2::RelayReserveResponse, RelayError>,
                    > + Send
                    + '_,
            >,
        > {
            self.calls
                .lock()
                .expect("stub call log lock")
                .push("reserve");
            self.reserve_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async { Err(RelayError::NotConnected) })
        }
    }
}
