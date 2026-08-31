#[tokio::test]
async fn connectivity_answer_merges_candidates_into_the_live_attempt() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("local-a".into(), [1u8; 32], [2u8; 32]),
    ));
    let candidate = Candidate::new(
        "198.51.100.20:42020".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "answer-lan".into(),
    )
    .with_generation(7);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 3, low: 4 }),
        revision: 7,
        transport_capabilities: Vec::new(),
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&candidate.advertisement()).expect("candidate")],
        }),
        published_at_ms: 1,
    };
    let answer = network_relay::v2::ConnectivityAnswer {
        request_id: 1,
        attempt_id: "attempt-answer".into(),
        accepted: true,
        responder_device_id: "peer-b".into(),
        responder_runtime_epoch: snapshot.runtime_epoch.clone(),
        responder_revision: snapshot.revision,
        responder_snapshot: Some(snapshot.clone()),
    };
    let coordination = ConnectivityAttemptStart::new(
        ResolvePeerResponse {
            request_id: 1,
            status: network_relay::v2::ResolveStatus::Ready as i32,
            discovery: Some(snapshot),
            retry_after_ms: 0,
        },
        async move { Ok(answer) },
    );
    let attempt = Arc::new(Mutex::new(ConnectivityAttempt::with_connect_window(
        "attempt-answer",
        "peer-b",
        CandidateSnapshotPolicy::nat_runtime_epoch(&RuntimeEpoch { high: 1, low: 2 }),
        SystemTime::now(),
        DIRECT_CONNECT_WINDOW,
    )));
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let mut updates = attempt_coordinator
        .spawn_coordination(
            coordination,
            "peer-b".into(),
            "attempt-answer".into(),
            Arc::clone(&attempt),
            Vec::new(),
            Some(Duration::from_secs(60)),
        )
        .expect("coordination task should start");
    tokio::time::timeout(Duration::from_secs(1), updates.changed())
        .await
        .expect("candidate update timeout")
        .expect("coordination sender dropped");
    let updates = updates.borrow().clone().expect("candidate update");
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0].endpoint.port(), 42020);
    let attempt = attempt.lock().await;
    assert_eq!(attempt.remote_candidates().len(), 1);
    assert_eq!(attempt.remote_discovery_revision(), Some(7));
    assert_eq!(
        attempt.remote_runtime_epoch(),
        Some(CandidateSnapshotPolicy::nat_runtime_epoch(&RuntimeEpoch {
            high: 3,
            low: 4
        })),
    );
    assert_eq!(
        attempt.state(),
        network_nat::ConnectivityAttemptState::Connecting
    );
}

#[test]
fn coordination_and_authoritative_statuses_fail_closed() {
    let peer_id = "peer-b";
    let ready_snapshot = stage_c_ready_relay_only_snapshot();
    let ready_response = ResolvePeerResponse {
        request_id: 1,
        status: ResolveStatus::Ready as i32,
        discovery: Some(ready_snapshot.clone()),
        retry_after_ms: 0,
    };
    let resolved =
        ConnectivityStageEligibility::ready_peer_from_coordination(&ready_response, peer_id)
            .expect("READY with discovery must resolve");
    assert!(matches!(
        resolved,
        ResolvedPeer::Ready { discovery: Some(_) }
    ));

    for (status, expected_code) in [
        (ResolveStatus::Offline, NetworkErrorCode::PeerOffline),
        (ResolveStatus::NotReady, NetworkErrorCode::PeerNotReady),
        (ResolveStatus::Unknown, NetworkErrorCode::RelayError),
        (ResolveStatus::Unspecified, NetworkErrorCode::RelayError),
    ] {
        let response = ResolvePeerResponse {
            request_id: 2,
            status: status as i32,
            discovery: None,
            retry_after_ms: 500,
        };
        let error = ConnectivityStageEligibility::ready_peer_from_coordination(&response, peer_id)
            .expect_err("non-ready status must not fabricate a peer");
        assert_eq!(error.code, expected_code as i32, "status={status:?}");
    }

    let missing_discovery = ResolvePeerResponse {
        request_id: 3,
        status: ResolveStatus::Ready as i32,
        discovery: None,
        retry_after_ms: 0,
    };
    let error =
        ConnectivityStageEligibility::ready_peer_from_coordination(&missing_discovery, peer_id)
            .expect_err("READY without discovery must fail closed");
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    assert!(
        ConnectivityStageEligibility::authoritative_resolve_or_error(
            peer_id,
            Ok(ResolvedPeer::Ready {
                discovery: Some(ready_snapshot),
            }),
        )
        .is_ok()
    );
    for (resolved, expected_code) in [
        (
            ResolvedPeer::Ready { discovery: None },
            NetworkErrorCode::RelayError,
        ),
        (ResolvedPeer::Offline, NetworkErrorCode::PeerOffline),
        (
            ResolvedPeer::NotReady {
                retry_after_ms: 500,
            },
            NetworkErrorCode::PeerNotReady,
        ),
        (
            ResolvedPeer::Unknown {
                retry_after_ms: 500,
            },
            NetworkErrorCode::RelayError,
        ),
    ] {
        let error =
            ConnectivityStageEligibility::authoritative_resolve_or_error(peer_id, Ok(resolved))
                .expect_err("authoritative status must remain typed");
        assert_eq!(error.code, expected_code as i32);
    }
    let error = ConnectivityStageEligibility::authoritative_resolve_or_error(
        peer_id,
        Err(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "cancelled",
            "test",
            peer_id,
        )),
    )
    .expect_err("transport error must propagate");
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
}

#[tokio::test]
async fn new_attempt_coordinator_starts_in_idle() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    assert_eq!(attempt_coordinator.stage(), ConnectivityAttemptState::Idle);
}

#[test]
fn resolved_runtime_epoch_is_read_from_ready_discovery() {
    let discovery = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 7, low: 8 }),
        revision: 3,
        transport_capabilities: vec![],
        candidate_bundle: None,
        published_at_ms: 0,
    };
    let resolved = ResolvedPeer::Ready {
        discovery: Some(discovery),
    };
    assert_eq!(
        CandidateSnapshotPolicy::resolved_runtime_epoch(&resolved),
        Some(RuntimeEpoch { high: 7, low: 8 })
    );
    assert_eq!(
        CandidateSnapshotPolicy::runtime_epoch_from_nat(
            CandidateSnapshotPolicy::nat_runtime_epoch(&RuntimeEpoch { high: 9, low: 10 })
        ),
        RuntimeEpoch { high: 9, low: 10 }
    );
    assert_eq!(
        CandidateSnapshotPolicy::resolved_snapshot(&resolved).map(|snapshot| snapshot.revision),
        Some(3)
    );
    assert_eq!(
        CandidateSnapshotPolicy::resolved_runtime_epoch(&ResolvedPeer::Offline),
        None
    );
    assert!(CandidateSnapshotPolicy::resolved_snapshot(&ResolvedPeer::Offline).is_none());
    assert_eq!(
        CandidateSnapshotPolicy::resolved_runtime_epoch(&ResolvedPeer::Ready { discovery: None }),
        None
    );
}

#[test]
fn candidate_conversion_and_snapshot_transport_mapping_are_fail_closed() {
    let candidate = Candidate::new(
        "192.0.2.50:41050".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "helper-lan".into(),
    )
    .with_generation(4);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 5, low: 6 }),
        revision: 8,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::Quic as i32,
            network_relay::v2::TransportCapability::Tcp as i32,
            network_relay::v2::TransportCapability::UdpDatagram as i32,
            network_relay::v2::TransportCapability::Websocket as i32,
            network_relay::v2::TransportCapability::RelayData as i32,
            network_relay::v2::TransportCapability::Webrtc as i32,
            network_relay::v2::TransportCapability::Unspecified as i32,
            999,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                b"not-json".to_vec(),
                serde_json::to_vec(&candidate.advertisement()).expect("advertisement"),
            ],
        }),
        published_at_ms: 0,
    };
    assert_eq!(
        CandidateSnapshotPolicy::snapshot_candidate_transports(&snapshot),
        vec![
            CandidateTransport::Quic,
            CandidateTransport::Tcp,
            CandidateTransport::UdpDatagram,
            CandidateTransport::Websocket,
            CandidateTransport::Relay,
        ]
    );
    let payloads = CandidateSnapshotPolicy::snapshot_candidate_payloads(&snapshot);
    assert_eq!(payloads.len(), 1);
    let direct = CandidateSnapshotPolicy::candidate_from_v2(&payloads[0])
        .expect("LAN candidate is direct eligible");
    assert!(direct.candidate_id.starts_with("helper-lan"));
    assert_eq!(direct.generation, 4);
    let mut relay = payloads[0].clone();
    relay.kind = CandidateKind::Relay;
    relay.transport_capabilities = vec![CandidateTransport::Relay];
    assert!(CandidateSnapshotPolicy::candidate_from_v2(&relay).is_none());
    let mut invalid = payloads[0].clone();
    invalid.transport_capabilities = vec![CandidateTransport::Relay];
    assert!(CandidateSnapshotPolicy::candidate_from_v2(&invalid).is_none());
}

#[tokio::test]
async fn cache_update_ignores_missing_epoch_and_rejects_inconsistent_snapshots() {
    let (state, _event_rx, _control) = configured_reuse_state().await;
    CandidateSnapshotPolicy::update_remote_candidate_cache(&state, "peer-b", None, None).await;
    CandidateSnapshotPolicy::update_remote_candidate_cache(
        &state,
        "peer-b",
        Some(&DiscoverySnapshot {
            runtime_epoch: None,
            revision: 1,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
        None,
    )
    .await;
    assert!(state.remote_candidate_cache.read().await.is_empty());

    let first = stage_c_ready_unreachable_direct_snapshot();
    CandidateSnapshotPolicy::update_remote_candidate_cache(
        &state,
        "peer-b",
        Some(&first),
        Some(Duration::from_secs(5)),
    )
    .await;
    assert!(state
        .remote_candidate_cache
        .read()
        .await
        .contains_key("peer-b"));

    let inconsistent = DiscoverySnapshot {
        runtime_epoch: first.runtime_epoch.clone(),
        revision: 0,
        transport_capabilities: first.transport_capabilities.clone(),
        candidate_bundle: first.candidate_bundle.clone(),
        published_at_ms: 0,
    };
    CandidateSnapshotPolicy::update_remote_candidate_cache(
        &state,
        "peer-b",
        Some(&inconsistent),
        Some(Duration::from_secs(5)),
    )
    .await;
    assert_eq!(
        state
            .remote_candidate_cache
            .read()
            .await
            .get("peer-b")
            .expect("cache entry")
            .revision,
        1
    );
}

#[test]
fn relay_error_mapping_and_stage_c_epoch_revision_guards_are_typed() {
    let peer_id = "peer-b";
    assert_eq!(
        relay_resolve_error(&RelayError::Timeout("slow".into()), peer_id).code,
        NetworkErrorCode::Timeout as i32
    );
    assert_eq!(
        relay_resolve_error(&RelayError::NotConnected, peer_id).code,
        NetworkErrorCode::RelayError as i32
    );
    let mut missing_epoch = stage_c_ready_relay_only_snapshot();
    missing_epoch.runtime_epoch = None;
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ResolvedPeer::Ready {
            discovery: Some(missing_epoch),
        },
        DEFAULT_CONNECTION_CAPABILITY,
        network_protocol::E2eePolicy::Required,
        Instant::now() + Duration::from_secs(1),
    ));
    let mut zero_revision = stage_c_ready_relay_only_snapshot();
    zero_revision.revision = 0;
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ResolvedPeer::Ready {
            discovery: Some(zero_revision),
        },
        DEFAULT_CONNECTION_CAPABILITY,
        network_protocol::E2eePolicy::Required,
        Instant::now() + Duration::from_secs(1),
    ));
}

#[tokio::test]
async fn resolve_is_the_authoritative_gate_before_connect() {
    // Legacy resolver seam: an authoritative OFFLINE result with no local
    // configured endpoint fails closed and never fabricates a Direct path.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let control = StubControl::new(ResolveStatus::Offline, None);
    *state.relay.control.write().await = Some(control);
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let result = attempt_coordinator
        .resolve("peer-b", &peer_without_endpoint())
        .await;
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::PeerOffline as i32
    ));
}

#[tokio::test]
async fn resolve_without_control_plane_fails_closed() {
    // Stage A owns local LAN/configured direct probing. Once it fails, the
    // authoritative Stage B Resolve cannot be replaced by local candidate
    // availability or a synthetic READY.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let result = attempt_coordinator
        .resolve("peer-b", &peer_without_endpoint())
        .await;
    assert!(matches!(
        result,
        Err(error) if error.code == NetworkErrorCode::RelayError as i32
    ));
}

#[tokio::test]
async fn resolve_not_ready_retries_once_then_maps_to_peer_not_ready() {
    // §10：NOT_READY gets one bounded retry; a second NOT_READY remains
    // authoritative and maps to PeerNotReady, never READY or Timeout.
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let control = StubControl::new(ResolveStatus::NotReady, None);
    *state.relay.control.write().await = Some(control.clone());
    let attempt_coordinator = ConnectivityAttemptCoordinator::new(state);
    let result = attempt_coordinator
        .resolve("peer-b", &peer_without_endpoint())
        .await;
    assert_eq!(control.resolve_calls(), 2);
    assert!(matches!(
        result,
        Err(error)
            if error.code == NetworkErrorCode::PeerNotReady as i32
                && error.retry_disposition
                    == network_protocol::RetryDisposition::RetryAfter as i32
    ));
}

#[tokio::test]
async fn active_connect_not_ready_retries_once_then_maps_to_peer_not_ready() {
    // The production connect path must apply the same bounded retry as the
    // legacy resolver seam, while never enqueueing an Offer for either
    // non-READY transaction.
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let control = StubControl::new(ResolveStatus::NotReady, None);
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(matches!(
        result,
        Err(error)
            if error.code == NetworkErrorCode::PeerNotReady as i32
                && error.retry_disposition
                    == network_protocol::RetryDisposition::RetryAfter as i32
    ));
    assert_eq!(control.resolve_calls(), 2);
    assert!(
        control.first_resolve_saw_owned_session(),
        "NOT_READY Resolve must still observe the owned local Session"
    );
    assert_eq!(
        control.connectivity_calls(),
        0,
        "NOT_READY transactions must not enqueue ConnectivityOffer"
    );
    assert_eq!(
        control.reserve_calls(),
        0,
        "NOT_READY transactions must not enqueue ReserveRelay"
    );
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "a pre-Offer Resolve/status failure must retire the newly owned Session"
    );
}
