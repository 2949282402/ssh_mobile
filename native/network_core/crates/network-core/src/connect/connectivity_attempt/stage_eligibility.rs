use super::*;

pub(super) struct ConnectivityStageEligibility;

/// Convert the control transaction's Resolve response into the coordinator's
/// typed resolver result. Keep the status mapping here so test control planes
/// and future implementations cannot turn a non-READY response into a
/// synthetic usable peer.
impl ConnectivityStageEligibility {
    pub(super) fn ready_peer_from_coordination(
        response: &ResolvePeerResponse,
        peer_id: &str,
    ) -> Result<ResolvedPeer, ProtocolError> {
        match network_relay::v2::ResolveStatus::try_from(response.status) {
            Ok(network_relay::v2::ResolveStatus::Ready) => {
                let Some(discovery) = response.discovery.clone() else {
                    return Err(protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        "Relay coordination returned READY without discovery",
                        "connect",
                        peer_id,
                    ));
                };
                Ok(ResolvedPeer::Ready {
                    discovery: Some(discovery),
                })
            }
            Ok(network_relay::v2::ResolveStatus::Offline) => Err(protocol_error_with_peer(
                NetworkErrorCode::PeerOffline,
                "Relay peer is offline",
                "connect",
                peer_id,
            )),
            Ok(network_relay::v2::ResolveStatus::NotReady) => Err(protocol_error_with_retry(
                NetworkErrorCode::PeerNotReady,
                "Relay peer discovery is not ready",
                "connect",
                Some(peer_id),
                network_protocol::RetryDisposition::RetryAfter,
                (response.retry_after_ms / 1000).max(1),
            )),
            Ok(network_relay::v2::ResolveStatus::Unknown)
            | Ok(network_relay::v2::ResolveStatus::Unspecified)
            | Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay peer resolution is unavailable",
                "connect",
                peer_id,
            )),
        }
    }
}

/// Stage C is a closed gate: the resolver must have returned an authoritative
/// READY snapshot, the peer must advertise the frozen RelayData capability,
/// the requested business capability must be carried by the Relay profile,
/// the Relay path must use Required E2EE, and the overall connect budget must
/// still have time for reservation admission.
impl ConnectivityStageEligibility {
    /// Preserve the authoritative Resolve status after Stage A has already tried
    /// configured/fresh direct candidates. A configured endpoint cannot turn an
    /// OFFLINE/NOT_READY/UNKNOWN result into a synthetic READY peer.
    #[allow(dead_code)]
    pub(super) fn authoritative_resolve_or_error(
        peer_id: &str,
        result: Result<ResolvedPeer, ProtocolError>,
    ) -> Result<ResolvedPeer, ProtocolError> {
        match result {
            Ok(ResolvedPeer::Ready {
                discovery: Some(discovery),
            }) => Ok(ResolvedPeer::Ready {
                discovery: Some(discovery),
            }),
            Ok(ResolvedPeer::Ready { discovery: None }) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay returned READY without an authoritative discovery snapshot",
                "connect",
                peer_id,
            )),
            Ok(ResolvedPeer::Offline) => Err(protocol_error_with_peer(
                NetworkErrorCode::PeerOffline,
                "Relay peer is offline",
                "connect",
                peer_id,
            )),
            Ok(ResolvedPeer::NotReady { retry_after_ms }) => Err(protocol_error_with_retry(
                NetworkErrorCode::PeerNotReady,
                "Relay peer discovery is not ready",
                "connect",
                Some(peer_id),
                network_protocol::RetryDisposition::RetryAfter,
                (retry_after_ms / 1000).max(1),
            )),
            Ok(ResolvedPeer::Unknown { .. }) => Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "Relay peer resolution is unavailable",
                "connect",
                peer_id,
            )),
            Err(error) => Err(error),
        }
    }

    pub(super) fn relay_fallback_is_eligible(
        resolved: &ResolvedPeer,
        requested_capability: u8,
        e2ee_policy: network_protocol::E2eePolicy,
        connect_deadline: Instant,
    ) -> bool {
        if Instant::now() >= connect_deadline
            || e2ee_policy != network_protocol::E2eePolicy::Required
        {
            return false;
        }
        let ResolvedPeer::Ready {
            discovery: Some(discovery),
        } = resolved
        else {
            return false;
        };
        if discovery.runtime_epoch.is_none() || discovery.revision == 0 {
            return false;
        }
        let relay_advertised = discovery
            .transport_capabilities
            .iter()
            .filter_map(|value| network_relay::v2::TransportCapability::try_from(*value).ok())
            .any(|capability| capability == network_relay::v2::TransportCapability::RelayData);
        let relay_supports_request = crate::connection::ConnectionProfile::for_route(
            RouteType::Relay,
        )
        .is_some_and(|profile| {
            profile_capability_mask(profile) & requested_capability == requested_capability
        });
        relay_advertised && relay_supports_request
    }
}
