#[tokio::test]
async fn stage_b_rejects_an_unusable_control_plane_before_session_ownership() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    control.set_usable(false);
    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::RelayError as i32
    ));
    assert_eq!(control.resolve_calls(), 0);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "control-plane admission must precede local Session ownership"
    );
}

#[tokio::test(start_paused = true)]
async fn overall_connect_budget_maps_a_hanging_control_transaction_to_timeout() {
    let (state, _event_rx, control) = configured_reuse_state().await;
    let hanging = StubControl::timeout();
    *state.relay.control.write().await = Some(hanging);
    let coordinator = ConnectivityAttemptCoordinator::new(Arc::clone(&state));
    let task = tokio::spawn(async move {
        coordinator
            .connect_with_capabilities("peer-b", DEFAULT_CONNECTION_CAPABILITY)
            .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(crate::connect::OVERALL_CONNECT_BUDGET + Duration::from_millis(1)).await;
    let result = task.await.expect("connect task");
    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::Timeout as i32
    ));
    for _ in 0..10 {
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
    assert!(
        state
            .connection_sessions
            .current_session_id("peer-b")
            .await
            .is_none(),
        "cancelling the bounded connect must retire its Session"
    );
    drop(control);
}

#[tokio::test]
async fn stage_a_direct_failure_releases_owned_session_before_authoritative_offline() {
    let (state, _event_rx, _configured_control) = configured_reuse_state().await;
    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("closed direct endpoint"),
        CandidateKind::Lan,
        "stage-a-unreachable".into(),
    )
    .with_generation(1);
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 9, low: 10 },
            revision: 1,
            candidates: vec![CandidatePayloadV2::from_candidate(
                &candidate,
                vec![CandidateTransport::Quic],
            )],
            server_presence_ttl: Some(Duration::from_secs(30)),
        },
        Instant::now(),
    )
    .expect("valid Stage A cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);
    let control = StubControl::new(ResolveStatus::Offline, None);
    *state.relay.control.write().await = Some(control.clone());
    control.observe_session_ownership(Arc::clone(&state));

    let result = ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .connect_with_class("peer-b", CommunicationClass::ReliableMessage)
        .await;

    assert!(matches!(
        result,
        Err(ref error) if error.code == NetworkErrorCode::PeerOffline as i32
    ));
    assert_eq!(control.resolve_calls(), 1);
    assert_eq!(
        state.connection_sessions.current_session_id("peer-b").await,
        None,
        "failed uncoordinated Direct must not leak its temporary Session"
    );
}

#[test]
fn direct_candidates_are_ranked_before_the_staggered_race() {
    let mut candidates = [
        Candidate::new(
            "198.51.100.4:41004".parse().unwrap(),
            CandidateKind::ServerReflexive,
            "srflx".into(),
        ),
        Candidate::new(
            "192.168.1.4:41001".parse().unwrap(),
            CandidateKind::Lan,
            "lan".into(),
        ),
        Candidate::new(
            "127.0.0.1:41000".parse().unwrap(),
            CandidateKind::Lan,
            "peer-configured".into(),
        ),
        Candidate::new(
            "[2001:db8::4]:41002".parse().unwrap(),
            CandidateKind::PublicIpv6,
            "ipv6".into(),
        ),
    ];
    candidates.sort_by(|left, right| {
        CandidateSnapshotPolicy::candidate_order(left)
            .cmp(&CandidateSnapshotPolicy::candidate_order(right))
            .then_with(|| right.priority.cmp(&left.priority))
            .then_with(|| left.candidate_id.cmp(&right.candidate_id))
    });
    assert_eq!(candidates[0].interface_name, "lan");
    assert_eq!(candidates[1].interface_name, "ipv6");
    assert_eq!(candidates[2].interface_name, "srflx");
    assert_eq!(candidates[3].interface_name, "peer-configured");
}

#[test]
fn stage_a_uses_fresh_cache_and_configured_direct_candidates_only() {
    let learned_at = Instant::now();
    let cache = ResolvedCandidateCache::from_snapshot(
        ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 11, low: 12 },
            revision: 4,
            candidates: vec![
                CandidatePayloadV2 {
                    version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                    candidate_id: "lan-remote".into(),
                    endpoint: "192.168.1.10:41001".parse().unwrap(),
                    kind: CandidateKind::Lan,
                    transport_capabilities: vec![CandidateTransport::Quic],
                    priority: 100,
                    interface: "wifi".into(),
                    generation: 1,
                },
                CandidatePayloadV2 {
                    version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                    candidate_id: "srflx-remote".into(),
                    endpoint: "198.51.100.10:41002".parse().unwrap(),
                    kind: CandidateKind::ServerReflexive,
                    transport_capabilities: network_nat::STUN_SRFLX_TRANSPORTS.to_vec(),
                    priority: 40,
                    interface: "stun".into(),
                    generation: 7,
                },
            ],
            server_presence_ttl: Some(Duration::from_secs(5)),
        },
        learned_at,
    )
    .expect("valid Stage A cache");
    let peer = crate::runtime::PeerConfig {
        endpoint: Some("192.168.1.20:41003".parse().unwrap()),
        identity_public_key: [0u8; 32],
        e2e_public_key: [1u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    };

    let (fresh, remote_epoch) = CandidateSnapshotPolicy::stage_a_direct_candidates(
        Some(&cache),
        &peer,
        learned_at + Duration::from_secs(4),
    );
    assert_eq!(remote_epoch, Some(RuntimeEpoch { high: 11, low: 12 }));
    assert_eq!(
        fresh
            .iter()
            .map(|candidate| candidate.interface_name.as_str())
            .collect::<Vec<_>>(),
        vec!["wifi", "stun", "peer-configured"]
    );
    assert_eq!(fresh[1].generation, 7);
    assert!(fresh
        .iter()
        .all(|candidate| candidate.kind != CandidateKind::Relay));

    let (stale, stale_epoch) = CandidateSnapshotPolicy::stage_a_direct_candidates(
        Some(&cache),
        &peer,
        learned_at + Duration::from_secs(5) + Duration::from_nanos(1),
    );
    assert_eq!(stale_epoch, None);
    assert_eq!(stale.len(), 1);
    assert_eq!(stale[0].interface_name, "peer-configured");
}

#[test]
fn snapshot_candidate_capabilities_keep_srflx_udp_only_and_drop_relay_from_direct() {
    let lan = Candidate::new(
        "192.168.1.30:41004".parse().unwrap(),
        CandidateKind::Lan,
        "wifi".into(),
    )
    .with_generation(1);
    let srflx = Candidate::new(
        "198.51.100.30:41005".parse().unwrap(),
        CandidateKind::ServerReflexive,
        "stun".into(),
    )
    .with_generation(1);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 13, low: 14 }),
        revision: 2,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::Quic as i32,
            network_relay::v2::TransportCapability::Tcp as i32,
            network_relay::v2::TransportCapability::Websocket as i32,
            network_relay::v2::TransportCapability::UdpDatagram as i32,
            network_relay::v2::TransportCapability::RelayData as i32,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                serde_json::to_vec(&lan.advertisement()).unwrap(),
                serde_json::to_vec(&srflx.advertisement()).unwrap(),
            ],
        }),
        published_at_ms: 0,
    };

    let payloads = CandidateSnapshotPolicy::snapshot_candidate_payloads(&snapshot);
    let lan_payload = payloads
        .iter()
        .find(|candidate| candidate.kind == CandidateKind::Lan)
        .expect("LAN payload");
    assert!(!lan_payload
        .transport_capabilities
        .contains(&CandidateTransport::Relay));
    let srflx_payload = payloads
        .iter()
        .find(|candidate| candidate.kind == CandidateKind::ServerReflexive)
        .expect("STUN payload");
    assert_eq!(
        srflx_payload.transport_capabilities,
        network_nat::STUN_SRFLX_TRANSPORTS.to_vec()
    );
}

#[test]
fn malformed_and_relay_only_snapshots_never_become_direct_candidates() {
    let lan = Candidate::new(
        "192.168.1.31:41004".parse().expect("LAN endpoint"),
        CandidateKind::Lan,
        "lan-fallback".into(),
    )
    .with_generation(2);
    let relay = Candidate::new(
        "127.0.0.1:41005".parse().expect("Relay endpoint"),
        CandidateKind::Relay,
        "relay-only".into(),
    )
    .with_generation(3);
    let snapshot = DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch { high: 19, low: 20 }),
        revision: 5,
        transport_capabilities: vec![
            network_relay::v2::TransportCapability::RelayData as i32,
            999,
        ],
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![
                b"not-json".to_vec(),
                serde_json::to_vec(&lan.advertisement()).expect("LAN advertisement"),
                serde_json::to_vec(&relay.advertisement()).expect("Relay advertisement"),
            ],
        }),
        published_at_ms: 0,
    };

    let payloads = CandidateSnapshotPolicy::snapshot_candidate_payloads(&snapshot);
    assert_eq!(
        payloads.len(),
        1,
        "RelayData-only snapshots drop direct LAN candidates"
    );
    assert_eq!(payloads[0].kind, CandidateKind::Relay);
    assert!(CandidateSnapshotPolicy::discovery_snapshot_candidates(&snapshot).is_empty());

    let legacy_snapshot = DiscoverySnapshot {
        runtime_epoch: snapshot.runtime_epoch,
        revision: snapshot.revision,
        transport_capabilities: Vec::new(),
        candidate_bundle: Some(network_relay::v2::CandidateBundle {
            candidates: vec![serde_json::to_vec(&lan.advertisement()).expect("LAN advertisement")],
        }),
        published_at_ms: 0,
    };
    let legacy = CandidateSnapshotPolicy::snapshot_candidate_payloads(&legacy_snapshot);
    assert_eq!(legacy.len(), 1);
    assert_eq!(
        legacy[0].transport_capabilities,
        vec![CandidateTransport::Quic]
    );
}

#[test]
fn candidate_order_keeps_configured_and_tail_kinds_deterministic() {
    let port_mapped = Candidate::new(
        "203.0.113.31:41006".parse().expect("mapped endpoint"),
        CandidateKind::PortMapped,
        "mapped".into(),
    );
    let relay = Candidate::new(
        "127.0.0.1:41007".parse().expect("relay endpoint"),
        CandidateKind::Relay,
        "relay".into(),
    );
    let configured = Candidate::new(
        "192.168.1.32:41008".parse().expect("configured endpoint"),
        CandidateKind::Lan,
        "peer-configured".into(),
    );
    assert_eq!(CandidateSnapshotPolicy::candidate_order(&configured), 3);
    assert_eq!(CandidateSnapshotPolicy::candidate_order(&port_mapped), 4);
    assert_eq!(CandidateSnapshotPolicy::candidate_order(&relay), 5);
}

#[test]
fn relay_fallback_gate_requires_ready_relay_policy_and_budget() {
    let ready = ResolvedPeer::Ready {
        discovery: Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 15, low: 16 }),
            revision: 3,
            transport_capabilities: vec![network_relay::v2::TransportCapability::RelayData as i32],
            candidate_bundle: None,
            published_at_ms: 0,
        }),
    };
    let deadline = Instant::now() + Duration::from_secs(1);
    assert!(ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ready,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ready,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Disabled,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ready,
        crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    let no_relay_capability = ResolvedPeer::Ready {
        discovery: Some(DiscoverySnapshot {
            runtime_epoch: Some(RuntimeEpoch { high: 17, low: 18 }),
            revision: 4,
            transport_capabilities: Vec::new(),
            candidate_bundle: None,
            published_at_ms: 0,
        }),
    };
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &no_relay_capability,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ResolvedPeer::NotReady { retry_after_ms: 0 },
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ResolvedPeer::Offline,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ResolvedPeer::Unknown { retry_after_ms: 0 },
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        deadline,
    ));
    assert!(!ConnectivityStageEligibility::relay_fallback_is_eligible(
        &ready,
        crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        network_protocol::E2eePolicy::Required,
        Instant::now() - Duration::from_secs(1),
    ));
}


