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
