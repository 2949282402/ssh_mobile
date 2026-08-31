use super::*;

impl ConnectivityAttemptCoordinator {
    /// Wait for the answer from the already-enqueued ConnectivityOffer
    /// without blocking the Direct window.
    pub(super) fn spawn_coordination(
        &self,
        coordination: ConnectivityAttemptStart,
        peer_id: String,
        attempt_id: String,
        attempt: Arc<Mutex<ConnectivityAttempt>>,
        preserved_direct_candidates: Vec<Candidate>,
        ready_presence_ttl: Option<Duration>,
    ) -> Result<watch::Receiver<Option<Vec<Candidate>>>, ProtocolError> {
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        let state = Arc::clone(&self.state);
        let supervisor = Arc::clone(&state.task_supervisor);
        let error_peer_id = peer_id.clone();
        let task = supervisor.spawn_runtime("connectivity-coordination", async move {
            match coordination.wait_for_answer().await {
                Ok(answer) => {
                    if answer.attempt_id != attempt_id {
                        tracing::debug!(
                            peer_id = %peer_id,
                            expected_attempt_id = %attempt_id,
                            received_attempt_id = %answer.attempt_id,
                            "ignored stale connectivity answer"
                        );
                        return;
                    }
                    if answer.accepted {
                        if let Some(snapshot) = answer.responder_snapshot.as_ref() {
                            CandidateSnapshotPolicy::update_remote_candidate_cache(
                                &state,
                                &peer_id,
                                Some(snapshot),
                                ready_presence_ttl,
                            )
                            .await;
                            let mut candidates =
                                CandidateSnapshotPolicy::discovery_snapshot_candidates(snapshot);
                            candidates.extend(preserved_direct_candidates.iter().cloned());
                            let result = {
                                let mut attempt = attempt.lock().await;
                                let result = attempt.apply_remote_candidates(
                                    snapshot
                                        .runtime_epoch
                                        .as_ref()
                                        .map(CandidateSnapshotPolicy::nat_runtime_epoch),
                                    u64::from(snapshot.revision),
                                    candidates,
                                );
                                match result {
                                    Ok(true) => {
                                        let _ = attempt.set_state(
                                            network_nat::ConnectivityAttemptState::Connecting,
                                        );
                                        Ok(Some(attempt.remote_candidates().to_vec()))
                                    }
                                    Ok(false) => Ok(None),
                                    Err(error) => Err(error),
                                }
                            };
                            match result {
                                Ok(Some(candidates)) => {
                                    let _ = candidate_update_tx.send(Some(candidates));
                                }
                                Ok(None) => {}
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        attempt_id = %attempt_id,
                                        error = %error,
                                        "rejected responder candidate snapshot"
                                    );
                                }
                            }
                        }
                    }
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        accepted = answer.accepted,
                        "connectivity answer received"
                    );
                }
                Err(error) => {
                    tracing::debug!(
                        peer_id = %peer_id,
                        attempt_id = %attempt_id,
                        error = %error,
                        "connectivity coordination failed"
                    );
                }
            }
        });
        if task.is_none() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::RelayError,
                "connectivity coordination task could not be started",
                "connect",
                &error_peer_id,
            ));
        }
        Ok(candidate_updates)
    }
}
