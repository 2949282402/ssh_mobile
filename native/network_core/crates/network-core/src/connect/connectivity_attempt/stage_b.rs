use super::*;

impl ConnectivityAttemptCoordinator {
    /// Begin the Stage B control transaction, retrying NOT_READY exactly once.
    /// A non-READY transaction never enqueues an Offer, so replacing its
    /// attempt id on retry cannot leave a server-side waiter behind. READY is
    /// returned with the same id that will be used by the following attempt.
    pub(super) async fn begin_stage_b_transaction(
        &self,
        control: Arc<dyn crate::discovery::DiscoveryControlPlane>,
        request: StageBTransactionRequest,
    ) -> Result<(String, ConnectivityAttemptStart), ProtocolError> {
        let mut attempt_id = new_attempt_id();
        let mut coordination = control
            .begin_connectivity_attempt(
                attempt_id.clone(),
                request.peer_id.clone(),
                request.initiator_device_id.clone(),
                request.initiator_runtime_epoch.clone(),
                request.initiator_revision,
                request.initiator_snapshot.clone(),
            )
            .await
            .map_err(|error| relay_resolve_error(&error, &request.peer_id))?;

        if network_relay::v2::ResolveStatus::try_from(coordination.resolved.status)
            != Ok(network_relay::v2::ResolveStatus::NotReady)
        {
            return Ok((attempt_id, coordination));
        }

        // Bound the retry wait by the public connect budget. If no budget
        // remains, return the authoritative first NOT_READY response so the
        // normal status mapper reports PeerNotReady instead of fabricating a
        // READY result or extending the operation beyond its deadline.
        let retry = Duration::from_millis(u64::from(coordination.resolved.retry_after_ms))
            .min(crate::connect::NOT_READY_WAIT);
        let remaining = request
            .connect_deadline
            .saturating_duration_since(Instant::now());
        if retry >= remaining {
            return Ok((attempt_id, coordination));
        }
        tokio::time::sleep(retry).await;
        if Instant::now() >= request.connect_deadline {
            return Ok((attempt_id, coordination));
        }

        // The first NOT_READY path has no Offer and therefore no active
        // server-side coordination ticket. A fresh attempt id keeps each
        // ConnectivityAttempt independently scoped on the retry.
        attempt_id = new_attempt_id();
        let retry_peer_id = request.peer_id.clone();
        coordination = control
            .begin_connectivity_attempt(
                attempt_id.clone(),
                retry_peer_id,
                request.initiator_device_id,
                request.initiator_runtime_epoch,
                request.initiator_revision,
                request.initiator_snapshot,
            )
            .await
            .map_err(|error| relay_resolve_error(&error, &request.peer_id))?;
        Ok((attempt_id, coordination))
    }

    /// Resolve 阶段：控制面可用时走服务器权威解析（§10）。Configured/local
    /// candidates belong only to Stage A; a non-READY Resolve result never
    /// becomes a synthetic READY and therefore cannot unlock Stage C Relay.
    #[allow(dead_code)] // compatibility seam for resolver-focused unit tests
    pub(super) async fn resolve(
        &self,
        peer_id: &str,
        _peer: &crate::runtime::PeerConfig,
    ) -> Result<ResolvedPeer, ProtocolError> {
        let Some(control) = self.state.relay.control.read().await.clone() else {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "authoritative Resolve is unavailable",
                "connect",
                peer_id,
            ));
        };
        if !control.is_usable().await {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "authoritative Resolve control plane is unavailable",
                "connect",
                peer_id,
            ));
        }
        let resolver = DiscoveryResolver::new(control);
        let result = match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
            Ok(Ok(ResolvedPeer::NotReady { retry_after_ms })) => {
                // NOT_READY is the only status with a bounded retry. A second
                // NOT_READY remains authoritative and must not become READY.
                let retry = Duration::from_millis(u64::from(retry_after_ms))
                    .min(crate::connect::NOT_READY_WAIT);
                tokio::time::sleep(retry).await;
                match tokio::time::timeout(RESOLVE_TIMEOUT, resolver.resolve(peer_id)).await {
                    Ok(Ok(resolved)) => Ok(resolved),
                    Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
                    Err(_) => Err(protocol_error_with_peer(
                        NetworkErrorCode::Timeout,
                        "Resolve retry timed out",
                        "connect",
                        peer_id,
                    )),
                }
            }
            Ok(Ok(resolved)) => Ok(resolved),
            Ok(Err(error)) => Err(relay_resolve_error(&error, peer_id)),
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Resolve timed out",
                "connect",
                peer_id,
            )),
        };
        ConnectivityStageEligibility::authoritative_resolve_or_error(peer_id, result)
    }
}
