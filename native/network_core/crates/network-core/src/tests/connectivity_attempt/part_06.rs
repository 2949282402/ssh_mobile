#[tokio::test]
async fn active_connect_offline_and_unknown_fail_closed_without_offer_or_reserve() {
    for (status, expected_code) in [
        (ResolveStatus::Offline, NetworkErrorCode::PeerOffline as i32),
        (ResolveStatus::Unknown, NetworkErrorCode::RelayError as i32),
    ] {
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        let control = StubControl::new(status, None);
        *state.relay.control.write().await = Some(control.clone());
        control.observe_session_ownership(Arc::clone(&state));

        let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
            .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
            .await;

        assert!(
            matches!(result, Err(ref error) if error.code == expected_code),
            "{status:?} must remain authoritative after Stage A: {result:?}"
        );
        assert_eq!(control.resolve_calls(), 1);
        assert!(
            control.first_resolve_saw_owned_session(),
            "{status:?} Resolve must observe the local Session owner"
        );
        assert_eq!(control.connectivity_calls(), 0);
        assert_eq!(control.reserve_calls(), 0);
        assert_eq!(control.call_order(), vec!["resolve"]);
        assert_eq!(
            state.connection_sessions.current_session_id("peer-b").await,
            None,
            "{status:?} must retire the Session before any Offer or ReserveRelay"
        );
    }
}

#[tokio::test]
async fn direct_failure_negative_stage_c_gates_do_not_reserve_relay() {
    for (class, e2ee_policy, label) in [
        (
            CommunicationClass::ReliableMessage,
            network_protocol::E2eePolicy::Disabled,
            "E2EE disabled",
        ),
        (
            CommunicationClass::UnreliableDatagram,
            network_protocol::E2eePolicy::Required,
            "unsupported Relay capability",
        ),
    ] {
        let (state, _event_rx, _configured_control) = configured_reuse_state().await;
        state
            .peers
            .write()
            .await
            .get_mut("peer-b")
            .expect("configured peer")
            .e2ee_policy = e2ee_policy;
        let control = StubControl::new(
            ResolveStatus::Ready,
            Some(stage_c_ready_unreachable_direct_snapshot()),
        );
        *state.relay.control.write().await = Some(control.clone());
        control.observe_session_ownership(Arc::clone(&state));

        let result = tokio::time::timeout(
            Duration::from_secs(6),
            ConnectivityAttemptCoordinator::new(Arc::clone(&state))
                .connect_with_class("peer-b", class),
        )
        .await
        .expect("Direct failure boundary must remain bounded");

        assert!(result.is_err(), "{label} must fail closed: {result:?}");
        assert_eq!(control.resolve_calls(), 1, "{label} Resolve count");
        assert_eq!(control.connectivity_calls(), 1, "{label} Offer count");
        assert_eq!(control.reserve_calls(), 0, "{label} ReserveRelay count");
        assert_eq!(control.call_order(), vec!["resolve", "offer"]);
        assert!(
            control.first_resolve_saw_owned_session(),
            "{label} Direct attempt must own a Session before Resolve"
        );
        assert_eq!(
            state.connection_sessions.current_session_id("peer-b").await,
            None,
            "{label} Direct failure must retire its Session when Stage C is ineligible"
        );
    }
}

#[tokio::test]
async fn expired_stage_c_budget_skips_reserve_relay() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "expired-stage-c",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() - Duration::from_millis(1),
        )
        .await;

    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::Timeout as i32),
        "an expired Direct budget must fail before ReserveRelay: {result:?}"
    );
    assert_eq!(control.reserve_calls(), 0);
    assert!(control.call_order().is_empty());
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(session_id),
        "the helper does not own cleanup before reservation admission"
    );
    state.fail_session(peer_id, session_id).await;
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        None
    );
}

#[tokio::test]
async fn active_connect_resolve_error_retires_owned_session_before_offer() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    *state.local_discovery.write().await = Some(Arc::new(
        crate::discovery::LocalDiscoveryManager::with_epoch(31, 32, 4),
    ));
    let control = StubControl::error();
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "Resolve transport error must fail closed: {result:?}"
    );
    assert_eq!(control.resolve_calls(), 1);
    assert!(control.first_resolve_saw_owned_session());
    assert_eq!(control.connectivity_calls(), 0);
    assert_eq!(control.reserve_calls(), 0);
    assert_eq!(control.call_order(), vec!["resolve"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a failed control transaction must not leak its owned Session"
    );
}

#[tokio::test]
async fn invalid_resolve_candidate_snapshot_retires_owned_session() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let duplicate = Candidate::new(
        "127.0.0.1:41030".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "duplicate-candidate".into(),
    )
    .with_generation(1);
    let advertisement = serde_json::to_vec(&duplicate.advertisement()).expect("candidate");
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 21, low: 22 }),
            revision: 1,
            transport_capabilities: vec![network_relay::v2::TransportCapability::Quic as i32],
            candidate_bundle: Some(network_relay::v2::CandidateBundle {
                candidates: vec![advertisement.clone(), advertisement],
            }),
            published_at_ms: 0,
        }),
    );
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::InvalidArgument as i32),
        "duplicate candidate ids must be rejected: {result:?}"
    );
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "malformed discovery must not leak its local Session"
    );
}

#[tokio::test]
async fn cancelled_task_supervisor_retires_owned_session_after_offer() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::new(
        ResolveStatus::Ready,
        Some(stage_c_ready_relay_only_snapshot()),
    );
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));
    state.task_supervisor.cancel_root();

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "cancelled task supervisor must reject coordination admission: {result:?}"
    );
    assert_eq!(control.call_order(), vec!["resolve", "offer"]);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "coordination task admission failure must retire its Session"
    );
}

#[tokio::test]
async fn relay_fallback_without_control_plane_fails_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    *state.relay.control.write().await = None;
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "missing-control",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;
    assert!(
        matches!(result, Err(ref error) if error.code == NetworkErrorCode::RelayError as i32),
        "missing control plane must fail closed: {result:?}"
    );
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_rejects_an_unusable_control_plane_before_reservation() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_usable(false);
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "unusable-control",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.reserve_calls(), 0);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_maps_reservation_failure_and_retires_session() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "reserve-error",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.reserve_calls(), 1);
    assert_eq!(control.call_order(), vec!["reserve"]);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test(start_paused = true)]
async fn relay_fallback_maps_a_hanging_reservation_to_timeout() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::timeout();
    *state.relay.control.write().await = Some(control.clone());
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");
    let task_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        coordinator_for(&task_state)
            .connect_relay_fallback(
                peer_id,
                session_id,
                &peer,
                "reserve-timeout",
                crate::connect::CAPABILITY_RELIABLE_MESSAGE,
                Instant::now() + Duration::from_secs(10),
            )
            .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(RELAY_RESERVE_TIMEOUT + Duration::from_millis(1)).await;
    let result = task.await.expect("reservation task");
    assert!(
        matches!(
            result,
            Err(ref error) if error.code == NetworkErrorCode::Timeout as i32
        ),
        "unexpected hanging reservation result: {result:?}"
    );
    assert_eq!(control.reserve_calls(), 1);
    state.fail_session(peer_id, session_id).await;
}

#[tokio::test]
async fn relay_fallback_retires_session_when_data_plane_cannot_start() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_relay_reservation(network_relay::v2::RelayReserveResponse {
        request_id: 1,
        attempt_id: "data-failure".into(),
        reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        expires_at_ms: 0,
        local_token: vec![0; 32],
    });
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let peer = state
        .peers
        .read()
        .await
        .get(peer_id)
        .cloned()
        .expect("configured peer");

    let result = coordinator_for(&state)
        .connect_relay_fallback(
            peer_id,
            session_id,
            &peer,
            "data-failure",
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
            Instant::now() + Duration::from_secs(1),
        )
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.call_order(), vec!["reserve"]);
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        None,
        "data-plane admission failure must retire its Session"
    );
}


