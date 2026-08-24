use super::*;

async fn register_pending(manager: &ConnectionSessionStore, peer_id: &str) -> SessionId {
    let session_id = SessionId::new();
    manager
        .register_pending_session(peer_id, session_id)
        .await
        .expect("pending session registration");
    session_id
}

#[tokio::test]
async fn new_session_ids_are_random_128_bit_lowercase_hex() {
    let first = SessionId::new();
    let second = SessionId::new();
    let first_key = first.wire_key();
    let second_key = second.wire_key();

    assert_eq!(first_key.len(), SESSION_ID_BYTES * 2);
    assert_eq!(second_key.len(), SESSION_ID_BYTES * 2);
    assert!(first_key
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
    assert!(second_key
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
    assert_ne!(first, second);
    assert_ne!(first_key, second_key);
}

#[tokio::test]
async fn pending_registration_is_identity_only_and_does_not_replace() {
    let manager = ConnectionSessionStore::new();
    let first = register_pending(&manager, "peer-a").await;

    assert_eq!(manager.current_session_id("peer-a").await, Some(first));
    assert_eq!(manager.current_remote_session_binding("peer-a").await, None);
    assert!(manager
        .register_pending_session("peer-a", SessionId::new())
        .await
        .is_err());
}

#[tokio::test]
async fn in_flight_admission_keeps_identity_and_installs_fresh_crypto_decision() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;

    let admission = manager
        .admit_authenticated_session("peer-a", Some(session_id), "remote-a")
        .await
        .expect("authenticated admission");

    assert_eq!(admission.session_id, session_id);
    assert_eq!(admission.decision, SessionCryptoDecision::Initialize);
    assert_eq!(admission.replaced_session_id, None);
    assert_eq!(
        manager
            .current_remote_session_binding("peer-a")
            .await
            .as_deref(),
        Some("remote-a")
    );
    assert!(manager.is_current_session("peer-a", session_id).await);
}

#[tokio::test]
async fn responder_admission_creates_a_fresh_identity() {
    let manager = ConnectionSessionStore::new();

    let admission = manager
        .admit_authenticated_session("peer-a", None, "remote-a")
        .await
        .expect("responder admission");

    assert_eq!(admission.decision, SessionCryptoDecision::Initialize);
    assert_eq!(admission.replaced_session_id, None);
    assert_eq!(
        manager.current_session_id("peer-a").await,
        Some(admission.session_id)
    );
}

#[tokio::test]
async fn candidate_winner_guard_rejects_late_candidates_without_replacing_identity() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;
    manager
        .admit_authenticated_session("peer-a", Some(session_id), "remote-a")
        .await
        .expect("winner admission");

    assert_eq!(
        manager
            .admit_authenticated_session("peer-a", Some(session_id), "remote-a")
            .await,
        Err(ConnectionAdmissionError::StaleSession)
    );
    assert_eq!(
        manager
            .admit_authenticated_session("peer-a", None, "remote-a")
            .await,
        Err(ConnectionAdmissionError::StaleSession)
    );
    assert_eq!(
        manager
            .admit_authenticated_session("peer-a", Some(session_id), "remote-b")
            .await,
        Err(ConnectionAdmissionError::StaleSession)
    );
    assert_eq!(manager.current_session_id("peer-a").await, Some(session_id));
    assert_eq!(
        manager
            .current_remote_session_binding("peer-a")
            .await
            .as_deref(),
        Some("remote-a")
    );
}

#[tokio::test]
async fn concurrent_authenticated_candidates_have_one_admission_winner() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;

    let (first, second) = tokio::join!(
        manager.admit_authenticated_session("peer-a", Some(session_id), "remote-a"),
        manager.admit_authenticated_session("peer-a", Some(session_id), "remote-a"),
    );
    let first_won = matches!(&first, Ok(admission) if admission.session_id == session_id);
    let second_won = matches!(&second, Ok(admission) if admission.session_id == session_id);
    assert!(first_won ^ second_won);
    let first_lost = matches!(&first, Err(ConnectionAdmissionError::StaleSession));
    let second_lost = matches!(&second, Err(ConnectionAdmissionError::StaleSession));
    assert!(first_lost ^ second_lost);
}

#[tokio::test]
async fn unaffiliated_remote_binding_gets_a_new_identity_and_fresh_root_decision() {
    let manager = ConnectionSessionStore::new();
    let first = manager
        .admit_authenticated_session("peer-a", None, "remote-a")
        .await
        .expect("first responder admission");

    let replaced = manager
        .admit_authenticated_session("peer-a", None, "remote-b")
        .await
        .expect("new remote binding admission");

    assert_ne!(replaced.session_id, first.session_id);
    assert_eq!(replaced.decision, SessionCryptoDecision::ReplaceWithNew);
    assert_eq!(replaced.replaced_session_id, Some(first.session_id));
    assert_eq!(
        manager.current_session_id("peer-a").await,
        Some(replaced.session_id)
    );
    assert_eq!(
        manager
            .current_remote_session_binding("peer-a")
            .await
            .as_deref(),
        Some("remote-b")
    );
}

#[tokio::test]
async fn finalization_is_binding_safe_and_cannot_rewrite_authenticated_state() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;
    manager
        .admit_authenticated_session("peer-a", Some(session_id), "remote-a")
        .await
        .expect("claim");

    manager
        .finalize_authenticated_session("peer-a", session_id, "remote-a")
        .await
        .expect("finalize");
    manager
        .finalize_authenticated_session("peer-a", session_id, "remote-a")
        .await
        .expect("same binding is idempotent");
    assert_eq!(
        manager
            .finalize_authenticated_session("peer-a", session_id, "remote-b")
            .await,
        Err(ConnectionAdmissionError::StaleSession)
    );
}

#[tokio::test]
async fn releasing_a_failed_claim_reopens_only_the_reserved_identity() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;
    manager
        .admit_authenticated_session("peer-a", Some(session_id), "remote-a")
        .await
        .expect("claim");

    assert!(
        manager
            .release_authenticated_session("peer-a", session_id, "remote-a")
            .await
    );
    assert_eq!(manager.current_remote_session_binding("peer-a").await, None);
    let retry = manager
        .admit_authenticated_session("peer-a", Some(session_id), "remote-b")
        .await
        .expect("retry claim");
    assert_eq!(retry.session_id, session_id);
    manager
        .finalize_authenticated_session("peer-a", session_id, "remote-b")
        .await
        .expect("finalize retry claim");
    assert!(
        !manager
            .release_authenticated_session("peer-a", session_id, "remote-b")
            .await
    );
}

#[tokio::test]
async fn stale_guards_and_invalid_bindings_fail_closed() {
    let manager = ConnectionSessionStore::new();
    let session_id = register_pending(&manager, "peer-a").await;

    assert_eq!(
        manager
            .admit_authenticated_session("peer-a", Some(SessionId::new()), "remote-a")
            .await,
        Err(ConnectionAdmissionError::StaleSession)
    );
    assert_eq!(
        manager
            .admit_authenticated_session("peer-a", Some(session_id), "")
            .await,
        Err(ConnectionAdmissionError::InvalidRemoteBinding)
    );
    assert_eq!(
        manager
            .finalize_authenticated_session("peer-a", session_id, "")
            .await,
        Err(ConnectionAdmissionError::InvalidRemoteBinding)
    );
}

#[tokio::test]
async fn retirement_requires_the_current_identity_and_allows_a_new_connection() {
    let manager = ConnectionSessionStore::new();
    let first = register_pending(&manager, "peer-a").await;

    assert!(!manager.retire_session("peer-a", SessionId::new()).await);
    assert!(manager.retire_session("peer-a", first).await);
    assert_eq!(manager.current_session_id("peer-a").await, None);

    let second = register_pending(&manager, "peer-a").await;
    assert_ne!(first, second);
}
