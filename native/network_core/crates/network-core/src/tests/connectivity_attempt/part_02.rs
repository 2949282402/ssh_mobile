
fn coordinator_for(state: &Arc<RuntimeState>) -> ConnectivityAttemptCoordinator {
    ConnectivityAttemptCoordinator::new(Arc::clone(state))
}

#[tokio::test]
async fn capability_mismatch_is_rejected_before_a_second_control_transaction() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, crate::connect::CAPABILITY_RELIABLE_MESSAGE)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let _admission = state
        .admit_authenticated_session(peer_id, Some(session_id), "remote-session")
        .await
        .expect("authenticate the existing route");
    assert!(
        state
            .mark_relay_route_connected(peer_id, session_id, None)
            .await
    );

    let error = coordinator_for(&state)
        .connect_with_class(peer_id, CommunicationClass::UnreliableDatagram)
        .await
        .expect_err("a message-only route cannot satisfy a datagram request");

    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    state.close_transport_path(peer_id).await;
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn stage_a_reuses_only_a_compatible_ready_direct_path() {
    let (state, _event_rx, _ready_control) = configured_reuse_state().await;
    let control = StubControl::new(ResolveStatus::Offline, None);
    *state.relay.control.write().await = Some(control.clone());
    install_ready_direct_path(&state, "peer-b", RouteTransport::Tcp).await;

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::UnreliableDatagram)
        .await;

    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::PeerOffline as i32),
        "an incompatible ready Direct path must not satisfy the request: {result:?}"
    );
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
}

#[tokio::test]
async fn stage_a_compatible_ready_direct_path_makes_no_control_plane_calls() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    install_ready_direct_path(&state, "peer-b", RouteTransport::Tcp).await;

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableStream)
        .await;

    assert!(
        result.is_ok(),
        "compatible Stage A reuse should succeed: {result:?}"
    );
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
}

#[tokio::test]
async fn in_progress_admission_retries_after_the_owned_session_is_retired() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("expected an in-progress owner session, got {decision:?}"),
    };

    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        ConnectivityAttemptCoordinator::new(task_state)
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await
    });

    // Let the second coordinator observe the first owner's in-progress
    // session, then retire that exact admission as a failed attempt would.
    tokio::time::sleep(Duration::from_millis(30)).await;
    state.fail_session("peer-b", session_id).await;

    let result = task.await.expect("connect task");
    assert!(
        result.is_err(),
        "the stub control plane has no usable route"
    );
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(control.connectivity_calls(), 1);
    assert_eq!(control.reserve_calls(), 0);
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert!(
        state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_none(),
        "failed retry must retire the replacement session"
    );
}

#[tokio::test]
async fn in_progress_admission_reuses_a_route_that_appears_before_retry() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("expected an in-progress owner session, got {decision:?}"),
    };

    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        ConnectivityAttemptCoordinator::new(task_state)
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await
    });

    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(
        state
            .mark_relay_route_connected("peer-b", session_id, None)
            .await,
        "the in-progress owner should be able to publish the replacement route"
    );

    assert!(task.await.expect("connect task").is_ok());
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    assert!(state.path_is_connected("peer-b").await);
    state.close_transport_path("peer-b").await;
    state
        .connection_sessions
        .retire_session("peer-b", session_id)
        .await;
}

#[tokio::test]
async fn cancelled_attempt_allows_immediate_reconnect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_unreachable_direct_snapshot()),
    );
    *state.relay.control.write().await = Some(control.clone());

    let coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let task = {
        let coordinator = Arc::clone(&coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };

    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if control.connectivity_calls() == 1 {
                if let Some(session_id) =
                    state.connection_sessions.current_session_id("peer-b").await
                {
                    break session_id;
                }
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("Stage B must commit Offer before cancellation");

    task.abort();
    let _ = task.await;

    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cancelled attempt must retire its exact Session");

    let new_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            match state
                .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
                .await
            {
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(_) => tokio::task::yield_now().await,
                decision => panic!("unexpected reconnect admission: {decision:?}"),
            }
        }
    })
    .await
    .expect("cancelled attempt must allow a new admission");

    assert_ne!(new_session_id, old_session_id);
    assert!(
        state
            .mark_relay_route_connected("peer-b", new_session_id, None)
            .await,
        "replacement Session must be able to publish a route"
    );

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale cleanup must not retire the replacement Session"
    );
    assert!(state.path_is_connected("peer-b").await);

    state.close_transport_path("peer-b").await;
    state.fail_session("peer-b", new_session_id).await;
}

#[tokio::test]
async fn cancelled_connect_can_immediately_start_second_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let first_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_unreachable_direct_snapshot()),
    );
    first_control.hold_offer();
    *state.relay.control.write().await = Some(first_control.clone());

    let first_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let first_task = {
        let coordinator = Arc::clone(&first_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    first_control.wait_offer_started().await;
    let old_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("first coordinator must own a Session before Offer");

    first_task.abort();
    assert!(first_task
        .await
        .expect_err("first connect must abort")
        .is_cancelled());
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state.connection_sessions.current_session_id("peer-b").await != Some(old_session_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cancelled coordinator must retire its old Session");

    let second_control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    second_control.hold_offer();
    *state.relay.control.write().await = Some(second_control.clone());

    let second_coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let second_task = {
        let coordinator = Arc::clone(&second_coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };
    second_control.wait_offer_started().await;
    let new_session_id = state
        .connection_sessions
        .current_session_id("peer-b")
        .await
        .expect("second coordinator must own a new Session before Offer release");

    assert!(second_control.resolve_calls() >= 1);
    assert!(second_control.connectivity_calls() >= 1);
    assert_ne!(new_session_id, old_session_id);

    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id),
        "stale cancellation cleanup must not retire the replacement Session"
    );

    second_control.release_offer();
    let result = tokio::time::timeout(Duration::from_secs(2), second_task)
        .await
        .expect("second coordinator must not remain permanently InProgress")
        .expect("second coordinator task");
    assert!(
        result.is_err(),
        "the closed test candidate must fail normally: {result:?}"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed replacement coordinator must retire its own Session"
    );
}

#[tokio::test(start_paused = true)]
async fn overall_timeout_does_not_poison_next_connect() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::timeout();
    *state.relay.control.write().await = Some(control);

    let coordinator = Arc::new(ConnectivityAttemptCoordinator::new(Arc::clone(&state)));
    let task = {
        let coordinator = Arc::clone(&coordinator);
        tokio::spawn(async move {
            coordinator
                .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
                .await
        })
    };

    let old_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if let Some(session_id) = state.connection_sessions.current_session_id("peer-b").await {
                break session_id;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("timeout attempt must reserve a Session before Resolve");

    tokio::task::yield_now().await;
    tokio::time::advance(super::super::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = task.await.expect("overall timeout task");
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "hanging control transaction must map to Timeout: {result:?}"
    );

    tokio::task::yield_now().await;
    let new_session_id = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            match state
                .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
                .await
            {
                ConnectDecision::Started(session_id) => break session_id,
                ConnectDecision::InProgress(_) => tokio::task::yield_now().await,
                decision => panic!("unexpected reconnect admission: {decision:?}"),
            }
        }
    })
    .await
    .expect("overall timeout must allow a new admission");

    assert_ne!(new_session_id, old_session_id);
    assert!(
        state
            .mark_relay_route_connected("peer-b", new_session_id, None)
            .await,
        "replacement Session must survive stale timeout cleanup"
    );
    state.fail_session("peer-b", old_session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        Some(new_session_id)
    );
    assert!(state.path_is_connected("peer-b").await);

    state.close_transport_path("peer-b").await;
    state.fail_session("peer-b", new_session_id).await;
}


