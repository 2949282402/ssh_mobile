//! transport-network v2：DiscoverySnapshot 构造（设计 §7/§28）。
//!
//! Snapshot 由三部分拼装：
//!
//! - `runtime_epoch + revision`：来自 [`LocalDiscoveryManager`]。
//! - `transport_capabilities`：来自本地传输 registry。当前 network-core 还没有
//!   独立的 TransportRegistry（§28 在 Step 6 落地），这里先提供固定的本地支持集合
//!   [`local_transport_capabilities`]，Step 6 换成 registry 查询。
//! - `candidate_bundle`：来自本地候选源（`local_path_manager`），候选是 opaque
//!   base64/JSON 字节，Relay 不解析（§32）。

use network_relay::v2::{
    CandidateBundle, DiscoverySnapshot, RuntimeEpoch, TransportCapability, MAX_DISCOVERY_CANDIDATES,
};

use crate::runtime::RuntimeState;

/// 当前运行时支持的传输能力（§16）。固定集合，直到 transport registry（§28）落地。
pub(crate) fn local_transport_capabilities() -> Vec<TransportCapability> {
    vec![
        TransportCapability::Quic,
        TransportCapability::Tcp,
        TransportCapability::UdpDatagram,
        TransportCapability::Webrtc,
        TransportCapability::RelayData,
    ]
}

/// 从本地 PathManager 读取候选并序列化为 opaque 字节 bundle。
///
/// 每个候选用 [`Candidate::advertisement`] 序列化为 JSON 字节；解码失败或超过
/// [`MAX_DISCOVERY_CANDIDATES`] 的条目被截断。Relay 只转发、不解析这些字节。
pub(crate) async fn candidate_bundle_from_local(state: &RuntimeState) -> CandidateBundle {
    let Some(manager) = state.local_path_manager.read().await.clone() else {
        return CandidateBundle {
            candidates: Vec::new(),
        };
    };
    let candidates = manager
        .ranked_candidates()
        .await
        .into_iter()
        .filter_map(|candidate| serde_json::to_vec(&candidate.advertisement()).ok())
        .filter(|bytes| !bytes.is_empty())
        .take(MAX_DISCOVERY_CANDIDATES)
        .collect();
    CandidateBundle { candidates }
}

/// 构造一个 DiscoverySnapshot（epoch + revision + capabilities + candidate_bundle）。
pub(crate) fn build_local_snapshot(
    runtime_epoch: &RuntimeEpoch,
    revision: u32,
    transport_capabilities: &[TransportCapability],
    candidate_bundle: &CandidateBundle,
) -> DiscoverySnapshot {
    DiscoverySnapshot {
        runtime_epoch: Some(runtime_epoch.clone()),
        revision,
        transport_capabilities: transport_capabilities
            .iter()
            .map(|cap| *cap as i32)
            .collect(),
        candidate_bundle: Some(candidate_bundle.clone()),
        published_at_ms: unix_timestamp_ms(),
    }
}

fn unix_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "../tests/discovery/snapshot.rs"]
mod tests;
