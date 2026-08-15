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
mod tests {
    use super::*;
    use network_nat::Candidate;
    use std::sync::atomic::AtomicU16;
    use std::sync::Arc;
    use tokio::sync::mpsc::unbounded_channel;

    fn test_state() -> std::sync::Arc<crate::runtime::RuntimeState> {
        let (event_tx, _event_rx) = unbounded_channel();
        std::sync::Arc::new(crate::runtime::RuntimeState::new(
            event_tx,
            Arc::new(AtomicU16::new(0)),
        ))
    }

    #[test]
    fn local_transport_capabilities_is_a_fixed_supported_set() {
        let capabilities = local_transport_capabilities();
        assert!(capabilities.contains(&TransportCapability::Quic));
        assert!(capabilities.contains(&TransportCapability::Tcp));
        // 集合内无重复。
        let mut seen = std::collections::HashSet::new();
        for capability in &capabilities {
            assert!(
                seen.insert(*capability),
                "duplicate capability {capability:?}"
            );
        }
    }

    #[tokio::test]
    async fn candidate_bundle_from_local_reads_the_local_path_manager() {
        let state = test_state();
        // 未配置 local_path_manager → 空 bundle。
        let bundle = candidate_bundle_from_local(&state).await;
        assert!(bundle.candidates.is_empty());
    }

    #[test]
    fn build_local_snapshot_maps_capabilities_to_i32() {
        let epoch = RuntimeEpoch { high: 1, low: 2 };
        let bundle = CandidateBundle {
            candidates: vec![vec![1, 2, 3]],
        };
        let snapshot = build_local_snapshot(
            &epoch,
            4,
            &[TransportCapability::Quic, TransportCapability::RelayData],
            &bundle,
        );
        assert_eq!(snapshot.runtime_epoch.as_ref(), Some(&epoch));
        assert_eq!(snapshot.revision, 4);
        assert_eq!(
            snapshot.transport_capabilities,
            vec![
                TransportCapability::Quic as i32,
                TransportCapability::RelayData as i32
            ]
        );
        assert_eq!(
            snapshot
                .candidate_bundle
                .as_ref()
                .expect("bundle")
                .candidates,
            vec![vec![1, 2, 3]]
        );
    }

    #[test]
    fn candidate_serialization_is_opaque_bytes() {
        // Candidate 广告序列化为不透明 JSON 字节；Relay 不解析。
        let candidate = Candidate::new(
            "127.0.0.1:45000".parse().unwrap(),
            network_nat::CandidateKind::Lan,
            "test0".into(),
        );
        let bytes = serde_json::to_vec(&candidate.advertisement()).expect("serialize");
        assert!(!bytes.is_empty());
        let decoded: serde_json::Value = serde_json::from_slice(&bytes).expect("decode");
        assert_eq!(decoded["interface"], "test0");
    }
}
