use super::*;

#[test]
fn begin_epoch_produces_fresh_epoch_and_revision_one() {
    let first = LocalDiscoveryManager::begin_epoch();
    let second = LocalDiscoveryManager::begin_epoch();
    // 两个随机 epoch 必须不同（128-bit 碰撞概率可忽略）。
    assert_ne!(first.runtime_epoch(), second.runtime_epoch());
    assert_eq!(first.revision(), 1);
    assert_eq!(first.state(), LocalDiscoveryState::Idle);
    // high/low 至少构成一个非零的 128-bit 标识。
    let epoch = first.runtime_epoch();
    assert!(epoch.high != 0 || epoch.low != 0);
}

#[test]
fn bump_revision_increments_within_epoch() {
    let manager = LocalDiscoveryManager::begin_epoch();
    let epoch = manager.runtime_epoch();
    manager.bump_revision();
    manager.bump_revision();
    assert_eq!(manager.revision(), 3);
    // epoch 不变：同一次 runtime 生命周期内 revision 单调递增（§7）。
    assert_eq!(manager.runtime_epoch(), epoch);
    // 提升 revision 后回到 Idle，需要重新发布。
    assert_eq!(manager.state(), LocalDiscoveryState::Idle);
}

#[test]
fn snapshot_carries_epoch_revision_capabilities_and_candidates() {
    let manager =
        LocalDiscoveryManager::with_epoch(0x1122_3344_5566_7788, 0x99aa_bbcc_ddee_ff00, 7);
    manager.set_candidate_bundle(CandidateBundle {
        candidates: vec![b"candidate-a".to_vec(), b"candidate-b".to_vec()],
    });
    manager.set_transport_capabilities(vec![TransportCapability::Quic, TransportCapability::Tcp]);
    let snapshot = manager.snapshot();
    assert_eq!(
        snapshot.runtime_epoch.as_ref(),
        Some(&RuntimeEpoch {
            high: 0x1122_3344_5566_7788,
            low: 0x99aa_bbcc_ddee_ff00,
        })
    );
    assert_eq!(snapshot.revision, 7);
    assert_eq!(
        snapshot.transport_capabilities,
        vec![
            TransportCapability::Quic as i32,
            TransportCapability::Tcp as i32
        ]
    );
    let bundle = snapshot.candidate_bundle.expect("candidate bundle");
    assert_eq!(
        bundle.candidates,
        vec![b"candidate-a".to_vec(), b"candidate-b".to_vec()]
    );
    // 同一 epoch/revision 的 snapshot 应带非零发布时间。
    assert!(snapshot.published_at_ms != 0);
}

#[test]
fn state_transitions_follow_publish_lifecycle() {
    let manager = LocalDiscoveryManager::begin_epoch();
    manager.mark_publishing();
    assert_eq!(manager.state(), LocalDiscoveryState::Publishing);
    manager.mark_published();
    assert_eq!(manager.state(), LocalDiscoveryState::Published);
    manager.mark_degraded();
    assert_eq!(manager.state(), LocalDiscoveryState::Degraded);
    // bump 后回到 Idle（新 revision 需要重新发布）。
    manager.bump_revision();
    assert_eq!(manager.state(), LocalDiscoveryState::Idle);
}
