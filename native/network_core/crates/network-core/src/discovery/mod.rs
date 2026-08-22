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
mod tests {
    use super::*;
    use crate::connect::{PeerId, PeerState, PeerSupervisor};
    use network_protocol::CommunicationClass;
    use network_relay::v2::{DiscoveryAck, DiscoverySnapshot, ResolvePeerResponse, ResolveStatus};
    use network_relay::RelayError;
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicBool, AtomicU16, AtomicUsize, Ordering};
    use std::sync::Mutex;
    use tokio::sync::mpsc::unbounded_channel;

    /// 记录已发布 snapshot 的 mock 控制面（AlwaysOk）。
    struct RecordingControl {
        published: Mutex<Vec<DiscoverySnapshot>>,
        calls: AtomicUsize,
        usable: AtomicBool,
    }

    impl RecordingControl {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                published: Mutex::new(Vec::new()),
                calls: AtomicUsize::new(0),
                usable: AtomicBool::new(true),
            })
        }
    }

    impl DiscoveryControlPlane for RecordingControl {
        fn publish_discovery(
            &self,
            request_id: u64,
            snapshot: DiscoverySnapshot,
        ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let ack = DiscoveryAck {
                request_id,
                runtime_epoch: snapshot.runtime_epoch.clone(),
                revision: snapshot.revision,
            };
            self.published.lock().unwrap().push(snapshot.clone());
            Box::pin(async move { Ok(ack) })
        }

        fn resolve_peer(
            &self,
            _target_device_id: &str,
        ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>>
        {
            Box::pin(async move {
                Ok(ResolvePeerResponse {
                    request_id: 0,
                    status: ResolveStatus::Unknown as i32,
                    discovery: None,
                    retry_after_ms: 0,
                })
            })
        }

        fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            let usable = self.usable.load(Ordering::SeqCst);
            Box::pin(async move { usable })
        }

        fn echoes_request_id(&self) -> bool {
            true
        }
    }

    async fn test_state() -> Arc<RuntimeState> {
        let (event_tx, _event_rx) = unbounded_channel();
        Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
    }

    #[tokio::test]
    async fn begin_epoch_initializes_local_discovery_at_revision_one() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let manager = state
            .local_discovery
            .read()
            .await
            .clone()
            .expect("local discovery initialized");
        assert_eq!(manager.revision(), 1);
        // begin_epoch 不直接发布，状态保持 Idle。
        assert_eq!(manager.state(), LocalDiscoveryState::Idle);
    }

    #[tokio::test]
    async fn on_control_connected_republishes_at_current_revision_without_bump() {
        let state = test_state().await;
        begin_epoch(&state).await;
        // 让本地 discovery 到 revision=3。
        let manager = state.local_discovery.read().await.clone().unwrap();
        manager.bump_revision();
        manager.bump_revision();
        assert_eq!(manager.revision(), 3);

        let control = RecordingControl::new();
        *state.relay.control.write().await = Some(control.clone());

        on_control_connected(&state).await;

        // 重连重发完整 snapshot：revision 仍是 3（epoch/revision 不变，§8）。
        assert_eq!(manager.revision(), 3);
        assert_eq!(manager.state(), LocalDiscoveryState::Published);
        let published = control.published.lock().unwrap().clone();
        assert_eq!(published.len(), 1);
        assert_eq!(published[0].revision, 3);
        assert_eq!(
            published[0].runtime_epoch.as_ref(),
            Some(&manager.runtime_epoch())
        );
    }

    #[tokio::test]
    async fn on_local_candidates_changed_bumps_revision_then_publishes() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let control = RecordingControl::new();
        *state.relay.control.write().await = Some(control.clone());
        let manager = state.local_discovery.read().await.clone().unwrap();

        on_local_candidates_changed(&state).await;

        // 网络变化 → revision++ → 发布 → ACK（§9）。
        assert_eq!(manager.revision(), 2);
        assert_eq!(manager.state(), LocalDiscoveryState::Published);
        let published = control.published.lock().unwrap().clone();
        assert_eq!(published.len(), 1);
        assert_eq!(published[0].revision, 2);
    }

    #[tokio::test]
    async fn environment_change_is_a_non_destructive_discovery_transition() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let control = RecordingControl::new();
        *state.relay.control.write().await = Some(control.clone());
        state
            .relay
            .relay_path_ready
            .write()
            .await
            .insert("peer-a".to_string());

        let result = on_network_environment_changed(&state, 42, true)
            .await
            .expect("local discovery transition");

        assert_eq!(result.generation, 42);
        assert!(result.has_connectivity);
        assert_eq!(result.revision, 2);
        assert_eq!(
            state
                .local_discovery
                .read()
                .await
                .as_ref()
                .unwrap()
                .revision(),
            2
        );
        assert!(state.relay.relay_path_ready.read().await.contains("peer-a"));
        assert!(control.is_usable().await);
        assert_eq!(control.calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            control.published.lock().unwrap()[0].revision,
            result.revision
        );
    }

    #[tokio::test]
    async fn environment_change_without_connectivity_still_publishes_and_preserves_relay() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let control = RecordingControl::new();
        *state.relay.control.write().await = Some(control.clone());
        state
            .relay
            .relay_path_ready
            .write()
            .await
            .insert("peer-a".into());

        let result = on_network_environment_changed(&state, 43, false)
            .await
            .expect("local discovery transition");

        assert!(!result.has_connectivity);
        assert!(state.relay.relay_path_ready.read().await.contains("peer-a"));
        assert_eq!(control.calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            state.local_discovery.read().await.as_ref().unwrap().state(),
            LocalDiscoveryState::Published
        );
    }

    #[test]
    fn passive_inbound_sets_online() {
        let supervisor = PeerSupervisor::new(PeerId::new("passive-peer").expect("peer id"));

        assert_eq!(supervisor.admit_inbound(true), Ok(PeerState::Online));
        assert_eq!(supervisor.state(), PeerState::Online);
    }

    #[test]
    fn passive_inbound_keeps_maintain_false() {
        let supervisor = PeerSupervisor::new(PeerId::new("passive-peer").expect("peer id"));

        supervisor
            .admit_inbound(true)
            .expect("authenticated inbound");

        assert!(!supervisor.maintain_connection());
    }

    #[test]
    fn passive_path_loss_does_not_reconnect() {
        let supervisor = PeerSupervisor::new(PeerId::new("passive-peer").expect("peer id"));

        supervisor
            .admit_inbound(true)
            .expect("authenticated inbound");
        supervisor.path_lost();

        assert_eq!(supervisor.state(), PeerState::Offline);
        assert!(!supervisor.maintain_connection());
        assert!(
            supervisor.can_evict(),
            "passive loss must not schedule recovery"
        );
    }

    #[tokio::test]
    async fn environment_change_preserves_maintain_false() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let supervisor = state
            .peer_supervisors
            .get_or_create("passive-peer")
            .expect("peer supervisor");
        supervisor
            .admit_inbound(true)
            .expect("authenticated inbound");

        on_network_environment_changed(&state, 44, true).await;

        assert!(!supervisor.maintain_connection());
    }

    #[tokio::test]
    async fn environment_change_preserves_maintain_true() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let supervisor = state
            .peer_supervisors
            .get_or_create("maintained-peer")
            .expect("peer supervisor");
        let intent = supervisor
            .begin_connect("environment-test", CommunicationClass::ReliableMessage)
            .expect("connect intent");
        intent.detach_completion();

        on_network_environment_changed(&state, 45, true).await;

        assert!(supervisor.maintain_connection());
    }

    #[tokio::test]
    async fn hooks_are_noop_without_a_wired_control_plane() {
        let state = test_state().await;
        begin_epoch(&state).await;
        let manager = state.local_discovery.read().await.clone().unwrap();
        on_control_connected(&state).await;
        on_local_candidates_changed(&state).await;
        // 未接线控制面：no-op，但本地状态仍正确推进。
        assert_eq!(manager.revision(), 2); // candidates-changed 已 bump
        assert_eq!(manager.state(), LocalDiscoveryState::Idle);
    }
}
