//! transport-network v2：Discovery Resolver（设计 §10/§28/§29）。
//!
//! 薄封装 `RelayControlClient::resolve_peer`：把 Resolve 的 4-state
//! （READY / OFFLINE / NOT_READY / UNKNOWN）映射为类型化结果 [`ResolvedPeer`]，
//! 供 Step 6 的 ConnectionOrchestrator 消费。本步骤只定义类型 + 调用路径，
//! 不接线到连接主链（§11 在 Step 6 落地）。

use std::sync::Arc;

use network_relay::v2::{DiscoverySnapshot, ResolvePeerResponse, ResolveStatus};
use network_relay::RelayError;

use super::publisher::DiscoveryControlPlane;

/// Resolve 4-state 的类型化结果（§10）。
///
/// | 状态 | 含义 | 客户端行为 |
/// |---|---|---|
/// | `Ready` | Presence + Discovery 均有效且 owner 一致 | 可以建连 |
/// | `Offline` | Presence 确定不存在 | 返回 PeerOffline |
/// | `NotReady` | Presence 在线，但 Discovery 尚未可靠发布 | 可短暂重试 Resolve |
/// | `Unknown` | Redis / Backend 状态无法可靠判断 | 返回 ControlUnavailable |
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ResolvedPeer {
    /// `READY`：唯一允许生成 ConnectivityAttempt 的状态。
    Ready {
        /// 对端当前 Discovery（含 runtime_epoch / revision / 候选）。
        discovery: Option<DiscoverySnapshot>,
    },
    /// `OFFLINE`：Presence 确定不存在。
    Offline,
    /// `NOT_READY`：Presence 在线但 Discovery 尚未可靠发布。
    NotReady {
        /// 服务端建议的重试等待（毫秒）。
        retry_after_ms: u32,
    },
    /// `UNKNOWN`：Redis / Backend 无法可靠判断。
    Unknown {
        /// 服务端建议的重试等待（毫秒）。
        retry_after_ms: u32,
    },
}

/// 按目标设备解析对端 Discovery 的类型化 resolver。
pub(crate) struct DiscoveryResolver {
    control: Arc<dyn DiscoveryControlPlane>,
}

impl DiscoveryResolver {
    #[allow(dead_code)] // forward path：Step 6 使用
    pub(crate) fn new(control: Arc<dyn DiscoveryControlPlane>) -> Self {
        Self { control }
    }

    /// 调用控制面 `resolve_peer` 并把 4-state 映射为 [`ResolvedPeer`]。
    ///
    /// 传输层错误（未连接 / 超时 / 协议错误）以 `Err` 返回，由调用方决定
    /// fail-open / fail-closed（Step 6 ConnectionOrchestrator）。
    #[allow(dead_code)] // forward path：Step 6 使用
    pub(crate) async fn resolve(&self, target_device_id: &str) -> Result<ResolvedPeer, RelayError> {
        let response = self.control.resolve_peer(target_device_id).await?;
        Ok(map_resolve_response(response))
    }
}

/// 把 ResolvePeerResponse 的 4-state 映射为类型化结果；未知/非法状态一律落到
/// `Unknown`（禁止「fail-open 但伪装成正常结果」——§10）。
#[allow(dead_code)] // forward path：Step 6 使用
fn map_resolve_response(response: ResolvePeerResponse) -> ResolvedPeer {
    match ResolveStatus::try_from(response.status) {
        Ok(ResolveStatus::Ready) => ResolvedPeer::Ready {
            discovery: response.discovery,
        },
        Ok(ResolveStatus::Offline) => ResolvedPeer::Offline,
        Ok(ResolveStatus::NotReady) => ResolvedPeer::NotReady {
            retry_after_ms: response.retry_after_ms,
        },
        // `Unspecified` / 未知 / 非法状态码都落到 UNKNOWN：禁止 fail-open 伪装成
        // 正常结果（§10）。
        Ok(ResolveStatus::Unspecified) | Ok(ResolveStatus::Unknown) | Err(_) => {
            ResolvedPeer::Unknown {
                retry_after_ms: response.retry_after_ms,
            }
        }
    }
}

#[cfg(test)]
mod tests {
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
        ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>>
        {
            self.resolve_calls.fetch_add(1, Ordering::SeqCst);
            let response = self.responses.lock().unwrap().pop().expect("stub response");
            Box::pin(async move { Ok(response) })
        }

        fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            let usable = self.usable.load(Ordering::SeqCst);
            Box::pin(async move { usable })
        }
    }

    fn response(
        status: ResolveStatus,
        discovery: Option<DiscoverySnapshot>,
    ) -> ResolvePeerResponse {
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
}
