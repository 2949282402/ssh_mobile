use super::*;
use network_relay::v2::{DiscoveryAck, DiscoverySnapshot, RuntimeEpoch, TransportCapability};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

/// 固定返回预置 ResolvePeerResponse 的 mock 控制面。
struct StubControl {
    responses: Mutex<Vec<ResolvePeerResponse>>,
    resolve_calls: AtomicUsize,
    usable: AtomicBool,
}

impl StubControl {
    fn new(response: ResolvePeerResponse) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(vec![response]),
            resolve_calls: AtomicUsize::new(0),
            usable: AtomicBool::new(true),
        })
    }

    fn calls(&self) -> usize {
        self.resolve_calls.load(Ordering::SeqCst)
    }
}

impl DiscoveryControlPlane for StubControl {
    fn publish_discovery(
        &self,
        _request_id: u64,
        _snapshot: DiscoverySnapshot,
    ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
        Box::pin(async { Err(RelayError::NotConnected) })
    }

    fn resolve_peer(
        &self,
        _target_device_id: &str,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>> {
        self.resolve_calls.fetch_add(1, Ordering::SeqCst);
        let response = self.responses.lock().unwrap().pop().expect("stub response");
        Box::pin(async move { Ok(response) })
    }

    fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
        let usable = self.usable.load(Ordering::SeqCst);
        Box::pin(async move { usable })
    }
}

fn response(status: ResolveStatus, discovery: Option<DiscoverySnapshot>) -> ResolvePeerResponse {
    ResolvePeerResponse {
        request_id: 1,
        status: status as i32,
        discovery,
        retry_after_ms: 42,
    }
}

#[tokio::test]
async fn resolve_maps_ready_with_discovery() {
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 1, low: 2 }),
        revision: 7,
        transport_capabilities: vec![TransportCapability::Quic as i32],
        candidate_bundle: None,
        published_at_ms: 1234,
    };
    let control = StubControl::new(response(ResolveStatus::Ready, Some(snapshot.clone())));
    let resolver = DiscoveryResolver::new(control.clone());

    let resolved = resolver.resolve("peer-b").await.expect("resolve");
    assert_eq!(control.calls(), 1);
    assert_eq!(
        resolved,
        ResolvedPeer::Ready {
            discovery: Some(snapshot)
        }
    );
}

#[tokio::test]
async fn resolve_maps_offline() {
    let control = StubControl::new(response(ResolveStatus::Offline, None));
    let resolver = DiscoveryResolver::new(control.clone());
    assert_eq!(
        resolver.resolve("peer-b").await.expect("resolve"),
        ResolvedPeer::Offline
    );
}

#[tokio::test]
async fn resolve_maps_not_ready_with_retry_hint() {
    let control = StubControl::new(response(ResolveStatus::NotReady, None));
    let resolver = DiscoveryResolver::new(control.clone());
    assert_eq!(
        resolver.resolve("peer-b").await.expect("resolve"),
        ResolvedPeer::NotReady { retry_after_ms: 42 }
    );
}

#[tokio::test]
async fn resolve_maps_unknown_and_invalid_statuses_to_unknown() {
    let control = StubControl::new(response(ResolveStatus::Unknown, None));
    let resolver = DiscoveryResolver::new(control.clone());
    assert_eq!(
        resolver.resolve("peer-b").await.expect("resolve"),
        ResolvedPeer::Unknown { retry_after_ms: 42 }
    );

    // 非法/未知状态码也必须落到 Unknown，禁止 fail-open 伪装成正常结果（§10）。
    let bad = StubControl::new(ResolvePeerResponse {
        request_id: 1,
        status: 999, // 枚举外状态码
        discovery: None,
        retry_after_ms: 42,
    });
    let resolver = DiscoveryResolver::new(bad.clone());
    assert_eq!(
        resolver.resolve("peer-b").await.expect("resolve"),
        ResolvedPeer::Unknown { retry_after_ms: 42 }
    );
}
