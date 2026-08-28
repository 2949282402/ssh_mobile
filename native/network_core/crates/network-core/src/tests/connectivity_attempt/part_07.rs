#[tokio::test]
async fn connect_wrapper_and_missing_control_plane_fail_closed() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    *state.relay.control.write().await = None;
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let result = coordinator
        .connect("peer-b")
        .await
        .expect_err("connect wrapper must use the authoritative control gate");
    assert_eq!(result.code, NetworkErrorCode::RelayError as i32);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "missing control must not reserve a Session"
    );
}

#[tokio::test]
async fn session_cleanup_guard_retires_an_unattached_attempt() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let session_id = match state
        .begin_connect("peer-b", DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected session decision: {decision:?}"),
    };
    let guard = SessionCleanupGuard::new(Arc::clone(&state), "peer-b", session_id);
    drop(guard);
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if state
                .connection_sessions
                .current_session_id("peer-b")
                .await
                .is_none()
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cleanup guard should retire its session");
}

#[tokio::test]
async fn coordination_spawn_fails_closed_when_runtime_supervisor_is_stopping() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    state.task_supervisor.cancel_root();
    let coordination = ConnectivityAttemptStart::new(
        ResolvePeerResponse {
            request_id: 1,
            status: ResolveStatus::Ready as i32,
            discovery: None,
            retry_after_ms: 0,
        },
        async { Err(RelayError::NotConnected) },
    );
    let attempt = Arc::new(Mutex::new(ConnectivityAttempt::with_connect_window(
        "stopped-coordination",
        "peer-b",
        NatRuntimeEpoch { high: 0, low: 0 },
        SystemTime::now(),
        DIRECT_CONNECT_WINDOW,
    )));
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    assert!(coordinator
        .spawn_coordination(
            coordination,
            "peer-b".into(),
            "stopped-coordination".into(),
            attempt,
            Vec::new(),
            None,
        )
        .is_err());
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn local_candidate_collection_uses_the_bounded_path_manager_snapshot() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let manager = Arc::new(PathManager::new());
    let candidate = Candidate::new(
        "192.168.1.24:42024".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "local-candidate".into(),
    );
    manager.add_candidates(vec![candidate.clone()]).await;
    *state.local_path_manager.write().await = Some(manager);
    let candidates = CandidateSnapshotPolicy::collect_local_candidates(Arc::clone(&state)).await;
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].candidate_id, candidate.candidate_id);
}

#[tokio::test]
async fn resolve_unknown_fails_closed_without_retry() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let control = StubControl::new(ResolveStatus::Unknown, None);
    *state.relay.control.write().await = Some(control.clone());
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let result = attempt_coordinator
        .resolve("peer-b", &peer_without_endpoint())
        .await;
    assert_eq!(control.resolve_calls(), 1);
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::RelayError as i32
    ));
}

#[tokio::test]
async fn offline_resolve_with_configured_endpoint_remains_authoritative() {
    // Stage A already owns configured-endpoint direct probing. Once it
    // fails, OFFLINE must not be converted into a synthetic READY.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let control = StubControl::new(ResolveStatus::Offline, None);
    *state.relay.control.write().await = Some(control);
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let peer = crate::runtime::PeerConfig {
        endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
        identity_public_key: [7u8; 32],
        e2e_public_key: [8u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };
    let result = attempt_coordinator.resolve("peer-b", &peer).await;
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::PeerOffline as i32
    ));
}

#[tokio::test]
async fn not_ready_resolve_with_configured_endpoint_remains_authoritative() {
    // A configured endpoint cannot make NOT_READY eligible for Relay
    // fallback or fabricate an authoritative discovery snapshot.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let control = StubControl::new(ResolveStatus::NotReady, None);
    *state.relay.control.write().await = Some(control);
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let peer = crate::runtime::PeerConfig {
        endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
        identity_public_key: [7u8; 32],
        e2e_public_key: [8u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };
    let result = attempt_coordinator.resolve("peer-b", &peer).await;
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::PeerNotReady as i32
    ));
}

#[tokio::test]
async fn resolve_transport_error_with_configured_endpoint_does_not_fail_open() {
    // A transport error is not permission to fabricate a peer discovery
    // result from a configured endpoint.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.relay.control.write().await = Some(StubControl::error());
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let peer = crate::runtime::PeerConfig {
        endpoint: Some("192.168.1.20:41020".parse().expect("test endpoint")),
        identity_public_key: [7u8; 32],
        e2e_public_key: [8u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };
    let result = attempt_coordinator.resolve("peer-b", &peer).await;
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::RelayError as i32
    ));
}

#[tokio::test(start_paused = true)]
async fn resolve_timeout_with_configured_endpoint_does_not_fail_open() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.relay.control.write().await = Some(StubControl::timeout());
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let peer = crate::runtime::PeerConfig {
        endpoint: Some("127.0.0.1:40000".parse().expect("test endpoint")),
        identity_public_key: [7u8; 32],
        e2e_public_key: [8u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };
    let task = tokio::spawn(async move { attempt_coordinator.resolve("peer-b", &peer).await });
    tokio::task::yield_now().await;
    tokio::time::advance(RESOLVE_TIMEOUT + Duration::from_millis(1)).await;
    let result = task.await.expect("resolve task");
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::Timeout as i32
    ));
}

#[tokio::test(start_paused = true)]
async fn resolve_timeout_without_endpoint_remains_a_timeout_error() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.relay.control.write().await = Some(StubControl::timeout());
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let peer = peer_without_endpoint();
    let task = tokio::spawn(async move { attempt_coordinator.resolve("peer-b", &peer).await });
    tokio::task::yield_now().await;
    tokio::time::advance(RESOLVE_TIMEOUT + Duration::from_millis(1)).await;
    let result = task.await.expect("resolve task");
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::Timeout as i32
    ));
}

#[tokio::test]
async fn reused_session_uses_route_profile_and_emits_connected() {
    // §17/§40：Registry 重用路径依据已登记的实际 capability；后续
    // ReliableStream 请求复用同一条同时支持 message/stream 的 Relay route 时，
    // 不需要覆盖 Session 上的任何业务类别状态。
    let (state, mut event_rx, control) = configured_reuse_state().await;
    let peer_id = "peer-b";

    // 预置一条健康连接：ReliableMessage 会话 + 已登记（模拟先前 connect 建立）。
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(id) => id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    assert!(
        state
            .mark_relay_route_connected(peer_id, session_id, None)
            .await
    );
    state
        .ready_session_index
        .register(peer_id, None, DEFAULT_CONNECTION_CAPABILITY, session_id);

    let attempt_coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let result = attempt_coordinator
        .connect_with_class(peer_id, CommunicationClass::ReliableStream)
        .await;
    assert!(result.is_ok(), "reuse path should succeed: {result:?}");
    assert_eq!(
        control.resolve_calls(),
        0,
        "healthy Relay reuse must not open a new Resolve transaction"
    );
    assert_eq!(
        control.connectivity_calls(),
        0,
        "healthy Relay reuse must not emit an unsolicited ConnectivityOffer"
    );
    assert_eq!(control.reserve_calls(), 0);

    // 重用的 Relay route profile 支持 ReliableStream；Relay(None) 载体只会因
    // 未连接而失败，不能因为此前的业务类别阻止 open_stream。
    let stream_result = crate::stream::open_stream(
        &state,
        peer_id,
        1,
        "shell",
        crate::stream::StreamConsumer::Event,
    )
    .await;
    assert!(
        !matches!(
            stream_result,
            Err(crate::stream::StreamError::UnsupportedTransport)
        ),
        "reused ReliableStream session must not gate byte streams"
    );

    // 重用路径发布 Connected 终态（Dart connect() 的成功信号）。
    let event = event_rx
        .try_recv()
        .expect("Connected event must be emitted on the reuse path");
    match event.payload {
        Some(network_protocol::network_event::Payload::PeerState(peer_state)) => {
            assert_eq!(peer_state.peer_id, peer_id);
            assert_eq!(
                peer_state.state,
                network_protocol::PeerConnectionState::Connected as i32
            );
            assert_eq!(peer_state.route_type, RouteType::Relay as i32);
        }
        other => panic!("unexpected event payload: {other:?}"),
    }
}

#[tokio::test]
async fn healthy_reuse_retires_path_after_remote_epoch_hint() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    let peer_id = "peer-b";
    let session_id = match state
        .begin_connect(peer_id, DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(id) => id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    assert!(
        state
            .mark_relay_route_connected(peer_id, session_id, None)
            .await
    );
    let remote_epoch = RuntimeEpoch { high: 3, low: 4 };
    state.ready_session_index.register(
        peer_id,
        Some(remote_epoch.clone()),
        DEFAULT_CONNECTION_CAPABILITY,
        session_id,
    );
    let candidate = Candidate::new(
        "127.0.0.1:41020".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "epoch-fence".into(),
    )
    .with_generation(1);
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: CandidateSnapshotPolicy::nat_runtime_epoch(&remote_epoch),
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(60)),
        },
        Instant::now(),
    )
    .expect("cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert(peer_id.into(), cache);
    state
        .remote_candidate_cache
        .write()
        .await
        .get_mut(peer_id)
        .expect("cache entry")
        .invalidate_for_remote_epoch(NatRuntimeEpoch { high: 5, low: 6 }, Instant::now());

    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    assert_eq!(
        coordinator
            .try_reuse_before_control(peer_id, DEFAULT_CONNECTION_CAPABILITY)
            .await
            .expect("reuse check"),
        None,
        "an epoch hint must fence pre-control reuse"
    );
    assert!(!state.path_is_connected(peer_id).await);
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        None
    );
}


