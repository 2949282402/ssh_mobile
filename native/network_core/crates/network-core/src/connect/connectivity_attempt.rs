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
    RouteAttemptPhase, RouteType,
};
use network_relay::v2::{
    ConnectivityAttemptStart, DiscoverySnapshot, ResolvePeerResponse, RuntimeEpoch,
};
use network_relay::RelayError;
use quinn::VarInt;

use crate::discovery::resolver::{DiscoveryResolver, ResolvedPeer};
use crate::events::{
    emit_peer_state, emit_peer_state_profile, emit_route_attempt_changed, emit_route_changed,
    emit_route_changed_profile, protocol_error_with_peer, protocol_error_with_retry,
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
    pub(super) state: Arc<RuntimeState>,
    /// 当前状态机位置（诊断/测试）。
    pub(super) stage: std::sync::atomic::AtomicU8,
}

/// Owns the local Session reserved at the Offer boundary until the
/// coordinator has attached a route successfully.  A timeout or task abort
/// drops this guard and asynchronously retires the exact Session, preventing
/// a cancelled attempt from poisoning the next connect admission.
pub(super) struct SessionCleanupGuard {
    state: Arc<RuntimeState>,
    pub(super) peer_id: String,
    session_id: Option<SessionId>,
}

impl SessionCleanupGuard {
    pub(super) fn new(state: Arc<RuntimeState>, peer_id: &str, session_id: SessionId) -> Self {
        Self {
            state,
            peer_id: peer_id.to_string(),
            session_id: Some(session_id),
        }
    }

    pub(super) fn disarm(&mut self) {
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
pub(super) struct StageBTransactionRequest {
    pub(super) peer_id: String,
    pub(super) initiator_device_id: String,
    pub(super) initiator_runtime_epoch: RuntimeEpoch,
    pub(super) initiator_revision: u32,
    pub(super) initiator_snapshot: Option<DiscoverySnapshot>,
    pub(super) connect_deadline: Instant,
}

/// Inputs collected before the coordinated Stage B/C flow begins.
///
/// Keeping this value separate from the coordinator keeps the state-machine
/// entry point small while preserving the exact identity, epoch, and
/// authorization snapshot used by the admission decision.
pub(super) struct CoordinatedConnectContext<'a> {
    pub(super) peer_id: &'a str,
    pub(super) capability: u8,
    pub(super) command_id: Option<&'a str>,
    pub(super) connect_deadline: Instant,
    pub(super) state: Arc<RuntimeState>,
    pub(super) endpoint: quinn::Endpoint,
    pub(super) identity: Arc<network_identity::DeviceIdentity>,
    pub(super) peer: crate::runtime::PeerConfig,
    pub(super) authorization: Option<crate::runtime::PeerRouteAuthorization>,
    pub(super) control: Arc<dyn crate::discovery::DiscoveryControlPlane>,
    pub(super) ready_presence_ttl: Option<Duration>,
    pub(super) local_epoch: RuntimeEpoch,
    pub(super) local_revision: u32,
    pub(super) local_snapshot: Option<DiscoverySnapshot>,
}

mod candidate_snapshot_policy;
mod coordinated;
mod coordination;
mod entry;
mod relay_stage;
mod reuse;
mod route_attachment;
mod stage_a;
mod stage_b;
mod stage_eligibility;

use candidate_snapshot_policy::CandidateSnapshotPolicy;
use stage_eligibility::ConnectivityStageEligibility;

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
}

/// 生成一次独立的 attempt_id（§12：每次建连独立 attempt）。
pub(super) fn new_attempt_id() -> String {
    hex::encode(rand::random::<[u8; 16]>())
}

/// 把控制面错误映射为类型化错误（§33 ControlUnavailable/ResolveTimeout/ProtocolError）。
pub(super) fn relay_resolve_error(error: &RelayError, peer_id: &str) -> ProtocolError {
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
pub(crate) mod tests;
