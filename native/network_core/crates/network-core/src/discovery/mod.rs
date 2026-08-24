//! transport-network v2：本地 Discovery 生命周期（设计 §7/§8/§9/§10/§28/§29）。
//!
//! 本模块是 v2 Discovery 的 forward path：
//!
//! - [`local_discovery::LocalDiscoveryManager`]：本地 Discovery 身份 owner
//!   （runtime_epoch + revision + LocalDiscoveryState + 候选/能力快照）。
//! - [`publisher::DiscoveryPublisher`]：可靠发布（DiscoveryPublish → ACK → retry →
//!   DEGRADED），退避 500ms/1s/2s/4s/4s，最多 5 次。
//! - [`resolver::DiscoveryResolver`]：Resolve 4-state（READY/OFFLINE/NOT_READY/UNKNOWN）
//!   的类型化映射。
//! - [`snapshot`]：从本地传输 registry / 候选源构造 `DiscoverySnapshot`。
//!
//! transport-network v2 之后：v1 的 `upload_discovery` 命令、`peer_presence`
//! 处理、`lookup` 路径已在 Step 11 删除；本模块是 Discovery 生命周期唯一实现。
//! `state.relay.control`（v2 控制面 sink）承载 DiscoveryPublish/DiscoveryAck；
//! 控制面未接线时 hooks 是安全的 no-op。

mod local_discovery;
mod publisher;
mod recovery;
pub(crate) mod resolver;
mod snapshot;

use std::sync::Arc;
use std::time::Duration;

use crate::runtime::RuntimeState;

pub(crate) use local_discovery::LocalDiscoveryManager;
pub(crate) use publisher::{DiscoveryControlPlane, DiscoveryPublisher};
#[allow(unused_imports)]
pub(crate) use recovery::{DirectRecoveryPolicy, DIRECT_RECOVERY_BASE_BACKOFF};
use snapshot::{candidate_bundle_from_local, local_transport_capabilities};

// 以下仅在测试中使用；非测试构建不引用它们（Step 6 接线 resolver 后再收紧）。
#[cfg(test)]
pub(crate) use local_discovery::LocalDiscoveryState;

// ---------------------------------------------------------------------------
// 集中常量（设计 §39：TTL / timeout / retry 必须集中定义，禁止散落 magic number）
// ---------------------------------------------------------------------------

/// DiscoveryPublish 的总尝试次数上限（设计 §9：最多重试 5 次后 DEGRADED）。
pub(crate) const DISCOVERY_PUBLISH_MAX_ATTEMPTS: usize = 5;

/// DiscoveryPublish 的退避调度：500ms / 1s / 2s / 4s / 4s（§9）。
pub(crate) const DISCOVERY_PUBLISH_RETRY_BACKOFF_MS: [u64; 5] = [500, 1000, 2000, 4000, 4000];

/// 单次 DiscoveryPublish 的应答等待上限。`RelayControlClient` 内部已有 8s 请求
/// 超时，这里是发布者层的双保险（timeout → 视为 ACK 丢失 → 重试）。
pub(crate) const DISCOVERY_PUBLISH_TIMEOUT: Duration = Duration::from_secs(8);

/// The result of a local network-environment transition.  It is an
/// invalidation/republication fact, not a disconnect instruction: callers
/// must preserve healthy Relay/Realtime resources and let the peer owner
/// decide which Direct probe to restart.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct EnvironmentChangeResult {
    pub(crate) generation: u64,
    pub(crate) has_connectivity: bool,
    pub(crate) runtime_epoch: network_relay::v2::RuntimeEpoch,
    pub(crate) revision: u32,
}

// ---------------------------------------------------------------------------
// 运行时接线 hooks（peer.rs / relay.rs 调用）
// ---------------------------------------------------------------------------

/// 运行时配置完成后初始化本地 Discovery 生命周期：新 `runtime_epoch` + `revision = 1`，
/// 并从本地 PathManager 刷新候选/能力。应在 `peer::configure_runtime` 成功时调用一次
/// （Native Runtime 每次启动）。
pub(crate) async fn begin_epoch(state: &Arc<RuntimeState>) {
    let manager = LocalDiscoveryManager::begin_epoch();
    refresh_local_discovery(state, &manager).await;
    *state.local_discovery.write().await = Some(Arc::new(manager));
}

/// 控制连接建立**或重连**（control_connection_id C1→C2，§8）后重新发布完整 Snapshot：
/// epoch 与 revision **不变**（owner 在服务端随 control_connection_id 改变）。
///
/// 当前 `state.relay.control`（v2 控制面 sink）尚未接线（Step 6/7），sink 不存在时是
/// 安全的 no-op。
pub(crate) async fn on_control_connected(state: &Arc<RuntimeState>) {
    let Some(manager) = state.local_discovery.read().await.clone() else {
        return;
    };
    trigger_publish(state, manager, "control-connected").await;
}

/// 本地候选/网络变化（interface/IP/NAT/STUN/rebind，§9）：重新 gather 后
/// `revision++` → 重新发布 → ACK。Step 6 前的网络变化检测尚未接线；本函数由未来的
/// candidate-gather 事件驱动，当前在模块测试中验证。
#[allow(dead_code)] // forward path：Step 6 接入网络变化检测后启用
pub(crate) async fn on_local_candidates_changed(state: &Arc<RuntimeState>) {
    let Some(manager) = state.local_discovery.read().await.clone() else {
        return;
    };
    manager.bump_revision();
    refresh_local_discovery(state, &manager).await;
    trigger_publish(state, manager, "candidates-changed").await;
}

/// Apply a network-environment lifecycle trigger without disconnecting any
/// peer, path, Relay control/data route, or Realtime session.  The returned
/// epoch/revision is the coordinator's stale-Direct invalidation token.
///
/// The peer owner should reset its Direct recovery policy using the same
/// trigger, preserve `maintain_connection`, and schedule any reprobe only
/// through its normal bounded connect intent.  This function deliberately has
/// no access to those mutable owners.
pub(crate) async fn on_network_environment_changed(
    state: &Arc<RuntimeState>,
    generation: u64,
    has_connectivity: bool,
) -> Option<EnvironmentChangeResult> {
    let manager = state.local_discovery.read().await.clone()?;
    manager.bump_revision();
    refresh_local_discovery(state, &manager).await;
    let snapshot = manager.snapshot();
    let result = EnvironmentChangeResult {
        generation,
        has_connectivity,
        runtime_epoch: snapshot.runtime_epoch.clone()?,
        revision: snapshot.revision,
    };
    trigger_publish(state, manager, "network-environment-changed").await;
    Some(result)
}

/// 在受监督的后台任务里执行 [`on_control_connected`]（供 relay connect/reconnect
/// 调用，避免发布重试阻塞控制面任务）。
pub(crate) fn spawn_control_connected(state: &Arc<RuntimeState>) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("discovery-control-connected", async move {
        on_control_connected(&state).await;
    });
}

/// 从本地 PathManager 刷新候选 bundle 与传输能力到 LocalDiscoveryManager。
async fn refresh_local_discovery(state: &RuntimeState, manager: &LocalDiscoveryManager) {
    let bundle = candidate_bundle_from_local(state).await;
    manager.set_candidate_bundle(bundle);
    manager.set_transport_capabilities(local_transport_capabilities());
}

/// 若 v2 控制面已接线且可用，内联执行一次完整可靠发布（含重试）。
async fn trigger_publish(
    state: &Arc<RuntimeState>,
    manager: Arc<LocalDiscoveryManager>,
    reason: &'static str,
) {
    let Some(control) = state.relay.control.read().await.clone() else {
        return;
    };
    if !control.is_usable().await {
        return;
    }
    let publisher = DiscoveryPublisher::new(control);
    let outcome = publisher.publish(&manager, reason).await;
    tracing::debug!(?outcome, reason, "discovery publish completed");
}

#[cfg(test)]
#[path = "../tests/discovery/mod.rs"]
mod tests;
