use super::*;

pub(super) struct CandidateSnapshotPolicy;

impl CandidateSnapshotPolicy {
    pub(super) fn nat_runtime_epoch(epoch: &RuntimeEpoch) -> NatRuntimeEpoch {
        NatRuntimeEpoch {
            high: epoch.high,
            low: epoch.low,
        }
    }

    pub(super) fn runtime_epoch_from_nat(epoch: NatRuntimeEpoch) -> RuntimeEpoch {
        RuntimeEpoch {
            high: epoch.high,
            low: epoch.low,
        }
    }

    pub(super) fn resolved_runtime_epoch(resolved: &ResolvedPeer) -> Option<RuntimeEpoch> {
        match resolved {
            ResolvedPeer::Ready { discovery } => discovery
                .as_ref()
                .and_then(|snapshot| snapshot.runtime_epoch.clone()),
            _ => None,
        }
    }
}

impl CandidateSnapshotPolicy {
    pub(super) fn resolved_snapshot(resolved: &ResolvedPeer) -> Option<&DiscoverySnapshot> {
        match resolved {
            ResolvedPeer::Ready { discovery } => discovery.as_ref(),
            ResolvedPeer::Offline
            | ResolvedPeer::NotReady { .. }
            | ResolvedPeer::Unknown { .. } => None,
        }
    }

    pub(super) fn snapshot_candidate_transports(
        snapshot: &DiscoverySnapshot,
    ) -> Vec<CandidateTransport> {
        snapshot
            .transport_capabilities
            .iter()
            .filter_map(|value| network_relay::v2::TransportCapability::try_from(*value).ok())
            .filter_map(|capability| match capability {
                network_relay::v2::TransportCapability::Quic => Some(CandidateTransport::Quic),
                network_relay::v2::TransportCapability::Tcp => Some(CandidateTransport::Tcp),
                network_relay::v2::TransportCapability::UdpDatagram => {
                    Some(CandidateTransport::UdpDatagram)
                }
                network_relay::v2::TransportCapability::Websocket => {
                    Some(CandidateTransport::Websocket)
                }
                network_relay::v2::TransportCapability::RelayData => {
                    Some(CandidateTransport::Relay)
                }
                network_relay::v2::TransportCapability::Unspecified
                | network_relay::v2::TransportCapability::Webrtc => None,
            })
            .collect()
    }

    pub(super) fn snapshot_candidate_payloads(
        snapshot: &DiscoverySnapshot,
    ) -> Vec<CandidatePayloadV2> {
        let advertised_transports = Self::snapshot_candidate_transports(snapshot);
        snapshot
            .candidate_bundle
            .as_ref()
            .into_iter()
            .flat_map(|bundle| bundle.candidates.iter())
            .filter_map(|bytes| serde_json::from_slice::<CandidateAdvertisement>(bytes).ok())
            .filter_map(|advertisement| {
                let mut transports = match advertisement.kind {
                    // STUN mappings are shared by QUIC and UDP datagrams. Never
                    // let a global TCP/WS capability turn them into TCP/WS probes.
                    CandidateKind::ServerReflexive => network_nat::STUN_SRFLX_TRANSPORTS.to_vec(),
                    CandidateKind::Relay => vec![CandidateTransport::Relay],
                    _ => advertised_transports
                        .iter()
                        .copied()
                        .filter(|transport| *transport != CandidateTransport::Relay)
                        .collect(),
                };
                // Empty capability lists are tolerated only for older local test
                // fixtures that predate the capability field. A RelayData-only
                // advertisement must not be turned into a synthetic QUIC direct
                // candidate.
                if transports.is_empty() && advertised_transports.is_empty() {
                    transports.push(CandidateTransport::Quic);
                }
                if transports.is_empty() {
                    return None;
                }
                let candidate = CandidatePayloadV2 {
                    version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                    candidate_id: advertisement.candidate_id,
                    endpoint: advertisement.endpoint,
                    kind: advertisement.kind,
                    transport_capabilities: transports,
                    priority: advertisement.priority,
                    interface: advertisement.interface,
                    generation: advertisement.generation,
                };
                candidate.validate().ok().map(|_| candidate)
            })
            .take(network_nat::MAX_CANDIDATE_PAYLOAD_ENTRIES)
            .collect()
    }

    pub(super) fn candidate_from_v2(candidate: &CandidatePayloadV2) -> Option<Candidate> {
        if !candidate.is_direct_probe_eligible() {
            return None;
        }
        let mut direct = Candidate::new(
            candidate.endpoint,
            candidate.kind,
            candidate.interface.clone(),
        );
        direct.candidate_id = candidate.candidate_id.clone();
        direct.priority = candidate.priority;
        direct.generation = candidate.generation;
        Some(direct)
    }

    /// Build the complete uncoordinated Stage A target set. Only a fresh remote
    /// cache entry is read; configured endpoints are local operator input and are
    /// always appended. The cache carries the remote LAN/STUN candidates gathered
    /// from the peer, while Relay candidates are excluded before the Direct race.
    pub(super) fn stage_a_direct_candidates(
        cache: Option<&ResolvedCandidateCache>,
        peer: &crate::runtime::PeerConfig,
        now: Instant,
    ) -> (Vec<Candidate>, Option<RuntimeEpoch>) {
        let (mut candidates, remote_epoch) = match cache {
            Some(cache) => {
                let fresh = cache.stage_a_candidates_at(now);
                let candidates = fresh
                    .unwrap_or_default()
                    .iter()
                    .filter_map(Self::candidate_from_v2)
                    .collect::<Vec<_>>();
                let remote_epoch = fresh.map(|_| RuntimeEpoch {
                    high: cache.runtime_epoch.high,
                    low: cache.runtime_epoch.low,
                });
                (candidates, remote_epoch)
            }
            None => (Vec::new(), None),
        };
        Self::append_configured_endpoint(&mut candidates, peer);
        candidates.retain(|candidate| candidate.kind != CandidateKind::Relay);
        candidates.sort_by(|left, right| {
            Self::candidate_order(left)
                .cmp(&Self::candidate_order(right))
                .then_with(|| right.priority.cmp(&left.priority))
                .then_with(|| left.candidate_id.cmp(&right.candidate_id))
        });
        (candidates, remote_epoch)
    }

    pub(super) async fn update_remote_candidate_cache(
        state: &RuntimeState,
        peer_id: &str,
        snapshot: Option<&DiscoverySnapshot>,
        ready_presence_ttl: Option<Duration>,
    ) {
        let Some(snapshot) = snapshot else {
            return;
        };
        let Some(runtime_epoch) = snapshot.runtime_epoch.as_ref() else {
            return;
        };
        let candidate_snapshot = ResolvedCandidateSnapshot {
            runtime_epoch: Self::nat_runtime_epoch(runtime_epoch),
            revision: u64::from(snapshot.revision),
            candidates: Self::snapshot_candidate_payloads(snapshot),
            server_presence_ttl: ready_presence_ttl,
        };
        let learned_at = Instant::now();
        let mut cache = state.remote_candidate_cache.write().await;
        match cache.get_mut(peer_id) {
            Some(existing) => {
                if let Err(error) = existing.apply(candidate_snapshot, learned_at) {
                    tracing::debug!(%peer_id, error = %error, "ignored inconsistent remote candidate cache snapshot");
                }
            }
            None => match ResolvedCandidateCache::from_snapshot(candidate_snapshot, learned_at) {
                Ok(value) => {
                    cache.insert(peer_id.to_string(), value);
                }
                Err(error) => {
                    tracing::debug!(%peer_id, error = %error, "ignored invalid remote candidate cache snapshot");
                }
            },
        }
    }

    pub(super) fn discovery_snapshot_candidates(snapshot: &DiscoverySnapshot) -> Vec<Candidate> {
        Self::snapshot_candidate_payloads(snapshot)
            .into_iter()
            .filter_map(|candidate| Self::candidate_from_v2(&candidate))
            .collect()
    }

    pub(super) fn resolved_candidates(
        resolved: &ResolvedPeer,
        peer: &crate::runtime::PeerConfig,
    ) -> Vec<Candidate> {
        let mut candidates = Vec::new();
        if let Some(snapshot) = Self::resolved_snapshot(resolved) {
            candidates.extend(Self::discovery_snapshot_candidates(snapshot));
        }
        Self::append_configured_endpoint(&mut candidates, peer);
        candidates.sort_by(|left, right| {
            Self::candidate_order(left)
                .cmp(&Self::candidate_order(right))
                .then_with(|| right.priority.cmp(&left.priority))
                .then_with(|| left.candidate_id.cmp(&right.candidate_id))
        });
        candidates
    }

    /// Direct candidate order is deterministic and deliberately independent of the
    /// order in which a remote snapshot happened to arrive. The configured endpoint
    /// is a last-resort direct candidate after the advertised LAN/public/reflexive
    /// candidates, while the remaining kinds keep their lower-priority tail.
    pub(super) fn candidate_order(candidate: &Candidate) -> u8 {
        if candidate.interface_name == "peer-configured" {
            return 3;
        }
        match candidate.kind {
            CandidateKind::Lan => 0,
            CandidateKind::PublicIpv6 => 1,
            CandidateKind::ServerReflexive => 2,
            CandidateKind::PortMapped => 4,
            CandidateKind::Relay => 5,
        }
    }

    /// 收集本地候选（local PathManager 已 gather 的候选）。
    pub(super) async fn collect_local_candidates(state: Arc<RuntimeState>) -> Vec<Candidate> {
        let Some(manager) = state.local_path_manager.read().await.clone() else {
            return Vec::new();
        };
        manager
            .ranked_candidates()
            .await
            .into_iter()
            .take(MAX_CANDIDATES_PER_SIGNAL)
            .collect()
    }

    /// 追加手工配置的 endpoint 候选（peer.endpoint，LAN/显式直连）。
    pub(super) fn append_configured_endpoint(
        candidates: &mut Vec<Candidate>,
        peer: &crate::runtime::PeerConfig,
    ) {
        if let Some(endpoint) = peer.endpoint {
            if !candidates
                .iter()
                .any(|candidate| candidate.endpoint == endpoint)
            {
                candidates.push(Candidate::new(
                    endpoint,
                    crate::peer::candidate_kind_for(endpoint),
                    "peer-configured".into(),
                ));
            }
        }
    }
}
