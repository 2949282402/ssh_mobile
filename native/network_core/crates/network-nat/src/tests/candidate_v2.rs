use super::*;

fn epoch(high: u64, low: u64) -> RuntimeEpoch {
    RuntimeEpoch { high, low }
}

fn candidate(id: &str, port: u16, kind: CandidateKind) -> CandidatePayloadV2 {
    let transport_capabilities = if kind == CandidateKind::Relay {
        vec![CandidateTransport::Relay]
    } else {
        vec![CandidateTransport::Quic]
    };
    CandidatePayloadV2 {
        version: CANDIDATE_PAYLOAD_VERSION,
        candidate_id: id.into(),
        endpoint: SocketAddr::from(([192, 168, 1, 10], port)),
        kind,
        transport_capabilities,
        priority: 100,
        interface: "wifi".into(),
        generation: 1,
    }
}

fn snapshot(
    epoch: RuntimeEpoch,
    revision: u64,
    ttl: Option<Duration>,
) -> ResolvedCandidateSnapshot {
    ResolvedCandidateSnapshot {
        runtime_epoch: epoch,
        revision,
        candidates: vec![candidate("lan-1", 41001, CandidateKind::Lan)],
        server_presence_ttl: ttl,
    }
}

#[test]
fn candidate_v2_normalizes_transport_order_and_rejects_srflx_tcp() {
    let mut value = candidate("srflx", 41001, CandidateKind::ServerReflexive);
    value.transport_capabilities = vec![CandidateTransport::Tcp, CandidateTransport::Quic];
    assert_eq!(
        value.validate(),
        Err(CandidatePayloadError::SrflxTransportMismatch)
    );

    value.transport_capabilities = vec![CandidateTransport::UdpDatagram, CandidateTransport::Quic];
    let normalized = value.clone().normalized().expect("valid srflx candidate");
    assert_eq!(
        normalized.transport_capabilities[0],
        CandidateTransport::Quic
    );

    value.transport_capabilities = vec![CandidateTransport::Quic, CandidateTransport::Relay];
    assert_eq!(
        value.validate(),
        Err(CandidatePayloadError::SrflxTransportMismatch)
    );
}

#[test]
fn relay_candidate_is_never_direct_probe_eligible() {
    let value = candidate("relay", 41001, CandidateKind::Relay);
    assert!(value.validate().is_ok());
    assert!(!value.is_direct_probe_eligible());
    assert!(value.direct_transports().is_empty());
}

#[test]
fn cache_uses_monotonic_age_and_server_confirmed_ttl() {
    let learned_at = Instant::now();
    let mut cache = ResolvedCandidateCache::from_snapshot(
        snapshot(epoch(1, 1), 1, Some(Duration::from_secs(5))),
        learned_at,
    )
    .expect("cache");
    assert_eq!(cache.ttl(), Duration::from_secs(5));
    assert!(cache.is_fresh_at(learned_at + Duration::from_secs(5)));
    assert!(!cache.is_fresh_at(learned_at + Duration::from_secs(5) + Duration::from_nanos(1)));
    assert!(cache
        .stage_a_candidates_at(learned_at + Duration::from_secs(5))
        .is_some());
    assert!(cache
        .stage_a_candidates_at(learned_at + Duration::from_secs(6))
        .is_none());

    let refreshed = cache
        .apply(
            snapshot(epoch(1, 1), 1, Some(Duration::from_secs(30))),
            learned_at + Duration::from_secs(6),
        )
        .expect("same snapshot refresh");
    assert_eq!(refreshed, CacheUpdate::Refreshed);
    assert_eq!(cache.ttl(), Duration::from_secs(30));
    assert!(cache.is_fresh_at(learned_at + Duration::from_secs(35)));
}

#[test]
fn cache_uses_sixty_second_fallback_when_ready_ttl_is_missing() {
    let cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 1, None), Instant::now())
            .expect("cache");
    assert_eq!(cache.ttl(), DEFAULT_REMOTE_CANDIDATE_CACHE_TTL);
    assert_eq!(cache.ttl(), Duration::from_secs(60));

    let zero_ttl_cache = ResolvedCandidateCache::from_snapshot(
        snapshot(epoch(1, 1), 1, Some(Duration::ZERO)),
        Instant::now(),
    )
    .expect("zero TTL cache");
    assert_eq!(zero_ttl_cache.ttl(), Duration::from_secs(60));
}

#[test]
fn expired_stage_b_resolve_snapshot_refreshes_cache() {
    let learned_at = Instant::now();
    let mut cache = ResolvedCandidateCache::from_snapshot(
        snapshot(epoch(1, 1), 1, Some(Duration::from_secs(1))),
        learned_at,
    )
    .expect("cache");
    let resolve_at = learned_at + Duration::from_secs(2);
    assert!(cache.stage_a_candidates_at(resolve_at).is_none());

    assert_eq!(
        cache.apply(
            snapshot(epoch(1, 1), 1, Some(Duration::from_secs(5))),
            resolve_at,
        ),
        Ok(CacheUpdate::Refreshed)
    );
    assert!(cache.stage_a_candidates_at(resolve_at).is_some());
    assert_eq!(cache.ttl(), Duration::from_secs(5));
}

#[test]
fn cache_orders_revision_only_within_the_same_epoch() {
    let learned_at = Instant::now();
    let mut cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 7, None), learned_at)
            .expect("cache");
    assert_eq!(
        cache.apply(snapshot(epoch(1, 1), 6, None), learned_at),
        Ok(CacheUpdate::IgnoredStale)
    );
    assert_eq!(
        cache.apply(snapshot(epoch(2, 1), 1, None), learned_at),
        Ok(CacheUpdate::Replaced)
    );
    assert_eq!(cache.runtime_epoch, epoch(2, 1));
    assert_eq!(cache.revision, 1);
}

#[test]
fn cache_learning_point_never_moves_backwards() {
    let learned_at = Instant::now();
    let mut cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 1, None), learned_at)
            .expect("cache");
    let later = learned_at + Duration::from_secs(5);

    assert_eq!(
        cache.apply(snapshot(epoch(1, 1), 1, None), later),
        Ok(CacheUpdate::Refreshed)
    );
    assert_eq!(cache.learned_at, later);
    assert_eq!(
        cache.apply(snapshot(epoch(1, 1), 1, None), learned_at),
        Ok(CacheUpdate::Refreshed)
    );
    assert_eq!(cache.learned_at, later);
}

#[test]
fn heartbeat_does_not_refresh_candidate_learning_point() {
    let learned_at = Instant::now();
    let cache = ResolvedCandidateCache::from_snapshot(
        snapshot(epoch(1, 1), 1, Some(Duration::from_secs(60))),
        learned_at,
    )
    .expect("cache");
    let heartbeat_at = learned_at + Duration::from_secs(30);

    // Heartbeat frames carry liveness only.  They do not carry a
    // Resolve/ConnectivityAnswer snapshot and therefore cannot move the
    // cache's monotonic learning point forward.
    assert_eq!(cache.learned_at, learned_at);
    assert_eq!(cache.age_at(heartbeat_at), Duration::from_secs(30));
}

#[test]
fn same_revision_with_different_fingerprint_is_inconsistent() {
    let learned_at = Instant::now();
    let mut cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 2, None), learned_at)
            .expect("cache");
    let mut changed = snapshot(epoch(1, 1), 2, None);
    changed.candidates[0].endpoint.set_port(41002);
    assert_eq!(
        cache.apply(changed, learned_at),
        Err(CandidateCacheError::SameRevisionDifferentFingerprint)
    );
}

#[test]
fn same_revision_with_changed_candidate_metadata_is_inconsistent() {
    let learned_at = Instant::now();
    let mut cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 2, None), learned_at)
            .expect("cache");
    let mut changed = snapshot(epoch(1, 1), 2, None);
    changed.candidates[0].priority += 1;
    assert_eq!(
        cache.apply(changed, learned_at),
        Err(CandidateCacheError::SameRevisionDifferentFingerprint)
    );
}

#[test]
fn runtime_epoch_change_invalidates_before_new_snapshot_arrives() {
    let now = Instant::now();
    let mut cache =
        ResolvedCandidateCache::from_snapshot(snapshot(epoch(1, 1), 1, None), now).expect("cache");
    assert!(cache.invalidate_for_remote_epoch(epoch(2, 1), now + Duration::from_secs(1)));
    assert_eq!(cache.pending_remote_epoch(), Some(epoch(2, 1)));
    assert!(cache
        .stage_a_candidates_at(now + Duration::from_secs(1))
        .is_none());

    assert_eq!(
        cache.apply(snapshot(epoch(1, 1), 2, None), now + Duration::from_secs(2)),
        Ok(CacheUpdate::IgnoredStale)
    );
    assert_eq!(
        cache.apply(snapshot(epoch(2, 1), 1, None), now + Duration::from_secs(3)),
        Ok(CacheUpdate::Replaced)
    );
    assert_eq!(cache.pending_remote_epoch(), None);
}

#[test]
fn candidate_payload_round_trips_and_keeps_generation_in_attempt_key() {
    let value = candidate("stable-id", 41001, CandidateKind::Lan);
    let encoded = value.encode().expect("valid payload");
    let decoded = CandidatePayloadV2::decode(&encoded).expect("decode payload");
    assert_eq!(decoded, value);
    assert_eq!(
        decoded.attempt_key(),
        CandidateAttemptKey {
            candidate_id: "stable-id".into(),
            endpoint: "192.168.1.10:41001".parse().unwrap(),
            generation: 1,
        }
    );
}

#[test]
fn direct_probe_queue_requeues_same_id_when_endpoint_or_generation_changes() {
    let mut queue = DirectProbeQueue::default();
    let first = candidate("stable-id", 41001, CandidateKind::Lan);
    queue
        .reconcile(vec![first.clone()])
        .expect("first snapshot");
    assert_eq!(queue.pending().len(), 1);
    let started = queue.pop_next().expect("first candidate");
    assert_eq!(started.candidate.endpoint.port(), 41001);

    let mut endpoint_update = first.clone();
    endpoint_update.endpoint.set_port(41002);
    queue
        .reconcile(vec![endpoint_update.clone()])
        .expect("endpoint update");
    assert_eq!(queue.pending().len(), 1);
    assert_eq!(queue.pending()[0].candidate.endpoint.port(), 41002);

    let mut generation_update = endpoint_update;
    generation_update.generation = 2;
    queue
        .reconcile(vec![generation_update])
        .expect("generation update");
    assert_eq!(queue.pending().len(), 1);
    assert_eq!(queue.pending()[0].candidate.generation, 2);
}

#[test]
fn relay_payload_is_rejected_if_it_claims_a_direct_transport() {
    let mut relay = candidate("relay", 41001, CandidateKind::Relay);
    relay.transport_capabilities = vec![CandidateTransport::Relay, CandidateTransport::Quic];
    assert_eq!(
        relay.validate(),
        Err(CandidatePayloadError::RelayTransportMismatch)
    );
    assert!(
        qualify_direct_probe(vec![candidate("relay", 41001, CandidateKind::Relay)])
            .unwrap()
            .is_empty()
    );
}
