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
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>> {
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
