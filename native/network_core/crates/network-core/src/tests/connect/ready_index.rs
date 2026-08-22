use super::*;
use crate::session::ConnectionSessionStore;
use std::sync::Arc;

fn epoch(high: u64, low: u64) -> Option<RuntimeEpoch> {
    Some(RuntimeEpoch { high, low })
}

async fn session_id(manager: &ConnectionSessionStore, peer_id: &str) -> SessionId {
    let id = SessionId::new();
    manager
        .register_pending_session(peer_id, id)
        .await
        .expect("reserve session identity");
    id
}

#[tokio::test]
async fn lookup_reuses_same_epoch_and_capability() {
    let manager = ConnectionSessionStore::new();
    let session_b = session_id(&manager, "device-b").await;
    let registry = ReadySessionIndex::new();
    registry.register("device-b", epoch(1, 2), 0, session_b);
    let found = registry.lookup("device-b", &epoch(1, 2), 0).expect("reuse");
    assert_eq!(found.session_id, session_b);
}

#[test]
fn lookup_capability_is_order_independent_and_concurrent() {
    // A request's CommunicationClass is translated to a lookup mask at the
    // boundary; the registry never stores that request-local value. Both
    // orderings and concurrent readers must observe the same route capability.
    let registry = Arc::new(ReadySessionIndex::new());
    let session_id = SessionId::from_bytes([7u8; crate::session::SESSION_ID_BYTES]);
    let remote_epoch = Some(RuntimeEpoch { high: 1, low: 2 });
    registry.register(
        "device-b",
        remote_epoch.clone(),
        super::super::DEFAULT_CONNECTION_CAPABILITY,
        session_id,
    );

    for capability in [
        super::super::CAPABILITY_RELIABLE_STREAM,
        super::super::CAPABILITY_RELIABLE_MESSAGE,
        super::super::CAPABILITY_RELIABLE_STREAM,
    ] {
        assert!(registry
            .lookup("device-b", &remote_epoch, capability)
            .is_some());
    }

    let handles: Vec<_> = (0..8)
        .map(|index| {
            let registry = Arc::clone(&registry);
            let remote_epoch = remote_epoch.clone();
            std::thread::spawn(move || {
                let capability = if index % 2 == 0 {
                    super::super::CAPABILITY_RELIABLE_MESSAGE
                } else {
                    super::super::CAPABILITY_RELIABLE_STREAM
                };
                assert!(registry
                    .lookup("device-b", &remote_epoch, capability)
                    .is_some());
            })
        })
        .collect();
    for handle in handles {
        handle.join().expect("capability lookup thread");
    }
}

#[tokio::test]
async fn lookup_returns_none_for_a_different_epoch() {
    let manager = ConnectionSessionStore::new();
    let session_e7 = session_id(&manager, "device-b").await;
    let registry = ReadySessionIndex::new();
    registry.register("device-b", epoch(7, 8), 0, session_e7);
    assert!(registry.lookup("device-b", &epoch(8, 8), 0).is_none());
    assert!(registry.lookup("device-b", &epoch(7, 9), 0).is_none());
}

#[tokio::test]
async fn take_obsolete_closes_old_when_epoch_changed() {
    let manager = ConnectionSessionStore::new();
    let session_e7 = session_id(&manager, "device-b").await;
    let registry = ReadySessionIndex::new();
    registry.register("device-b", epoch(7, 8), 0, session_e7);
    let obsolete = registry
        .take_obsolete("device-b", &epoch(8, 8))
        .expect("old epoch must be taken");
    assert_eq!(obsolete.session_id, session_e7);
    assert!(registry.lookup("device-b", &epoch(8, 8), 0).is_none());
}

#[tokio::test]
async fn local_direct_mode_epoch_none_is_reused() {
    let manager = ConnectionSessionStore::new();
    let session_local = session_id(&manager, "device-b").await;
    let registry = ReadySessionIndex::new();
    registry.register("device-b", None, 0, session_local);
    assert!(registry.lookup("device-b", &None, 0).is_some());
    // 有控制面（epoch=Some）不能复用一个 epoch=None 的本地直连。
    assert!(registry.lookup("device-b", &epoch(1, 1), 0).is_none());
    // epoch=None 本地直连遇到有 epoch 的登记 → 视为换代（take_obsolete）。
    assert!(registry.take_obsolete("device-b", &None).is_none());
}

#[tokio::test]
async fn unregister_if_session_only_removes_matching_session() {
    let manager = ConnectionSessionStore::new();
    let session_b = session_id(&manager, "device-b").await;
    let session_stale = session_id(&manager, "device-c").await;
    let registry = ReadySessionIndex::new();
    registry.register("device-b", epoch(1, 2), 0, session_b);
    registry.unregister_if_session("device-b", session_stale);
    assert!(registry.lookup("device-b", &epoch(1, 2), 0).is_some());
    registry.unregister_if_session("device-b", session_b);
    assert!(registry.lookup("device-b", &epoch(1, 2), 0).is_none());
}
