use super::*;
use network_relay::v2::ResolveStatus;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use std::sync::Mutex;
use tokio::sync::mpsc::unbounded_channel;

/// 忠实控制面 mock：记录每次发布并返回可配置结果。
struct MockControlPlane {
    mode: Mutex<MockMode>,
    attempts: AtomicUsize,
    published_snapshots: Mutex<Vec<DiscoverySnapshot>>,
    request_ids: Mutex<Vec<u64>>,
    attempt_instants: Mutex<Vec<tokio::time::Instant>>,
    usable: AtomicBool,
}

#[derive(Clone)]
enum MockMode {
    AlwaysOk,
    AlwaysFail,
    /// 前 N 次失败（模拟 ACK 丢失），之后成功。
    FailThenOk(usize),
    /// 返回与发布者 request_id 不匹配的 ACK（echoes_request_id=true 时被忽略）。
    MismatchedRequestId,
    /// ACK arrives after the publisher-level timeout.
    Delayed(Duration),
}

impl MockControlPlane {
    fn new(mode: MockMode) -> Arc<Self> {
        Arc::new(Self {
            mode: Mutex::new(mode),
            attempts: AtomicUsize::new(0),
            published_snapshots: Mutex::new(Vec::new()),
            request_ids: Mutex::new(Vec::new()),
            attempt_instants: Mutex::new(Vec::new()),
            usable: AtomicBool::new(true),
        })
    }

    fn attempts(&self) -> usize {
        self.attempts.load(Ordering::SeqCst)
    }

    fn published(&self) -> Vec<DiscoverySnapshot> {
        self.published_snapshots.lock().unwrap().clone()
    }

    fn request_ids(&self) -> Vec<u64> {
        self.request_ids.lock().unwrap().clone()
    }

    fn attempt_instants(&self) -> Vec<tokio::time::Instant> {
        self.attempt_instants.lock().unwrap().clone()
    }
}

impl DiscoveryControlPlane for MockControlPlane {
    fn publish_discovery(
        &self,
        request_id: u64,
        snapshot: DiscoverySnapshot,
    ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
        let attempt = self.attempts.fetch_add(1, Ordering::SeqCst) + 1;
        self.published_snapshots
            .lock()
            .unwrap()
            .push(snapshot.clone());
        self.request_ids.lock().unwrap().push(request_id);
        self.attempt_instants
            .lock()
            .unwrap()
            .push(tokio::time::Instant::now());
        let mode = self.mode.lock().unwrap().clone();
        let ack = DiscoveryAck {
            request_id,
            runtime_epoch: snapshot.runtime_epoch.clone(),
            revision: snapshot.revision,
        };
        Box::pin(async move {
            match mode {
                MockMode::AlwaysOk => Ok(ack),
                MockMode::AlwaysFail => Err(RelayError::Timeout("mock ack lost".into())),
                MockMode::FailThenOk(failures) => {
                    if attempt <= failures {
                        Err(RelayError::Timeout("mock ack lost".into()))
                    } else {
                        Ok(ack)
                    }
                }
                MockMode::MismatchedRequestId => Ok(DiscoveryAck {
                    request_id: request_id.wrapping_add(1),
                    ..ack
                }),
                MockMode::Delayed(delay) => {
                    tokio::time::sleep(delay).await;
                    Ok(ack)
                }
            }
        })
    }

    fn resolve_peer(
        &self,
        _target_device_id: &str,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>> {
        // publisher 测试不解析对端。
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

fn manager_at_revision(revision: u32) -> LocalDiscoveryManager {
    let manager = LocalDiscoveryManager::with_epoch(1, 2, 1);
    for _ in 1..revision {
        manager.bump_revision();
    }
    manager
}

fn unconnected_control_client() -> Arc<RelayControlClient> {
    Arc::new(
        RelayControlClient::new(
            "ws://127.0.0.1:9".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid unconnected control client"),
    )
}

#[tokio::test(start_paused = true)]
async fn publish_success_marks_published_and_uses_the_current_snapshot() {
    let manager = manager_at_revision(3);
    let epoch = manager.runtime_epoch();
    let mock = MockControlPlane::new(MockMode::AlwaysOk);
    let publisher = DiscoveryPublisher::new(mock.clone());

    let outcome = publisher.publish(&manager, "test").await;

    assert_eq!(outcome, PublishOutcome::Published);
    assert_eq!(
        manager.state(),
        crate::discovery::LocalDiscoveryState::Published
    );
    // 只发布了一次，且发布的是当前 revision（epoch 不变）。
    assert_eq!(mock.attempts(), 1);
    let published = mock.published().pop().expect("snapshot");
    assert_eq!(published.revision, 3);
    assert_eq!(published.runtime_epoch.as_ref(), Some(&epoch));
    assert_eq!(
        published.runtime_epoch.as_ref(),
        Some(&manager.runtime_epoch())
    );
}

#[tokio::test(start_paused = true)]
async fn publish_ack_lost_retries_then_succeeds() {
    let manager = manager_at_revision(2);
    let mock = MockControlPlane::new(MockMode::FailThenOk(1));
    // 用零退避让「ACK 丢失 → 重试 → 成功」测试快速确定性地收敛。
    let publisher = DiscoveryPublisher::with_config(
        mock.clone(),
        vec![Duration::ZERO; 1],
        DISCOVERY_PUBLISH_MAX_ATTEMPTS,
        DISCOVERY_PUBLISH_TIMEOUT,
    );

    let outcome = publisher.publish(&manager, "test").await;

    assert_eq!(outcome, PublishOutcome::Published);
    assert_eq!(
        manager.state(),
        crate::discovery::LocalDiscoveryState::Published
    );
    assert_eq!(mock.attempts(), 2, "第一次 ACK 丢失，第二次成功");
    // 每次发布有独立的 request_id。
    let request_ids = mock.request_ids();
    assert_ne!(request_ids[0], request_ids[1]);
}

#[tokio::test(start_paused = true)]
async fn publish_degrades_after_max_attempts_with_bounded_backoff() {
    let manager = Arc::new(manager_at_revision(1));
    let mock = MockControlPlane::new(MockMode::AlwaysFail);
    let publisher = Arc::new(DiscoveryPublisher::new(mock.clone()));

    let manager_task = Arc::clone(&manager);
    let publisher_task = Arc::clone(&publisher);
    let task = tokio::spawn(async move { publisher_task.publish(&manager_task, "test").await });

    // 推进时间直到 publish 完成；总退避 = 500 + 1000 + 2000 + 4000 = 7500ms。
    let start = tokio::time::Instant::now();
    loop {
        tokio::time::advance(Duration::from_millis(500)).await;
        tokio::task::yield_now().await;
        if task.is_finished() {
            break;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "publish did not terminate within backoff budget"
        );
    }
    let outcome = task.await.expect("publish task panicked");
    assert_eq!(outcome, PublishOutcome::Degraded);
    assert_eq!(
        manager.state(),
        crate::discovery::LocalDiscoveryState::Degraded
    );
    assert_eq!(mock.attempts(), DISCOVERY_PUBLISH_MAX_ATTEMPTS);

    // 退避调度：每次尝试间隔依次为 500ms / 1s / 2s / 4s（第 5 个 4s 是调度上限）。
    let instants = mock.attempt_instants();
    let deltas = instants
        .windows(2)
        .map(|pair| pair[1] - pair[0])
        .collect::<Vec<_>>();
    assert_eq!(
        deltas,
        vec![
            Duration::from_millis(500),
            Duration::from_millis(1000),
            Duration::from_millis(2000),
            Duration::from_millis(4000),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn publish_applies_the_full_500ms_1s_2s_4s_4s_schedule() {
    // 允许更多尝试（6 次）以完整消费 5 个退避值：500ms / 1s / 2s / 4s / 4s。
    let manager = Arc::new(manager_at_revision(1));
    let mock = MockControlPlane::new(MockMode::AlwaysFail);
    let publisher = Arc::new(DiscoveryPublisher::with_config(
        mock.clone(),
        DISCOVERY_PUBLISH_RETRY_BACKOFF_MS
            .iter()
            .map(|ms| Duration::from_millis(*ms))
            .collect(),
        6,
        DISCOVERY_PUBLISH_TIMEOUT,
    ));

    let manager_task = Arc::clone(&manager);
    let publisher_task = Arc::clone(&publisher);
    let task = tokio::spawn(async move { publisher_task.publish(&manager_task, "test").await });

    // 总退避 = 500 + 1000 + 2000 + 4000 + 4000 = 11500ms。
    let start = tokio::time::Instant::now();
    loop {
        tokio::time::advance(Duration::from_millis(500)).await;
        tokio::task::yield_now().await;
        if task.is_finished() {
            break;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "publish did not terminate within backoff budget"
        );
    }
    let outcome = task.await.expect("publish task panicked");
    assert_eq!(outcome, PublishOutcome::Degraded);
    assert_eq!(mock.attempts(), 6);

    let instants = mock.attempt_instants();
    let deltas = instants
        .windows(2)
        .map(|pair| pair[1] - pair[0])
        .collect::<Vec<_>>();
    assert_eq!(
        deltas,
        vec![
            Duration::from_millis(500),
            Duration::from_millis(1000),
            Duration::from_millis(2000),
            Duration::from_millis(4000),
            Duration::from_millis(4000),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn publish_ignores_ack_with_mismatched_request_id() {
    let manager = manager_at_revision(1);
    // 忠实 sink（echoes_request_id=true）返回错误的 request_id → 视为失败。
    let mock = MockControlPlane::new(MockMode::MismatchedRequestId);
    let publisher = DiscoveryPublisher::with_config(
        mock.clone(),
        vec![Duration::ZERO; DISCOVERY_PUBLISH_MAX_ATTEMPTS],
        DISCOVERY_PUBLISH_MAX_ATTEMPTS,
        DISCOVERY_PUBLISH_TIMEOUT,
    );

    let outcome = publisher.publish(&manager, "test").await;

    assert_eq!(outcome, PublishOutcome::Degraded);
    assert_eq!(
        manager.state(),
        crate::discovery::LocalDiscoveryState::Degraded
    );
    assert_eq!(mock.attempts(), DISCOVERY_PUBLISH_MAX_ATTEMPTS);
}

#[tokio::test(start_paused = true)]
async fn publish_returns_unavailable_when_control_plane_is_down() {
    let manager = manager_at_revision(1);
    let mock = MockControlPlane::new(MockMode::AlwaysOk);
    mock.usable.store(false, Ordering::SeqCst);
    let publisher = DiscoveryPublisher::new(mock.clone());

    let outcome = publisher.publish(&manager, "test").await;

    assert_eq!(outcome, PublishOutcome::Unavailable);
    assert_eq!(mock.attempts(), 0, "不可用时不应发送任何帧");
    // 不可用不是「有限重试耗尽」，但当前实现标记 Degraded；重连后重新触发。
    assert_eq!(
        manager.state(),
        crate::discovery::LocalDiscoveryState::Degraded
    );
}

#[test]
fn publish_constants_are_centralized_and_match_design() {
    // §9：500ms / 1s / 2s / 4s / 4s，最多重试 5 次。
    assert_eq!(
        DISCOVERY_PUBLISH_RETRY_BACKOFF_MS,
        [500, 1000, 2000, 4000, 4000]
    );
    assert_eq!(DISCOVERY_PUBLISH_MAX_ATTEMPTS, 5);
}

#[tokio::test(start_paused = true)]
async fn start_retry_loop_uses_the_task_supervisor() {
    // 构造一个可用的 RuntimeState 以验证 start_retry_loop 可被调用（spawn 成功）。
    let (event_tx, _event_rx) = unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let manager = Arc::new(manager_at_revision(1));
    let mock = MockControlPlane::new(MockMode::AlwaysOk);
    let publisher = DiscoveryPublisher::new(mock);
    let task_id = publisher.start_retry_loop(&state, manager, "test");
    assert!(task_id.is_some());
    state.task_supervisor.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn publish_timeout_is_counted_as_a_failed_attempt() {
    let manager = manager_at_revision(1);
    let mock = MockControlPlane::new(MockMode::Delayed(Duration::from_secs(1)));
    let publisher = DiscoveryPublisher::with_config(
        mock.clone(),
        vec![Duration::ZERO],
        1,
        Duration::from_millis(10),
    );
    let task = tokio::spawn(async move { publisher.publish(&manager, "timeout").await });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_millis(11)).await;
    tokio::task::yield_now().await;
    assert_eq!(task.await.unwrap(), PublishOutcome::Degraded);
    assert_eq!(mock.attempts(), 1);
}

#[test]
fn publisher_ack_and_backoff_validation_reject_stale_metadata() {
    let mock = MockControlPlane::new(MockMode::AlwaysOk);
    let publisher = DiscoveryPublisher::with_config(
        mock,
        vec![Duration::from_millis(7), Duration::from_millis(11)],
        3,
        Duration::from_secs(1),
    );
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 1, low: 2 }),
        revision: 4,
        ..Default::default()
    };
    let valid = DiscoveryAck {
        request_id: 9,
        runtime_epoch: snapshot.runtime_epoch.clone(),
        revision: 4,
    };
    assert!(publisher.ack_is_valid(9, &snapshot, &valid));
    assert!(!publisher.ack_is_valid(
        9,
        &snapshot,
        &DiscoveryAck {
            revision: 3,
            ..valid.clone()
        }
    ));
    assert!(!publisher.ack_is_valid(
        9,
        &snapshot,
        &DiscoveryAck {
            runtime_epoch: Some(RuntimeEpoch { high: 8, low: 9 }),
            ..valid.clone()
        }
    ));
    assert_eq!(publisher.backoff_for(1), Duration::from_millis(7));
    assert_eq!(publisher.backoff_for(2), Duration::from_millis(11));
    assert_eq!(publisher.backoff_for(99), Duration::from_millis(11));

    let empty_sink = MockControlPlane::new(MockMode::AlwaysOk);
    let empty = DiscoveryPublisher::with_config(empty_sink, Vec::new(), 1, Duration::from_secs(1));
    assert_eq!(empty.backoff_for(1), Duration::ZERO);
}

#[tokio::test]
async fn default_control_plane_operations_fail_closed() {
    let mock = MockControlPlane::new(MockMode::AlwaysOk);
    let epoch = RuntimeEpoch { high: 1, low: 1 };
    assert!(matches!(
        mock.start_connectivity_attempt(
            "attempt".into(),
            "peer".into(),
            "device".into(),
            epoch.clone(),
            1,
            None,
        )
        .await,
        Err(RelayError::NotConnected)
    ));
    assert!(matches!(
        mock.begin_connectivity_attempt(
            "attempt".into(),
            "peer".into(),
            "device".into(),
            epoch,
            1,
            None,
        )
        .await,
        Err(RelayError::NotConnected)
    ));
    assert!(matches!(
        mock.reserve_relay("attempt".into(), "peer".into(), 60)
            .await,
        Err(RelayError::NotConnected)
    ));
    assert!(matches!(
        mock.signal_webrtc(
            "realtime",
            "peer",
            network_relay::v2::RealtimeSignalKind::Offer,
            1,
            b"payload",
        )
        .await,
        Err(RelayError::NotConnected)
    ));
    assert_eq!(mock.ready_presence_ttl(), None);
}

#[tokio::test]
async fn relay_control_plane_adapter_forwards_operations_and_preserves_errors() {
    let control = unconnected_control_client();
    let plane: &dyn DiscoveryControlPlane = control.as_ref();
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 1, low: 1 }),
        revision: 1,
        ..Default::default()
    };
    assert!(plane.publish_discovery(1, snapshot).await.is_err());
    assert!(plane.resolve_peer("peer-a").await.is_err());
    assert!(!plane.is_usable().await);
    assert_eq!(plane.ready_presence_ttl(), None);
    assert!(plane
        .start_connectivity_attempt(
            "attempt".into(),
            "peer-a".into(),
            "device-a".into(),
            RuntimeEpoch { high: 1, low: 1 },
            1,
            None,
        )
        .await
        .is_err());
    assert!(plane
        .begin_connectivity_attempt(
            "attempt".into(),
            "peer-a".into(),
            "device-a".into(),
            RuntimeEpoch { high: 1, low: 1 },
            1,
            None,
        )
        .await
        .is_err());
    assert!(plane
        .reserve_relay("attempt".into(), "peer-a".into(), 60)
        .await
        .is_err());
    assert!(plane
        .signal_webrtc(
            "realtime",
            "peer-a",
            network_relay::v2::RealtimeSignalKind::Offer,
            1,
            b"payload",
        )
        .await
        .is_err());
}
