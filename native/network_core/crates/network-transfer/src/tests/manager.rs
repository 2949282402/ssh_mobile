use super::*;
use crate::manifest::NETWORK_TRANSFER_PROTOCOL_VERSION;

fn manifest(id: &str) -> FileManifest {
    FileManifest {
        transfer_id: id.into(),
        file_name: "payload.bin".into(),
        file_size: 4,
        modified_at: 0,
        content_hash: "00".repeat(32),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

#[tokio::test]
async fn network_pause_preserves_peer_and_can_be_claimed_once() {
    let manager = TransferManager::new();
    assert!(
        manager
            .register_outgoing(
                manifest("transfer-1"),
                PathBuf::from("source.bin"),
                "peer-b".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("transfer-1").await);
    assert!(manager.update_progress("transfer-1", 2).await);
    assert!(manager.pause_for_network("transfer-1").await);
    assert_eq!(
        manager.snapshot("transfer-1").await.unwrap().state,
        TransferState::Paused
    );
    // §19：恢复按 Peer 领取；session_id 只是派发时附加的 crypto/task 键，
    // 不参与匹配——新 ConnectionSession 用新 wire key 重新编码。
    let resumed = manager
        .take_resumable_for_peer("peer-b", "0000000000000002")
        .await;
    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].offset, 2);
    assert_eq!(resumed[0].session_id, "0000000000000002");
    assert!(manager
        .take_resumable_for_peer("peer-b", "0000000000000002")
        .await
        .is_empty());
}

#[tokio::test]
async fn paused_transfer_survives_session_replacement_and_resumes_by_peer() {
    // §19：ConnectionSession 被替换（新连接）不是终态；TransferOperation 保留
    // 并按 transfer_id + peer_id 恢复，而不是按 SessionId 终止。
    let manager = TransferManager::new();
    assert!(
        manager
            .register_outgoing(
                manifest("transfer-2"),
                PathBuf::from("source.bin"),
                "peer-b".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("transfer-2").await);
    assert!(manager.update_progress("transfer-2", 3).await);
    // 旧 ConnectionSession 销毁 → Paused。
    assert!(manager.pause_for_network("transfer-2").await);
    let paused_ids = manager.pause_peer_transfers("peer-b").await;
    assert!(
        paused_ids.is_empty(),
        "already-paused transfer is not re-paused"
    );
    // 新 ConnectionSession（不同 wire key）通过 Peer 领取并恢复。
    let resumed = manager
        .take_resumable_for_peer("peer-b", "0000000000000002")
        .await;
    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].offset, 3);
    assert_eq!(resumed[0].session_id, "0000000000000002");
    // 恢复后旧状态不再是 Paused。
    assert_eq!(
        manager.snapshot("transfer-2").await.unwrap().state,
        TransferState::Resuming
    );
}

#[tokio::test]
async fn session_destruction_pauses_active_transfers() {
    let manager = TransferManager::new();
    assert!(
        manager
            .register_outgoing(
                manifest("transfer-pause-all"),
                PathBuf::from("source.bin"),
                "peer-b".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("transfer-pause-all").await);
    assert!(manager.update_progress("transfer-pause-all", 1).await);
    let paused_ids = manager.pause_peer_transfers("peer-b").await;
    assert_eq!(paused_ids, vec!["transfer-pause-all".to_string()]);
    assert_eq!(
        manager.snapshot("transfer-pause-all").await.unwrap().state,
        TransferState::Paused
    );
    // 其他 Peer 的传输不受影响。
    assert!(
        manager
            .register_outgoing(
                manifest("transfer-other-peer"),
                PathBuf::from("source.bin"),
                "peer-c".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("transfer-other-peer").await);
    assert!(manager.pause_peer_transfers("peer-b").await.is_empty());
    assert_eq!(
        manager.snapshot("transfer-other-peer").await.unwrap().state,
        TransferState::Transferring
    );
}

#[tokio::test]
async fn incoming_paused_transfer_is_reused_only_for_same_peer_and_manifest() {
    let manager = TransferManager::new();
    let first = manifest("transfer-3");
    assert!(
        manager
            .register_incoming(first.clone(), "peer-b".into(),)
            .await
    );
    assert!(manager.mark_transferring("transfer-3").await);
    assert!(manager.pause_for_network("transfer-3").await);
    // 同一 Peer + 同一 Manifest → 复用并回到 WaitingApproval。
    assert!(manager.register_incoming(first, "peer-b".into(),).await);
    assert_eq!(
        manager.snapshot("transfer-3").await.unwrap().state,
        TransferState::WaitingApproval
    );
    // 同一 TransferId 但不同 Manifest → 拒绝复用（业务身份不匹配）。
    assert!(
        !manager
            .register_incoming(
                FileManifest {
                    file_name: "different.bin".into(),
                    ..manifest("transfer-3")
                },
                "peer-b".into(),
            )
            .await
    );
}

#[tokio::test]
async fn incoming_resume_claim_keeps_offset_and_rejects_wrong_binding() {
    let manager = TransferManager::new();
    let file_manifest = manifest("transfer-resume");
    assert!(
        manager
            .register_incoming(file_manifest.clone(), "peer-b".into(),)
            .await
    );
    assert!(manager.mark_transferring("transfer-resume").await);
    assert!(manager.update_progress("transfer-resume", 2).await);
    assert!(manager.pause_for_network("transfer-resume").await);
    assert_eq!(
        manager
            .claim_incoming_resume(&file_manifest, "peer-b",)
            .await,
        Some(2)
    );
    // 不同 Peer → 拒绝；TransferOperation 保持 Paused，可再被正确 Peer 领取。
    assert!(manager
        .claim_incoming_resume(&file_manifest, "peer-c")
        .await
        .is_none());
    assert!(manager
        .claim_incoming_resume(&file_manifest, "peer-b")
        .await
        .is_none());
}

#[tokio::test]
async fn checkpoint_mismatch_keeps_transfer_paused() {
    // §40 失败场景：ResumeTransfer 协商出的 checkpoint 与对端不一致时，恢复被
    // 拒绝，TransferOperation 必须留在 Paused（干净失败，不能继续发送）。
    let manager = TransferManager::new();
    let file_manifest = manifest("transfer-checkpoint");
    assert!(
        manager
            .register_incoming(file_manifest.clone(), "peer-b".into(),)
            .await
    );
    assert!(manager.mark_transferring("transfer-checkpoint").await);
    assert!(manager.update_progress("transfer-checkpoint", 5).await);
    assert!(manager.pause_for_network("transfer-checkpoint").await);
    // 对端以不同 Manifest 来恢复（checkpoint 所属业务身份不匹配）→ None。
    let mismatched = FileManifest {
        file_size: 99,
        ..file_manifest.clone()
    };
    assert!(manager
        .claim_incoming_resume(&mismatched, "peer-b")
        .await
        .is_none());
    assert_eq!(
        manager.snapshot("transfer-checkpoint").await.unwrap().state,
        TransferState::Paused
    );
    // 恢复仍可被正确 Manifest 领取，checkpoint（confirmed_offset）不变。
    assert_eq!(
        manager
            .claim_incoming_resume(&file_manifest, "peer-b")
            .await,
        Some(5)
    );
}

#[tokio::test]
async fn terminal_state_cannot_be_rewritten_by_old_route() {
    let manager = TransferManager::new();
    assert!(
        manager
            .register_outgoing(
                manifest("transfer-4"),
                PathBuf::from("source.bin"),
                "peer-b".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("transfer-4").await);
    assert!(manager.mark_verifying("transfer-4").await);
    assert!(manager.mark_completed("transfer-4").await);
    assert!(!manager.pause_for_network("transfer-4").await);
    assert!(
        !manager
            .fail_transfer("transfer-4", TransferFailureReason::Io)
            .await
    );
    assert_eq!(
        manager.snapshot("transfer-4").await.unwrap().state,
        TransferState::Completed
    );
}

#[tokio::test]
async fn manager_state_boundaries_expose_only_live_transfers_and_shared_cancellation() {
    let manager = TransferManager::default();
    assert_eq!(manager.active_count_for_peer("peer-a").await, 0);
    assert!(manager.active_ids_for_peer("peer-a").await.is_empty());
    assert!(manager.snapshot("missing").await.is_none());
    assert!(manager.cancellation_token("missing").await.is_none());

    assert!(
        manager
            .register_outgoing(
                manifest("live"),
                PathBuf::from("source.bin"),
                "peer-a".into(),
            )
            .await
    );
    assert!(
        !manager
            .register_outgoing(
                manifest("live"),
                PathBuf::from("other.bin"),
                "peer-a".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("live").await);
    assert!(!manager.mark_transferring("live").await);
    assert!(manager.mark_verifying("live").await);
    assert!(!manager.mark_verifying("live").await);
    assert!(manager.update_progress("live", 3).await);
    assert_eq!(manager.active_count_for_peer("peer-a").await, 1);
    assert_eq!(manager.active_ids_for_peer("peer-a").await, vec!["live"]);

    assert!(manager.mark_completed("live").await);
    assert!(!manager.mark_completed("live").await);
    assert_eq!(manager.active_count_for_peer("peer-a").await, 0);
    assert!(!manager.update_progress("live", 4).await);

    assert!(
        manager
            .register_incoming(manifest("cancelled"), "peer-a".into())
            .await
    );
    assert!(manager.cancel_transfer("cancelled").await);
    assert!(!manager.cancel_transfer("cancelled").await);
    assert!(manager.is_cancelled("cancelled").await);
    assert!(manager
        .cancellation_token("cancelled")
        .await
        .expect("cancellation token")
        .is_cancelled());
    assert!(!manager.mark_transferring("cancelled").await);

    assert!(
        manager
            .register_outgoing(
                manifest("failed"),
                PathBuf::from("source.bin"),
                "peer-a".into(),
            )
            .await
    );
    assert!(
        manager
            .fail_transfer("failed", TransferFailureReason::Permission)
            .await
    );
    assert!(
        !manager
            .fail_transfer("failed", TransferFailureReason::Io)
            .await
    );
    assert_eq!(
        manager.snapshot("failed").await.unwrap().state,
        TransferState::Failed(TransferFailureReason::Permission)
    );

    manager.remove_transfer("failed").await;
    assert!(manager.snapshot("failed").await.is_none());
    assert!(!manager.pause_for_network("missing").await);
    assert!(!manager.mark_verifying("missing").await);
    assert!(!manager.mark_completed("missing").await);
}

#[tokio::test]
async fn pause_peer_transfers_only_pauses_non_terminal_matching_peer_sessions() {
    let manager = TransferManager::new();
    assert!(
        manager
            .register_outgoing(
                manifest("pause-a"),
                PathBuf::from("source-a.bin"),
                "peer-a".into(),
            )
            .await
    );
    assert!(
        manager
            .register_incoming(manifest("pause-b"), "peer-a".into())
            .await
    );
    assert!(
        manager
            .register_outgoing(
                manifest("pause-c"),
                PathBuf::from("source-c.bin"),
                "peer-b".into(),
            )
            .await
    );
    assert!(manager.mark_transferring("pause-c").await);
    assert!(manager.mark_completed("pause-c").await);

    let mut paused = manager.pause_peer_transfers("peer-a").await;
    paused.sort();
    assert_eq!(paused, vec!["pause-a", "pause-b"]);
    assert_eq!(
        manager.active_count_for_peer("peer-a").await,
        2,
        "paused transfers remain non-terminal until resumed or failed"
    );
    assert_eq!(
        manager.snapshot("pause-c").await.unwrap().state,
        TransferState::Completed
    );
    let resumed = manager
        .take_resumable_for_peer("peer-a", "new-session")
        .await;
    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].transfer_id, "pause-a");
    assert_eq!(resumed[0].session_id, "new-session");
}
