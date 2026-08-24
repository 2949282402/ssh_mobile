//! transport-network v2：Discovery Resolver（设计 §10/§28/§29）。
//!
//! 薄封装 `RelayControlClient::resolve_peer`：把 Resolve 的 4-state
//! （READY / OFFLINE / NOT_READY / UNKNOWN）映射为类型化结果 [`ResolvedPeer`]，
//! 供 Step 6 的 ConnectivityAttemptCoordinator 消费。本步骤只定义类型 + 调用路径，
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
    /// fail-open / fail-closed（Step 6 ConnectivityAttemptCoordinator）。
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
        Ok(ResolveStatus::Ready) => match response.discovery {
            Some(discovery) => ResolvedPeer::Ready {
                discovery: Some(discovery),
            },
            // READY without a discovery snapshot is not authoritative. Keep
            // the connection gate fail-closed instead of manufacturing a
            // usable peer from presence alone.
            None => ResolvedPeer::Unknown {
                retry_after_ms: response.retry_after_ms,
            },
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
#[path = "../tests/discovery/resolver.rs"]
mod tests;
