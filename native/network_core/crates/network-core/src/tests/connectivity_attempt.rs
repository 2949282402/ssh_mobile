//! ConnectivityAttempt boundary tests kept outside the implementation module.

use super::*;
use crate::connect::{PeerId, PeerPathManager, DEFAULT_CONNECTION_CAPABILITY};
use crate::connection::{ConnectionProfile, Route, RouteTransport};
use network_nat::PathManager;
use network_relay::v2::ResolveStatus;
use std::time::{Duration, Instant};

/// Captures the existing Direct-failure diagnostic from the test thread
/// without adding an observer or callback to the production coordinator.
struct StageCLogState {
    direct_failed_at: std::sync::Mutex<Option<Instant>>,
    expected_attempt_id: Arc<std::sync::Mutex<Option<String>>>,
}

impl StageCLogState {
    fn new() -> Self {
        Self {
            direct_failed_at: std::sync::Mutex::new(None),
            expected_attempt_id: Arc::new(std::sync::Mutex::new(None)),
        }
    }
}

struct StageCLogCapture {
    state: Arc<StageCLogState>,
}

impl StageCLogCapture {
    fn new(state: Arc<StageCLogState>) -> Self {
        Self { state }
    }
}

struct StageCEventVisitor {
    message: Option<String>,
    attempt_id: Option<String>,
}

impl tracing::field::Visit for StageCEventVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}"));
        } else if field.name() == "attempt_id" {
            self.attempt_id = Some(format!("{value:?}").trim_matches('"').to_string());
        }
    }
}

impl tracing::Subscriber for StageCLogCapture {
    fn enabled(&self, _metadata: &tracing::Metadata<'_>) -> bool {
        true
    }

    fn new_span(&self, _span: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }

    fn record(&self, _span: &tracing::span::Id, _values: &tracing::span::Record<'_>) {}

    fn record_follows_from(&self, _span: &tracing::span::Id, _follows: &tracing::span::Id) {}

    fn event(&self, event: &tracing::Event<'_>) {
        let mut visitor = StageCEventVisitor {
            message: None,
            attempt_id: None,
        };
        event.record(&mut visitor);
        let expected_attempt_id = self
            .state
            .expected_attempt_id
            .lock()
            .expect("Stage C attempt id lock")
            .clone();
        if expected_attempt_id
            .as_deref()
            .zip(visitor.attempt_id.as_deref())
            .is_some_and(|(expected, actual)| expected == actual)
            && visitor.message.as_deref().is_some_and(|message| {
                message.contains("direct first failed; falling back to relay")
            })
        {
            let mut timestamp = self
                .state
                .direct_failed_at
                .lock()
                .expect("Direct failure timestamp lock");
            if timestamp.is_none() {
                *timestamp = Some(Instant::now());
            }
        }
    }

    fn enter(&self, _span: &tracing::span::Id) {}

    fn exit(&self, _span: &tracing::span::Id) {}
}

static STAGE_C_LOG_STATE: std::sync::OnceLock<Arc<StageCLogState>> = std::sync::OnceLock::new();

fn stage_c_log_state() -> Arc<StageCLogState> {
    if let Some(state) = STAGE_C_LOG_STATE.get() {
        return Arc::clone(state);
    }
    let state = Arc::new(StageCLogState::new());
    if STAGE_C_LOG_STATE.set(Arc::clone(&state)).is_ok() {
        tracing::subscriber::set_global_default(StageCLogCapture::new(Arc::clone(&state)))
            .expect("Stage C tracing subscriber must be installable");
    }
    STAGE_C_LOG_STATE
        .get()
        .map(Arc::clone)
        .expect("Stage C tracing state")
}

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

/// A valid READY snapshot whose only advertised Direct candidate points
/// at a closed loopback port.  The bounded Direct race therefore fails
/// without depending on a live peer, while the snapshot still retains the
/// authoritative epoch/revision and RelayData capability needed to
/// exercise the Stage C eligibility boundary.
fn stage_c_ready_unreachable_direct_snapshot() -> DiscoverySnapshot {
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("direct candidate endpoint"),
        CandidateKind::Lan,
        "stage-c-direct".into(),
    )
    .with_generation(1);
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: 101,
            low: 202,
        }),
        revision: 1,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::Quic as i32,
            network_relay::v2::TransportCapability::RelayData as i32,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&candidate.advertisement())
                .expect("direct candidate advertisement")],
        }),
        published_at_ms: 0,
    }
}

fn stage_c_ready_relay_only_snapshot() -> DiscoverySnapshot {
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("relay candidate endpoint"),
        CandidateKind::Relay,
        "stage-c-relay".into(),
    )
    .with_generation(1);
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: 101,
            low: 202,
        }),
        revision: 1,
        transport_capabilities: vec![network_relay::v2::TransportCapability::RelayData as i32],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&candidate.advertisement())
                .expect("relay candidate advertisement")],
        }),
        published_at_ms: 0,
    }
}

async fn install_ready_direct_path(state: &RuntimeState, peer_id: &str, transport: RouteTransport) {
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

#[test]
fn coordinator_stage_setter_round_trips_every_terminal_and_live_state() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let coordinator = ConnectivityAttemptCoordinator::new(state);
    for expected in [
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
    ] {
        coordinator.set_stage(expected);
        assert_eq!(coordinator.stage(), expected);
    }
}

#[tokio::test]
async fn session_cleanup_guard_only_retires_an_armed_exact_session() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let session_id = match state
        .begin_connect("peer-a", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    {
        let mut guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-a", session_id);
        guard.disarm();
    }
    assert_eq!(
        state.connection_sessions.current_session_id("peer-a").await,
        Some(session_id)
    );
    {
        let _guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-a", session_id);
    }
    tokio::task::yield_now().await;
    assert!(state
        .connection_sessions
        .current_session_id("peer-a")
        .await
        .is_none());
}

#[tokio::test]
async fn connect_and_probe_reject_missing_runtime_inputs_fail_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let endpoint = state
        .lifecycle
        .endpoint
        .read()
        .await
        .clone()
        .expect("configured endpoint");
    let identity = state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .expect("configured identity");

    *state.lifecycle.endpoint.write().await = None;
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without endpoint must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without endpoint must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);

    *state.lifecycle.endpoint.write().await = Some(endpoint);
    *state.lifecycle.identity.write().await = None;
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without identity must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without identity must fail");
    assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);

    *state.lifecycle.identity.write().await = Some(identity);
    state.peers.write().await.remove("peer-b");
    let error = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("connect without peer route must fail");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("direct probe without peer route must fail");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn direct_probe_reports_no_route_when_no_candidate_is_available() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));

    let error = coordinator
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("a configured runtime without candidates must fail closed");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a probe with no candidate must not reserve a Session"
    );
}

#[tokio::test]
async fn direct_probe_retires_its_temporary_session_after_a_failed_race() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("closed direct endpoint"),
        CandidateKind::Lan,
        "probe-unreachable".into(),
    )
    .with_generation(1);
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 41, low: 42 },
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(30)),
        },
        Instant::now(),
    )
    .expect("valid probe cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);

    let error = coordinator_for(&state)
        .probe_direct("peer-b", CommunicationClass::ReliableMessage)
        .await
        .expect_err("closed direct candidate must fail");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed pure Direct probing must retire its temporary Session"
    );
}

fn coordinator_for(state: &Arc<RuntimeState>) -> ConnectivityAttemptCoordinator {
    ConnectivityAttemptCoordinator::new(Arc::clone(state))
}

#[tokio::test]
async fn capability_mismatch_is_rejected_before_a_second_control_transaction() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, crate::connect::CAPABILITY_RELIABLE_MESSAGE)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let _admission = state
        .admit_authenticated_session(peer_id, Some(session_id), "remote-session")
        .await
        .expect("authenticate the existing route");
    assert!(
        state
            .mark_relay_route_connected(peer_id, session_id, None)
            .await
    );

    let error = coordinator_for(&state)
        .connect_with_class(peer_id, CommunicationClass::UnreliableDatagram)
        .await
        .expect_err("a message-only route cannot satisfy a datagram request");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    state.close_transport_path(peer_id).await;
    state.fail_session(peer_id, session_id).await;
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
async fn in_progress_admission_retries_after_the_owned_session_is_retired() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("expected an in-progress owner session, got {decision:?}"),
    };

    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        ConnectivityAttemptCoordinator::new(task_state)
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await
    });

    // Let the second coordinator observe the first owner's in-progress
    // session, then retire that exact admission as a failed attempt would.
    tokio::time::sleep(Duration::from_millis(30)).await;
    state.fail_session("peer-b", session_id).await;

    let result = task.await.expect("connect task");
    assert!(
        result.is_err(),
        "the stub control plane has no usable route"
    );
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 1);
    assert_eq!(control.reserve_calls(), 0);
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert!(
        state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_none(),
        "failed retry must retire the replacement session"
    );
}

#[tokio::test]
async fn in_progress_admission_reuses_a_route_that_appears_before_retry() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("expected an in-progress owner session, got {decision:?}"),
    };

    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        ConnectivityAttemptCoordinator::new(task_state)
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await
    });

    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(
        state
            .mark_relay_route_connected("peer-b", session_id, None)
            .await,
        "the in-progress owner should be able to publish the replacement route"
    );

    assert!(task.await.expect("connect task").is_ok());
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    assert!(state.path_is_connected("peer-b").await);
    state.close_transport_path("peer-b").await;
    state
        .connection_sessions
        .retire_session("peer-b", session_id)
        .await;
}

#[tokio::test]
async fn cancelled_attempt_allows_immediate_reconnect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_unreachable_direct_snapshot()),
    );
    *state.relay.control.write().await = Some(control.clone());

    let coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let task = {
        let coordinator = Arc::clone(&coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };

    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if control.connectivity_calls() == 1 {
                if let Some(session_id) =
                    state.connection_sessions.current_session_id("peer-b").await
                {
                    break session_id;
                }
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("Stage B must commit Offer before cancellation");

    task.abort();
    let _ = task.await;

    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cancelled attempt must retire its exact Session");

    let new_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            match state
                .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
                .await
            {
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(_) => tokio::task::yield_now().await,
                decision => panic!("unexpected reconnect admission: {decision:?}"),
            }
        }
    })
    .await
    .expect("cancelled attempt must allow a new admission");

    assert_ne!(new_session_id, old_session_id);
    assert!(
        state
            .mark_relay_route_connected("peer-b", new_session_id, None)
            .await,
        "replacement Session must be able to publish a route"
    );

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale cleanup must not retire the replacement Session"
    );
    assert!(state.path_is_connected("peer-b").await);

    state.close_transport_path("peer-b").await;
    state.fail_session("peer-b", new_session_id).await;
}

#[tokio::test]
async fn cancelled_connect_can_immediately_start_second_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let first_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_unreachable_direct_snapshot()),
    );
    first_control.hold_offer();
    *state.relay.control.write().await = Some(first_control.clone());

    let first_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let first_task = {
        let coordinator = Arc::clone(&first_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    first_control.wait_offer_started().await;
    let old_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("first coordinator must own a Session before Offer");

    first_task.abort();
    assert!(first_task
        .await
        .expect_err("first connect must abort")
        .is_cancelled());
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cancelled coordinator must retire its old Session");

    let second_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    second_control.hold_offer();
    *state.relay.control.write().await = Some(second_control.clone());

    let second_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let second_task = {
        let coordinator = Arc::clone(&second_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    second_control.wait_offer_started().await;
    let new_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("second coordinator must own a new Session before Offer release");

    assert!(second_control.resolve_calls() >= 1);
    assert!(second_control.connectivity_calls() >= 1);
    assert_ne!(new_session_id, old_session_id);

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale cancellation cleanup must not retire the replacement Session"
    );

    second_control.release_offer();
    let result = tokio::time::timeout(Duration::from_secs(2), second_task)
        .await
        .expect("second coordinator must not remain permanently InProgress")
        .expect("second coordinator task");
    assert!(
        result.is_err(),
        "the closed test candidate must fail normally: {result:?}"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed replacement coordinator must retire its own Session"
    );
}

#[tokio::test(start_paused = true)]
async fn overall_timeout_does_not_poison_next_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::timeout();
    *state.relay.control.write().await = Some(control);

    let coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let task = {
        let coordinator = Arc::clone(&coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };

    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if let Some(session_id) = state.connection_sessions.current_session_id("peer-b").await {
                break session_id;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("timeout attempt must reserve a Session before Resolve");

    tokio::task::yield_now().await;
    tokio::time::advance(super::super::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = task.await.expect("overall timeout task");
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "hanging control transaction must map to Timeout: {result:?}"
    );

    tokio::task::yield_now().await;
    let new_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            match state
                .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
                .await
            {
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(_) => tokio::task::yield_now().await,
                decision => panic!("unexpected reconnect admission: {decision:?}"),
            }
        }
    })
    .await
    .expect("overall timeout must allow a new admission");

    assert_ne!(new_session_id, old_session_id);
    assert!(
        state
            .mark_relay_route_connected("peer-b", new_session_id, None)
            .await,
        "replacement Session must survive stale timeout cleanup"
    );
    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id)
    );
    assert!(state.path_is_connected("peer-b").await);

    state.close_transport_path("peer-b").await;
    state.fail_session("peer-b", new_session_id).await;
}

#[tokio::test(start_paused = true)]
async fn overall_timeout_allows_real_second_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let first_control = StubControl::timeout();
    *state.relay.control.write().await = Some(first_control.clone());

    let first_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let first_task = {
        let coordinator = Arc::clone(&first_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if first_control.resolve_calls() >= 1 {
                if let Some(session_id) =
                    state.connection_sessions.current_session_id("peer-b").await
                {
                    break session_id;
                }
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("timeout coordinator must reach authoritative Resolve");

    tokio::time::advance(super::super::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = first_task.await.expect("overall timeout task");
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "first coordinator must return Timeout: {result:?}"
    );
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("overall timeout cleanup must retire the old Session");

    let second_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    second_control.hold_offer();
    *state.relay.control.write().await = Some(second_control.clone());

    let second_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let second_task = {
        let coordinator = Arc::clone(&second_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    second_control.wait_offer_started().await;
    let new_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("second coordinator must reach Offer with a new Session");

    assert!(second_control.resolve_calls() >= 1);
    assert!(second_control.connectivity_calls() >= 1);
    assert_ne!(new_session_id, old_session_id);

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale timeout cleanup must not retire the replacement Session"
    );

    second_control.release_offer();
    let result = tokio::time::timeout(Duration::from_secs(2), second_task)
        .await
        .expect("second coordinator must not remain permanently InProgress")
        .expect("second coordinator task");
    assert!(
        result.is_err(),
        "the closed test candidate must fail normally: {result:?}"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed replacement coordinator must retire its own Session"
    );
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
    control.observe_session_ownership(Arc::clone(&state));

    let stage_c_state = stage_c_log_state();
    *stage_c_state
        .direct_failed_at
        .lock()
        .expect("Direct failure timestamp lock") = None;
    *stage_c_state
        .expected_attempt_id
        .lock()
        .expect("Stage C attempt id lock") = None;
    control.observe_attempt_id(Arc::clone(&stage_c_state.expected_attempt_id));
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
    assert!(
        control.first_resolve_saw_owned_session(),
        "Stage B must reserve a local Session before authoritative Resolve"
    );
    assert_eq!(
        control.connectivity_calls(),
        1,
        "Stage B must enqueue exactly one ConnectivityOffer"
    );
    assert_eq!(
        control.reserve_calls(),
        1,
        "Stage C must issue exactly one Relay reservation"
    );
    let direct_failed_at = stage_c_state
        .direct_failed_at
        .lock()
        .expect("Direct failure timestamp lock")
        .expect("Stage C observer must capture Direct failure");
    let call_times = control.call_times();
    let resolve_at = call_times
        .iter()
        .find_map(|(name, timestamp)| (*name == "resolve").then_some(*timestamp))
        .expect("Resolve timestamp");
    let offer_at = call_times
        .iter()
        .find_map(|(name, timestamp)| (*name == "offer").then_some(*timestamp))
        .expect("Offer timestamp");
    let reserve_at = control.reserve_at().expect("Reserve timestamp");
    assert!(
        resolve_at < offer_at && offer_at < direct_failed_at && direct_failed_at < reserve_at,
        "Stage C must preserve Resolve → Offer → Direct failure → Reserve ordering: resolve={resolve_at:?}, offer={offer_at:?}, direct_failed={direct_failed_at:?}, reserve={reserve_at:?}"
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stage_c_direct_success_attaches_a_fresh_quic_session() {
    let (client_state, _event_rx, _configured_control) = configured_reuse_state().await;
    let client_identity = client_state
        .lifecycle
        .identity
        .read()
        .await
        .clone()
        .expect("client identity");

    let server_identity = Arc::new(network_identity::DeviceIdentity::from_private_keys(
        "peer-b".into(),
        [41u8; 32],
        [51u8; 32],
    ));
    let (server_event_tx, _server_event_rx) = tokio::sync::mpsc::unbounded_channel();
    let server_state = Arc::new(RuntimeState::new(
        server_event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *server_state.lifecycle.identity.write().await = Some(Arc::clone(&server_identity));
    server_state.peers.write().await.insert(
        client_identity.device_id.clone(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: client_identity.public_identity_key().to_bytes(),
            e2e_public_key: client_identity.public_e2e_key().to_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    server_state.trusted_peer_keys.write().await.insert(
        client_identity.device_id.clone(),
        client_identity.public_identity_key().to_bytes(),
    );
    let server_endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("server address"),
        Arc::new(PathManager::new()),
    )
    .expect("server endpoint")
    .endpoint;
    let server_address = server_endpoint.local_addr().expect("server local address");
    server_state
        .task_supervisor
        .spawn_runtime(
            "stage-c-direct-accept",
            crate::peer::accept_connections(server_endpoint.clone(), Arc::clone(&server_state)),
        )
        .expect("server accept task");

    {
        let mut peers = client_state.peers.write().await;
        let peer = peers.get_mut("peer-b").expect("configured peer");
        peer.identity_public_key = server_identity.public_identity_key().to_bytes();
        peer.e2e_public_key = server_identity.public_e2e_key().to_bytes();
    }
    let candidate = Candidate::new(server_address, CandidateKind::Lan, "stage-c-quic".into())
        .with_generation(1);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 11, low: 12 }),
        revision: 1,
        transport_capabilities: vec![network_relay::v2::TransportCapability::Quic as i32],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                serde_json::to_vec(&candidate.advertisement()).expect("candidate advertisement")
            ],
        }),
        published_at_ms: 0,
    };
    let control = StubControl::new(ResolveStatus::Ready, Some(snapshot.clone()));
    *client_state.relay.control.write().await = Some(control.clone());
    let answer = network_relay::v2::ConnectivityAnswer {
        request_id: 1,
        attempt_id: String::new(),
        accepted: true,
        responder_device_id: "peer-b".into(),
        responder_runtime_epoch: snapshot.runtime_epoch.clone(),
        responder_revision: snapshot.revision,
        responder_snapshot: Some(snapshot.clone()),
    };
    control.set_connectivity_answer(answer);
    control.observe_session_ownership(Arc::clone(&client_state));

    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&client_state));
    let result = coordinator
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(result.is_ok(), "Direct Stage C should attach: {result:?}");
    assert_eq!(
        coordinator.stage(),
        ConnectivityAttemptState::ConnectedDirect
    );
    assert!(
        client_state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_some(),
        "Direct attach must retain the session admission"
    );
    let manager_state = client_state
        .peer_path_managers
        .read()
        .await
        .get("peer-b")
        .cloned()
        .map(|manager| {
            let manager = manager.lock().expect("peer path manager lock");
            (
                manager.direct_ready().len(),
                manager.relay_ready().is_some(),
            )
        });
    assert_eq!(
        manager_state,
        Some((1, false)),
        "Direct attach must retain its ready Direct carrier"
    );
    assert!(
        client_state.path_profile("peer-b").await.is_some(),
        "Direct attach must publish a physical path"
    );
    assert!(client_state.path_is_connected("peer-b").await);
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 1);
    assert_eq!(control.reserve_calls(), 0);

    let session_id = client_state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("client session");
    client_state.close_transport_path("peer-b").await;
    client_state
        .connection_sessions
        .retire_session("peer-b", session_id)
        .await;
    client_state
        .cancel_session_tasks("peer-b", session_id)
        .await;
    server_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    client_state.task_supervisor.cancel_root();
    server_state.task_supervisor.cancel_root();
    client_state.task_supervisor.shutdown().await;
    server_state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn stage_b_not_ready_retries_once_with_a_fresh_attempt_id() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.return_not_ready_once();
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let result = coordinator
        .begin_stage_b_transaction(
            control.clone(),
            StageBTransactionRequest {
                peer_id: "peer-b".into(),
                initiator_device_id: "device-a".into(),
                initiator_runtime_epoch: RuntimeEpoch { high: 1, low: 2 },
                initiator_revision: 1,
                initiator_snapshot: None,
                connect_deadline: Instant::now() + Duration::from_secs(2),
            },
        )
        .await
        .expect("NOT_READY should retry within the connect budget");

    assert_eq!(
        control.resolve_calls(),
        2,
        "retry must issue a fresh Resolve"
    );
    assert_eq!(
        control.connectivity_calls(),
        1,
        "only the READY retry may Offer"
    );
    assert_eq!(control.call_order(), vec!["resolve", "resolve", "offer"]);
    assert_eq!(result.1.resolved.status, ResolveStatus::Ready as i32);
    assert!(matches!(
        result.1.wait_for_answer().await,
        Err(RelayError::NotConnected)
    ));
}

#[tokio::test]
async fn stage_b_not_ready_preserves_authority_when_budget_is_exhausted() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.return_not_ready_once();
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let (_, start) = coordinator
        .begin_stage_b_transaction(
            control.clone(),
            StageBTransactionRequest {
                peer_id: "peer-b".into(),
                initiator_device_id: "device-a".into(),
                initiator_runtime_epoch: RuntimeEpoch { high: 1, low: 2 },
                initiator_revision: 1,
                initiator_snapshot: None,
                connect_deadline: Instant::now(),
            },
        )
        .await
        .expect("the first authoritative NOT_READY response should return");

    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(start.resolved.status, ResolveStatus::NotReady as i32);
}

#[tokio::test]
async fn stage_b_rejects_an_unusable_control_plane_before_session_ownership() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_usable(false);
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "control-plane admission must precede local Session ownership"
    );
}

#[tokio::test(start_paused = true)]
async fn overall_connect_budget_maps_a_hanging_control_transaction_to_timeout() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let hanging = StubControl::timeout();
    *state.relay.control.write().await = Some(hanging);
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let task = tokio::spawn(async move {
        coordinator
            .connect_with_capabilities("peer-b", DEFAULT_CONNECTION_CAPABILITY)
            .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(crate::connect::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = task.await.expect("connect task");
    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::Timeout as i32
    ));
    for _ in 0..10 {
        if state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_none()
        {
            break;
        }
        tokio::task::yield_now().await;
    }
    assert!(
        state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_none(),
        "cancelling the bounded connect must retire its Session"
    );
    drop(control);
}

#[tokio::test]
async fn stage_a_direct_failure_releases_owned_session_before_authoritative_offline() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("closed direct endpoint"),
        CandidateKind::Lan,
        "stage-a-unreachable".into(),
    )
    .with_generation(1);
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 9, low: 10 },
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(30)),
        },
        Instant::now(),
    )
    .expect("valid Stage A cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);
    let control = StubControl::new(ResolveStatus::Offline, None);
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::PeerOffline as i32
    ));
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed uncoordinated Direct must not leak its temporary Session"
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
fn malformed_and_relay_only_snapshots_never_become_direct_candidates() {
    let lan = Candidate::new(
        "192.168.1.31:41004".parse().expect("LAN endpoint"),
        CandidateKind::Lan,
        "lan-fallback".into(),
    )
    .with_generation(2);
    let relay = Candidate::new(
        "127.0.0.1:41005".parse().expect("Relay endpoint"),
        CandidateKind::Relay,
        "relay-only".into(),
    )
    .with_generation(3);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 19, low: 20 }),
        revision: 5,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::RelayData as i32,
            999,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                b"not-json".to_vec(),
                serde_json::to_vec(&lan.advertisement()).expect("LAN advertisement"),
                serde_json::to_vec(&relay.advertisement()).expect("Relay advertisement"),
            ],
        }),
        published_at_ms: 0,
    };

    let payloads = snapshot_candidate_payloads(&snapshot);
    assert_eq!(
        payloads.len(),
        1,
        "RelayData-only snapshots drop direct LAN candidates"
    );
    assert_eq!(payloads[0].kind, CandidateKind::Relay);
    assert!(discovery_snapshot_candidates(&snapshot).is_empty());

    let legacy_snapshot = DiscoverySnapshot {
        runtime_epoch: snapshot.runtime_epoch,
        revision: snapshot.revision,
        transport_capabilities: Vec::new(),
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&lan.advertisement()).expect("LAN advertisement")],
        }),
        published_at_ms: 0,
    };
    let legacy = snapshot_candidate_payloads(&legacy_snapshot);
    assert_eq!(legacy.len(), 1);
    assert_eq!(
        legacy[0].transport_capabilities,
        vec![CandidateTransport::Quic]
    );
}

#[test]
fn candidate_order_keeps_configured_and_tail_kinds_deterministic() {
    let port_mapped = Candidate::new(
        "203.0.113.31:41006".parse().expect("mapped endpoint"),
        CandidateKind::PortMapped,
        "mapped".into(),
    );
    let relay = Candidate::new(
        "127.0.0.1:41007".parse().expect("relay endpoint"),
        CandidateKind::Relay,
        "relay".into(),
    );
    let configured = Candidate::new(
        "192.168.1.32:41008".parse().expect("configured endpoint"),
        CandidateKind::Lan,
        "peer-configured".into(),
    );
    assert_eq!(candidate_order(&configured), 3);
    assert_eq!(candidate_order(&port_mapped), 4);
    assert_eq!(candidate_order(&relay), 5);
}

#[test]
fn relay_fallback_gate_requires_ready_relay_policy_and_budget() {
    let ready = ResolvedPeer::Ready {
        discovery: Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 15, low: 16 }),
            revision: 3,
            transport_capabilities: vec![network_relay::v2::TransportCapability::RelayData as i32],
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
        &ResolvedPeer::Offline,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!relay_fallback_is_eligible(
        &ResolvedPeer::Unknown { retry_after_ms: 0 },
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
        network_identity::DeviceIdentity::from_private_keys("local-a".into(), [1u8; 32], [2u8; 32]),
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
    let mut updates = attempt_coordinator
        .spawn_coordination(
            coordination,
            "peer-b".into(),
            "attempt-answer".into(),
            Arc::clone(&attempt),
            Vec::new(),
            Some(Duration::from_secs(60)),
        )
        .expect("coordination task should start");
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

#[test]
fn coordination_and_authoritative_statuses_fail_closed() {
    let peer_id = "peer-b";
    let ready_snapshot = stage_c_ready_relay_only_snapshot();
    let ready_response = ResolvePeerResponse {
        request_id: 1,
        status: ResolveStatus::Ready as i32,
        discovery: Some(ready_snapshot.clone()),
        retry_after_ms: 0,
    };
    let resolved = ready_peer_from_coordination(&ready_response, peer_id)
        .expect("READY with discovery must resolve");
    assert!(matches!(
        resolved,
        ResolvedPeer::Ready { discovery: Some(_) }
    ));

    for (status, expected_code) in [
        (ResolveStatus::Offline, NetworkErrorCode::PeerOffline),
        (ResolveStatus::NotReady, NetworkErrorCode::PeerNotReady),
        (ResolveStatus::Unknown, NetworkErrorCode::RelayError),
        (ResolveStatus::Unspecified, NetworkErrorCode::RelayError),
    ] {
        let response = ResolvePeerResponse {
            request_id: 2,
            status: status as i32,
            discovery: None,
            retry_after_ms: 500,
        };
        let error = ready_peer_from_coordination(&response, peer_id)
            .expect_err("non-ready status must not fabricate a peer");
        assert_eq!(error.code, expected_code as i32, "status={status:?}");
    }

    let missing_discovery = ResolvePeerResponse {
        request_id: 3,
        status: ResolveStatus::Ready as i32,
        discovery: None,
        retry_after_ms: 0,
    };
    let error = ready_peer_from_coordination(&missing_discovery, peer_id)
        .expect_err("READY without discovery must fail closed");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let coordinator = ConnectivityAttemptCoordinator::new(state);
    assert!(coordinator
        .authoritative_resolve_or_error(
            peer_id,
            &peer_without_endpoint(),
            Ok(ResolvedPeer::Ready {
                discovery: Some(ready_snapshot),
            }),
        )
        .is_ok());
    for (resolved, expected_code) in [
        (
            ResolvedPeer::Ready { discovery: None },
            NetworkErrorCode::RelayError,
        ),
        (ResolvedPeer::Offline, NetworkErrorCode::PeerOffline),
        (
            ResolvedPeer::NotReady {
                retry_after_ms: 500,
            },
            NetworkErrorCode::PeerNotReady,
        ),
        (
            ResolvedPeer::Unknown {
                retry_after_ms: 500,
            },
            NetworkErrorCode::RelayError,
        ),
    ] {
        let error = coordinator
            .authoritative_resolve_or_error(peer_id, &peer_without_endpoint(), Ok(resolved))
            .expect_err("authoritative status must remain typed");
        assert_eq!(error.code, expected_code as i32);
    }
    let error = coordinator
        .authoritative_resolve_or_error(
            peer_id,
            &peer_without_endpoint(),
            Err(protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "cancelled",
                "test",
                peer_id,
            )),
        )
        .expect_err("transport error must propagate");
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
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
    assert_eq!(
        runtime_epoch_from_nat(nat_runtime_epoch(&RuntimeEpoch { high: 9, low: 10 })),
        RuntimeEpoch { high: 9, low: 10 }
    );
    assert_eq!(
        resolved_snapshot(&resolved).map(|snapshot| snapshot.revision),
        Some(3)
    );
    assert_eq!(resolved_runtime_epoch(&ResolvedPeer::Offline), None);
    assert!(resolved_snapshot(&ResolvedPeer::Offline).is_none());
    assert_eq!(
        resolved_runtime_epoch(&ResolvedPeer::Ready { discovery: None }),
        None
    );
}

#[test]
fn candidate_conversion_and_snapshot_transport_mapping_are_fail_closed() {
    let candidate = Candidate::new(
        "192.0.2.50:41050".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "helper-lan".into(),
    )
    .with_generation(4);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 5, low: 6 }),
        revision: 8,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::Quic as i32,
            network_relay::v2::TransportCapability::Tcp as i32,
            network_relay::v2::TransportCapability::UdpDatagram as i32,
            network_relay::v2::TransportCapability::Websocket as i32,
            network_relay::v2::TransportCapability::RelayData as i32,
            network_relay::v2::TransportCapability::Webrtc as i32,
            network_relay::v2::TransportCapability::Unspecified as i32,
            999,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                b"not-json".to_vec(),
                serde_json::to_vec(&candidate.advertisement()).expect("advertisement"),
            ],
        }),
        published_at_ms: 0,
    };
    assert_eq!(
        snapshot_candidate_transports(&snapshot),
        vec![
            CandidateTransport::Quic,
            CandidateTransport::Tcp,
            CandidateTransport::UdpDatagram,
            CandidateTransport::Websocket,
            CandidateTransport::Relay,
        ]
    );
    let payloads = snapshot_candidate_payloads(&snapshot);
    assert_eq!(payloads.len(), 1);
    let direct = candidate_from_v2(&payloads[0]).expect("LAN candidate is direct eligible");
    assert!(direct.candidate_id.starts_with("helper-lan"));
    assert_eq!(direct.generation, 4);
    let mut relay = payloads[0].clone();
    relay.kind = CandidateKind::Relay;
    relay.transport_capabilities = vec![CandidateTransport::Relay];
    assert!(candidate_from_v2(&relay).is_none());
    let mut invalid = payloads[0].clone();
    invalid.transport_capabilities = vec![CandidateTransport::Relay];
    assert!(candidate_from_v2(&invalid).is_none());
}

#[tokio::test]
async fn cache_update_ignores_missing_epoch_and_rejects_inconsistent_snapshots() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    update_remote_candidate_cache(&state, "peer-b", None, None).await;
    update_remote_candidate_cache(
        &state,
        "peer-b",
        Some(&DiscoverySnapshot {
            runtime_epoch: None,
            revision: 1,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
        None,
    )
    .await;
    assert!(state.remote_candidate_cache.read().await.is_empty());

    let first = stage_c_ready_unreachable_direct_snapshot();
    update_remote_candidate_cache(&state, "peer-b", Some(&first), Some(Duration::from_secs(5)))
        .await;
    assert!(state
        .remote_candidate_cache
        .read()
        .await
        .contains_key("peer-b"));

    let inconsistent = DiscoverySnapshot {
        runtime_epoch: first.runtime_epoch.clone(),
        revision: 0,
        transport_capabilities: first.transport_capabilities.clone(),
        candidate_bundle: first.candidate_bundle.clone(),
        published_at_ms: 0,
    };
    update_remote_candidate_cache(
        &state,
        "peer-b",
        Some(&inconsistent),
        Some(Duration::from_secs(5)),
    )
    .await;
    assert_eq!(
        state
            .remote_candidate_cache
            .read()
            .await
            .get("peer-b")
            .expect("cache entry")
            .revision,
        1
    );
}

#[test]
fn relay_error_mapping_and_stage_c_epoch_revision_guards_are_typed() {
    let peer_id = "peer-b";
    assert_eq!(
        relay_resolve_error(&RelayError::Timeout("slow".into()), peer_id).code,
        NetworkErrorCode::Timeout as i32
    );
    assert_eq!(
        relay_resolve_error(&RelayError::NotConnected, peer_id).code,
        NetworkErrorCode::RelayError as i32
    );
    let mut missing_epoch = stage_c_ready_relay_only_snapshot();
    missing_epoch.runtime_epoch = None;
    assert!(!relay_fallback_is_eligible(
        &ResolvedPeer::Ready {
            discovery: Some(missing_epoch),
        },
        DEFAULT_CONNECTION_CAPABILITY,
        network_protocol::E2eePolicy::Required,
        Instant::now() + Duration::from_secs(1),
    ));
    let mut zero_revision = stage_c_ready_relay_only_snapshot();
    zero_revision.revision = 0;
    assert!(!relay_fallback_is_eligible(
        &ResolvedPeer::Ready {
            discovery: Some(zero_revision),
        },
        DEFAULT_CONNECTION_CAPABILITY,
        network_protocol::E2eePolicy::Required,
        Instant::now() + Duration::from_secs(1),
    ));
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
    control.observe_session_ownership(Arc::clone(&state));

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
    assert!(
        control.first_resolve_saw_owned_session(),
        "NOT_READY Resolve must still observe the owned local Session"
    );
    assert_eq!(
        control.connectivity_calls(),
        0,
        "NOT_READY transactions must not enqueue ConnectivityOffer"
    );
    assert_eq!(
        control.reserve_calls(),
        0,
        "NOT_READY transactions must not enqueue ReserveRelay"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a pre-Offer Resolve/status failure must retire the newly owned Session"
    );
}

#[tokio::test]
async fn active_connect_offline_and_unknown_fail_closed_without_offer_or_reserve() {
    for (status, expected_code) in [
        (ResolveStatus::Offline, NetworkErrorCode::PeerOffline as i32),
        (ResolveStatus::Unknown, NetworkErrorCode::RelayError as i32),
    ] {
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        let control = StubControl::new(status, None);
        *state.relay.control.write().await = Some(control.clone());
        control.observe_session_ownership(Arc::clone(&state));

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await;

        assert!(
            matches!(result, Err(ref error) if error.code == expected_code),
            "{status:?} must remain authoritative after Stage A: {result:?}"
        );
        assert_eq!(control.resolve_calls(), 1);
        assert!(
            control.first_resolve_saw_owned_session(),
            "{status:?} Resolve must observe the local Session owner"
        );
        assert_eq!(control.connectivity_calls(), 0);
        assert_eq!(control.reserve_calls(), 0);
        assert_eq!(control.call_order(), vec!["resolve"]);
        assert_eq!(
            state.connection_sessions.current_session_id("peer-b").await,
            None,
            "{status:?} must retire the Session before any Offer or ReserveRelay"
        );
    }
}

#[tokio::test]
async fn direct_failure_negative_stage_c_gates_do_not_reserve_relay() {
    for (class, e2ee_policy, label) in [
        (
            CommunicationClass::ReliableMessage,
            network_protocol::E2eePolicy::Disabled,
            "E2EE disabled",
        ),
        (
            CommunicationClass::UnreliableDatagram,
            network_protocol::E2eePolicy::Required,
            "unsupported Relay capability",
        ),
    ] {
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        state
            .peers
            .write()
            .await
            .get_mut("peer-b")
            .expect("configured peer")
            .e2ee_policy = e2ee_policy;
        let control = StubControl::new(
            ResolveStatus::Ready,
            Some(stage_c_ready_unreachable_direct_snapshot()),
        );
        *state.relay.control.write().await = Some(control.clone());
        control.observe_session_ownership(Arc::clone(&state));

        let result = tokio::time::timeout(
            Duration::from_secs(6),
            ConnectivityAttemptCoordinator::new(Arc::clone(&state))
                .connect_with_class("peer-b", class),
        )
        .await
        .expect("Direct failure boundary must remain bounded");

        assert!(result.is_err(), "{label} must fail closed: {result:?}");
        assert_eq!(control.resolve_calls(), 1, "{label} Resolve count");
        assert_eq!(control.connectivity_calls(), 1, "{label} Offer count");
        assert_eq!(control.reserve_calls(), 0, "{label} ReserveRelay count");
        assert_eq!(control.call_order(), vec!["resolve", "offer"]);
        assert!(
            control.first_resolve_saw_owned_session(),
            "{label} Direct attempt must own a Session before Resolve"
        );
        assert_eq!(
            state.connection_sessions.current_session_id("peer-b").await,
            None,
            "{label} Direct failure must retire its Session when Stage C is ineligible"
        );
    }
}

#[tokio::test]
async fn expired_stage_c_budget_skips_reserve_relay() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "expired-stage-c",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() - Duration::from_millis(1),
        )
        .await;

    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "an expired Direct budget must fail before ReserveRelay: {result:?}"
    );
    assert_eq!(control.reserve_calls(), 0);
    assert!(control.call_order().is_empty());
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(session_id),
        "the helper does not own cleanup before reservation admission"
    );
    state.fail_session(peer_id, session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        None
    );
}

#[tokio::test]
async fn active_connect_resolve_error_retires_owned_session_before_offer() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    *state.local_discovery.write().await = Some(Arc::new(
        crate::discovery::LocalDiscoveryManager::with_epoch(31, 32, 4),
    ));
    let control = StubControl::error();
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "Resolve transport error must fail closed: {result:?}"
    );
    assert_eq!(control.resolve_calls(), 1);
    assert!(control.first_resolve_saw_owned_session());
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    assert_eq!(control.call_order(), vec!["resolve"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a failed control transaction must not leak its owned Session"
    );
}

#[tokio::test]
async fn invalid_resolve_candidate_snapshot_retires_owned_session() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let duplicate = Candidate::new(
        "127.0.0.1:41030".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "duplicate-candidate".into(),
    )
    .with_generation(1);
    let advertisement = serde_json::to_vec(&duplicate.advertisement()).expect("candidate");
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 21, low: 22 }),
            revision: 1,
            transport_capabilities: vec![network_relay::v2::TransportCapability::Quic as i32],
            candidate_bundle: Some(network_relay::v2::CandidateBundle {
                candidates: vec![advertisement.clone(), advertisement],
            }),
            published_at_ms: 0,
        }),
    );
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::InvalidArgument as i32),
        "duplicate candidate ids must be rejected: {result:?}"
    );
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "malformed discovery must not leak its local Session"
    );
}

#[tokio::test]
async fn cancelled_task_supervisor_retires_owned_session_after_offer() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));
    state.task_supervisor.cancel_root();

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "cancelled task supervisor must reject coordination admission: {result:?}"
    );
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "coordination task admission failure must retire its Session"
    );
}

#[tokio::test]
async fn relay_fallback_without_control_plane_fails_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    *state.relay.control.write().await = None;
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "missing-control",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "missing control plane must fail closed: {result:?}"
    );
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_rejects_an_unusable_control_plane_before_reservation() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_usable(false);
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "unusable-control",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.reserve_calls(), 0);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_maps_reservation_failure_and_retires_session() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "reserve-error",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.reserve_calls(), 1);
    assert_eq!(control.call_order(), vec!["reserve"]);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test(start_paused = true)]
async fn relay_fallback_maps_a_hanging_reservation_to_timeout() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::timeout();
    *state.relay.control.write().await = Some(control.clone());
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        coordinator_for(&task_state)
            .connect_relay_fallback(
                peer_id,
                session_id,
                &peer,
                "reserve-timeout",
                crate::connect::CAPABILITY_RELIABLE_MESSAGE,
                Instant::now() + Duration::from_secs(10),
            )
            .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(RELAY_RESERVE_TIMEOUT + Duration::from_millis(1)).await;
    let result = task.await.expect("reservation task");
    assert!(
        matches!(
            result,
            Err(ref error) if error.code == NetworkErrorCode::Timeout as i32
        ),
        "unexpected hanging reservation result: {result:?}"
    );
    assert_eq!(control.reserve_calls(), 1);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_retires_session_when_data_plane_cannot_start() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_relay_reservation(network_relay::v2::RelayReserveResponse {
        request_id: 1,
        attempt_id: "data-failure".into(),
        reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        expires_at_ms: 0,
        local_token: vec![0; 32],
    });
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "data-failure",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.call_order(), vec!["reserve"]);
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        None,
        "data-plane admission failure must retire its Session"
    );
}

#[tokio::test]
async fn connect_wrapper_and_missing_control_plane_fail_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    *state.relay.control.write().await = None;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let result = coordinator
        .connect("peer-b")
        .await
        .expect_err("connect wrapper must use the authoritative control gate");
    assert_eq!(result.code, NetworkErrorCode::RelayError as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "missing control must not reserve a Session"
    );
}

#[tokio::test]
async fn session_cleanup_guard_retires_an_unattached_attempt() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    let guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-b", session_id);
    drop(guard);
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state
                .connection_sessions
                .current_session_id("peer-b")
                .await
                .is_none()
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cleanup guard should retire its session");
}

#[tokio::test]
async fn coordination_spawn_fails_closed_when_runtime_supervisor_is_stopping() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    state.task_supervisor.cancel_root();
    let coordination = ConnectivityAttemptStart::new(
        ResolvePeerResponse {
            request_id: 1,
            status: ResolveStatus::Ready as i32,
            discovery: None,
            retry_after_ms: 0,
        },
        async { Err(RelayError::NotConnected) },
    );
    let attempt = Arc::new(Mutex::new(ConnectivityAttempt::with_connect_window(
        "stopped-coordination",
        "peer-b",
        NatRuntimeEpoch { high: 0, low: 0 },
        SystemTime::now(),
        DIRECT_CONNECT_WINDOW,
    )));
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    assert!(coordinator
        .spawn_coordination(
            coordination,
            "peer-b".into(),
            "stopped-coordination".into(),
            attempt,
            Vec::new(),
            None,
        )
        .is_err());
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn local_candidate_collection_uses_the_bounded_path_manager_snapshot() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let manager = Arc::new(PathManager::new());
    let candidate = Candidate::new(
        "192.168.1.24:42024".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "local-candidate".into(),
    );
    manager.add_candidates(vec![candidate.clone()]).await;
    *state.local_path_manager.write().await = Some(manager);
    let candidates = collect_local_candidates(Arc::clone(&state)).await;
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].candidate_id, candidate.candidate_id);
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
    state
        .ready_session_index
        .register(peer_id, None, DEFAULT_CONNECTION_CAPABILITY, session_id);

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

/// Test-local gate that keeps a real coordinator inside Stage B after its
/// Resolve/Offer evidence has been recorded.  It makes the reconnect tests
/// deterministic without adding a production injection point.
struct StubOfferGate {
    started: tokio::sync::Notify,
    release: tokio::sync::Notify,
    hold: std::sync::atomic::AtomicBool,
    started_flag: std::sync::atomic::AtomicBool,
}

impl StubOfferGate {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            started: tokio::sync::Notify::new(),
            release: tokio::sync::Notify::new(),
            hold: std::sync::atomic::AtomicBool::new(false),
            started_flag: std::sync::atomic::AtomicBool::new(false),
        })
    }

    fn hold(&self) {
        self.hold.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    async fn wait_started(&self) {
        loop {
            if self.started_flag.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            let notified = self.started.notified();
            if self.started_flag.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }

    fn release(&self) {
        self.hold.store(false, std::sync::atomic::Ordering::SeqCst);
        self.release.notify_one();
    }

    async fn wait_if_held(&self) {
        if self.hold.load(std::sync::atomic::Ordering::SeqCst) {
            self.started_flag
                .store(true, std::sync::atomic::Ordering::SeqCst);
            self.started.notify_one();
            self.release.notified().await;
        }
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
    not_ready_once: std::sync::atomic::AtomicBool,
    usable: std::sync::atomic::AtomicBool,
    connectivity_answer: std::sync::Mutex<Option<network_relay::v2::ConnectivityAnswer>>,
    relay_reservation: std::sync::Mutex<Option<network_relay::v2::RelayReserveResponse>>,
    reserve_at: std::sync::Mutex<Option<Instant>>,
    calls: std::sync::Mutex<Vec<&'static str>>,
    call_times: std::sync::Mutex<Vec<(&'static str, Instant)>>,
    attempt_id_target: std::sync::Mutex<Option<Arc<std::sync::Mutex<Option<String>>>>>,
    ownership_state: std::sync::Mutex<Option<Arc<RuntimeState>>>,
    first_resolve_saw_owned_session: Arc<std::sync::atomic::AtomicBool>,
    offer_gate: Arc<StubOfferGate>,
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
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
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
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
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
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
        })
    }

    fn observe_session_ownership(&self, state: Arc<RuntimeState>) {
        *self
            .ownership_state
            .lock()
            .expect("stub ownership state lock") = Some(state);
    }

    fn observe_attempt_id(&self, target: Arc<std::sync::Mutex<Option<String>>>) {
        *self
            .attempt_id_target
            .lock()
            .expect("stub attempt id target lock") = Some(target);
    }

    fn return_not_ready_once(&self) {
        self.not_ready_once
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    fn set_usable(&self, usable: bool) {
        self.usable
            .store(usable, std::sync::atomic::Ordering::SeqCst);
    }

    fn set_connectivity_answer(&self, answer: network_relay::v2::ConnectivityAnswer) {
        *self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock") = Some(answer);
    }

    fn set_relay_reservation(&self, reservation: network_relay::v2::RelayReserveResponse) {
        *self
            .relay_reservation
            .lock()
            .expect("stub relay reservation lock") = Some(reservation);
    }

    fn hold_offer(&self) {
        self.offer_gate.hold();
    }

    async fn wait_offer_started(&self) {
        self.offer_gate.wait_started().await;
    }

    fn release_offer(&self) {
        self.offer_gate.release();
    }

    fn first_resolve_saw_owned_session(&self) -> bool {
        self.first_resolve_saw_owned_session
            .load(std::sync::atomic::Ordering::SeqCst)
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

    fn reserve_at(&self) -> Option<Instant> {
        *self.reserve_at.lock().expect("reserve timestamp lock")
    }

    fn call_times(&self) -> Vec<(&'static str, Instant)> {
        self.call_times
            .lock()
            .expect("stub call timestamp lock")
            .clone()
    }

    fn record_call(&self, name: &'static str) {
        self.calls.lock().expect("stub call log lock").push(name);
        self.call_times
            .lock()
            .expect("stub call timestamp lock")
            .push((name, Instant::now()));
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
            dyn std::future::Future<Output = Result<network_relay::v2::DiscoveryAck, RelayError>>
                + Send
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
        self.record_call("resolve");
        self.resolve_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let first_resolve = self.resolve_calls() == 1;
        let status = self.status;
        let not_ready_once = self
            .not_ready_once
            .load(std::sync::atomic::Ordering::SeqCst)
            && first_resolve;
        let status = if not_ready_once {
            ResolveStatus::NotReady
        } else {
            status
        };
        let discovery = if not_ready_once {
            None
        } else {
            self.discovery.clone()
        };
        let resolve_error = self.resolve_error;
        let resolve_never = self.resolve_never;
        let ownership_state = self
            .ownership_state
            .lock()
            .expect("stub ownership state lock")
            .clone();
        let first_resolve_saw_owned_session = Arc::clone(&self.first_resolve_saw_owned_session);
        Box::pin(async move {
            if first_resolve {
                if let Some(state) = ownership_state {
                    if state
                        .connection_sessions
                        .current_session_id("peer-b")
                        .await
                        .is_some()
                    {
                        first_resolve_saw_owned_session
                            .store(true, std::sync::atomic::Ordering::SeqCst);
                    }
                }
            }
            if resolve_error {
                return Err(RelayError::NotConnected);
            }
            if resolve_never {
                return std::future::pending::<
                    Result<network_relay::v2::ResolvePeerResponse, RelayError>,
                >()
                .await;
            }
            Ok(network_relay::v2::ResolvePeerResponse {
                request_id: 1,
                status: status as i32,
                discovery,
                retry_after_ms: 500,
            })
        })
    }

    fn is_usable(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + '_>> {
        let usable = self.usable.load(std::sync::atomic::Ordering::SeqCst);
        Box::pin(async move { usable })
    }

    fn begin_connectivity_attempt(
        &self,
        attempt_id: String,
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
        if let Some(target) = self
            .attempt_id_target
            .lock()
            .expect("stub attempt id target lock")
            .clone()
        {
            *target.lock().expect("Stage C attempt id lock") = Some(attempt_id.clone());
        }
        let mut answer = self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock")
            .clone();
        if let Some(answer) = answer.as_mut() {
            // The production control client binds the answer waiter to the
            // freshly generated attempt id.  Keep the fixture convenient for
            // success-path tests while still allowing an explicit id to test
            // stale-answer rejection.
            if answer.attempt_id.is_empty() {
                answer.attempt_id = attempt_id;
            }
        }
        let offer_gate = Arc::clone(&self.offer_gate);
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
            self.record_call("offer");
            self.connectivity_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            offer_gate.wait_if_held().await;
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
        self.record_call("offer");
        self.connectivity_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let answer = self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock")
            .clone();
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
        *self.reserve_at.lock().expect("reserve timestamp lock") = Some(Instant::now());
        self.record_call("reserve");
        self.reserve_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let reservation = self
            .relay_reservation
            .lock()
            .expect("stub relay reservation lock")
            .clone();
        let reserve_never = self.resolve_never;
        Box::pin(async move {
            if reserve_never {
                return std::future::pending::<
                    Result<network_relay::v2::RelayReserveResponse, RelayError>,
                >()
                .await;
            }
            reservation.ok_or(RelayError::NotConnected)
        })
    }
}
