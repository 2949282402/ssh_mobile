//! `ConnectivityAttempt` — the one-shot state machine for a single connectivity
//! exchange between two peers.
//!
//! V2 design (§12): every connection attempt creates an independent
//! `ConnectivityAttempt`. All state below belongs to *this* attempt alone:
//! `remote_runtime_epoch`, `remote_discovery_revision`, and the remote candidate
//! set describe the remote discovery snapshot for THIS attempt only, and the
//! object must be dropped when the attempt ends. Nothing here persists between
//! attempts and no attempt's state can leak into the next one.

use crate::candidate::Candidate;
use crate::exchange::{CandidateSignal, MAX_CANDIDATES_PER_SIGNAL};
use std::collections::HashSet;
use std::time::{Duration, SystemTime};

/// Lifecycle of a single `ConnectivityAttempt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectivityAttemptState {
    /// The attempt has been created but the peer has not been resolved yet.
    Created,
    /// Peer resolution completed and remote discovery was attached.
    Resolved,
    /// Candidate coordination (offer/answer) is in flight.
    Coordinating,
    /// Direct connectivity checks are in flight.
    Connecting,
    /// A direct path succeeded.
    Succeeded,
    /// The attempt failed and is terminal.
    Failed,
    /// The direct deadline elapsed without success.
    Expired,
}

impl ConnectivityAttemptState {
    /// Terminal states cannot transition back to a live state.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Expired)
    }
}

/// One connectivity attempt. Fully attempt-scoped: every field belongs to this
/// attempt alone, and the object is dropped when the attempt ends.
#[derive(Debug, Clone)]
pub struct ConnectivityAttempt {
    /// Identifies this simultaneous-connectivity window; answers echo the
    /// offer's ID so a stale answer can never update a newer attempt.
    pub attempt_id: String,
    /// The remote peer this attempt is exchanging candidates with.
    pub peer_id: String,
    /// Runtime epoch of the local control plane when the attempt started.
    pub local_runtime_epoch: u64,
    /// Runtime epoch of the remote control plane observed during THIS attempt.
    pub remote_runtime_epoch: Option<u64>,
    /// Discovery revision of the remote peer observed during THIS attempt.
    pub remote_discovery_revision: Option<u64>,
    /// Local candidate set gathered for this attempt.
    pub local_candidates: Vec<Candidate>,
    /// Remote candidate set attached to this attempt via offer/answer signaling.
    pub remote_candidates: Vec<Candidate>,
    /// When the attempt started.
    pub started_at: SystemTime,
    /// Absolute time by which a direct path must be established, if bounded.
    pub direct_deadline: Option<SystemTime>,
    /// Current lifecycle state.
    pub state: ConnectivityAttemptState,
}

impl ConnectivityAttempt {
    /// Creates a fresh attempt in the [`ConnectivityAttemptState::Created`]
    /// state. `direct_deadline` is the absolute time the direct window closes.
    pub fn new(
        attempt_id: impl Into<String>,
        peer_id: impl Into<String>,
        local_runtime_epoch: u64,
        started_at: SystemTime,
        direct_deadline: Option<SystemTime>,
    ) -> Self {
        Self {
            attempt_id: attempt_id.into(),
            peer_id: peer_id.into(),
            local_runtime_epoch,
            remote_runtime_epoch: None,
            remote_discovery_revision: None,
            local_candidates: Vec::new(),
            remote_candidates: Vec::new(),
            started_at,
            direct_deadline,
            state: ConnectivityAttemptState::Created,
        }
    }

    /// Convenience constructor that derives the absolute direct deadline from a
    /// bounded `connect_window` measured from `started_at`.
    pub fn with_connect_window(
        attempt_id: impl Into<String>,
        peer_id: impl Into<String>,
        local_runtime_epoch: u64,
        started_at: SystemTime,
        connect_window: Duration,
    ) -> Self {
        Self::new(
            attempt_id,
            peer_id,
            local_runtime_epoch,
            started_at,
            started_at.checked_add(connect_window),
        )
    }

    pub fn attempt_id(&self) -> &str {
        &self.attempt_id
    }

    pub fn peer_id(&self) -> &str {
        &self.peer_id
    }

    pub fn state(&self) -> ConnectivityAttemptState {
        self.state
    }

    pub fn started_at(&self) -> SystemTime {
        self.started_at
    }

    pub fn direct_deadline(&self) -> Option<SystemTime> {
        self.direct_deadline
    }

    pub fn local_runtime_epoch(&self) -> u64 {
        self.local_runtime_epoch
    }

    pub fn remote_runtime_epoch(&self) -> Option<u64> {
        self.remote_runtime_epoch
    }

    pub fn remote_discovery_revision(&self) -> Option<u64> {
        self.remote_discovery_revision
    }

    pub fn local_candidates(&self) -> &[Candidate] {
        &self.local_candidates
    }

    pub fn remote_candidates(&self) -> &[Candidate] {
        &self.remote_candidates
    }

    /// Terminal attempts can never be moved back to a live state.
    pub fn is_terminal(&self) -> bool {
        self.state.is_terminal()
    }

    /// Attaches the local candidate set gathered for this attempt.
    pub fn with_local_candidates(mut self, candidates: Vec<Candidate>) -> Self {
        self.local_candidates = candidates;
        self
    }

    /// Advances the lifecycle state. Returns `false` if the attempt is already
    /// terminal (the transition is ignored) so callers can short-circuit.
    pub fn set_state(&mut self, state: ConnectivityAttemptState) -> bool {
        if self.state.is_terminal() {
            return false;
        }
        self.state = state;
        true
    }

    /// Whether the bounded direct window has elapsed by `now`.
    pub fn direct_deadline_elapsed(&self, now: SystemTime) -> bool {
        self.direct_deadline.is_some_and(|deadline| now >= deadline)
    }

    /// Merged candidate pool for connectivity checks: local candidates first,
    /// then remote candidates attached via signaling.
    pub fn all_candidates(&self) -> Vec<Candidate> {
        self.local_candidates
            .iter()
            .cloned()
            .chain(self.remote_candidates.iter().cloned())
            .collect()
    }

    /// Merges a discovery snapshot into this attempt's remote candidate set.
    /// Discovery snapshots carry already-decoded candidate advertisements, so
    /// their candidate generation is independent from the control signal's
    /// exchange generation. The attempt still owns epoch/revision monotonicity
    /// and replaces removed candidates atomically.
    pub fn apply_remote_candidates(
        &mut self,
        runtime_epoch: Option<u64>,
        discovery_revision: u64,
        candidates: Vec<Candidate>,
    ) -> Result<bool, String> {
        if self.state.is_terminal() {
            return Ok(false);
        }
        if candidates.len() > MAX_CANDIDATES_PER_SIGNAL {
            return Err("remote candidate set exceeds the attempt limit".into());
        }
        let mut incoming_ids = HashSet::with_capacity(candidates.len());
        if candidates
            .iter()
            .any(|candidate| !incoming_ids.insert(candidate.candidate_id.clone()))
        {
            return Err("remote candidate set contains duplicate ids".into());
        }

        if let Some(signal_epoch) = runtime_epoch {
            match self.remote_runtime_epoch {
                Some(current) if signal_epoch < current => return Ok(false),
                Some(current) if signal_epoch > current => {
                    self.remote_runtime_epoch = Some(signal_epoch);
                    self.remote_discovery_revision = Some(discovery_revision);
                    self.remote_candidates.clear();
                }
                Some(_) => {
                    if let Some(current_revision) = self.remote_discovery_revision {
                        if discovery_revision < current_revision {
                            return Ok(false);
                        }
                        if discovery_revision > current_revision {
                            self.remote_discovery_revision = Some(discovery_revision);
                        }
                    } else {
                        self.remote_discovery_revision = Some(discovery_revision);
                    }
                }
                None => {
                    self.remote_runtime_epoch = Some(signal_epoch);
                    self.remote_discovery_revision = Some(discovery_revision);
                    self.remote_candidates.clear();
                }
            }
        } else if let Some(current_revision) = self.remote_discovery_revision {
            if discovery_revision < current_revision {
                return Ok(false);
            }
            if discovery_revision > current_revision {
                self.remote_discovery_revision = Some(discovery_revision);
            }
        } else {
            self.remote_discovery_revision = Some(discovery_revision);
        }

        self.remote_candidates
            .retain(|candidate| incoming_ids.contains(&candidate.candidate_id));
        for candidate in candidates {
            if let Some(existing) = self
                .remote_candidates
                .iter_mut()
                .find(|existing| existing.candidate_id == candidate.candidate_id)
            {
                let sample_count = existing.sample_count;
                let rtt_ms = existing.rtt_ms;
                let jitter_ms = existing.jitter_ms;
                let loss_rate = existing.loss_rate;
                let last_success_timestamp = existing.last_success_timestamp;
                *existing = candidate;
                if sample_count > 0 {
                    existing.sample_count = sample_count;
                    existing.rtt_ms = rtt_ms;
                    existing.jitter_ms = jitter_ms;
                    existing.loss_rate = loss_rate;
                    existing.last_success_timestamp = last_success_timestamp;
                }
            } else {
                self.remote_candidates.push(candidate);
            }
        }
        Ok(true)
    }

    /// Attempt-scoped validity gatekeeper for an incoming offer/answer.
    ///
    /// This replaces the v1 `PathManager::apply_remote_candidates` role: the
    /// signal must belong to THIS attempt (`attempt_id` match), a stale epoch
    /// must never regress the attempt, and the remote candidate set is stored
    /// only on the attempt. Returns `Ok(false)` for a stale attempt (the caller
    /// should ignore it), `Err` for a malformed signal, and `Ok(true)` when the
    /// remote discovery snapshot was applied.
    pub fn apply_signal(&mut self, signal: &CandidateSignal) -> Result<bool, String> {
        signal.validate()?;
        if signal.attempt_id != self.attempt_id {
            // A signal for a different attempt is stale — never cross-attempt.
            return Ok(false);
        }
        let signal_epoch = signal.runtime_epoch.unwrap_or(signal.generation);
        let signal_revision = signal.discovery_revision.unwrap_or(signal.generation);

        let candidates = signal
            .candidates
            .iter()
            .map(|candidate| Candidate::from_advertisement(candidate.clone()))
            .collect::<Result<Vec<_>, _>>()?;
        self.apply_remote_candidates(Some(signal_epoch), signal_revision, candidates)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate::CandidateKind;
    use crate::exchange::{CandidateSignal, CandidateSignalKind, DEFAULT_CONNECT_WINDOW_MS};
    use std::net::SocketAddr;

    fn signal(
        kind: CandidateSignalKind,
        attempt_id: &str,
        generation: u64,
        port: u16,
    ) -> CandidateSignal {
        let candidate = Candidate::new(
            SocketAddr::from(([192, 168, 1, 10], port)),
            CandidateKind::Lan,
            "wifi".into(),
        )
        .with_generation(generation);
        match kind {
            CandidateSignalKind::Offer => CandidateSignal::offer(
                generation,
                attempt_id.into(),
                DEFAULT_CONNECT_WINDOW_MS,
                vec![candidate.advertisement()],
            ),
            CandidateSignalKind::Answer => CandidateSignal::answer(
                generation,
                attempt_id.into(),
                DEFAULT_CONNECT_WINDOW_MS,
                vec![candidate.advertisement()],
            ),
        }
    }

    fn attempt(attempt_id: &str) -> ConnectivityAttempt {
        ConnectivityAttempt::with_connect_window(
            attempt_id,
            "peer-a",
            7,
            SystemTime::now(),
            Duration::from_secs(5),
        )
    }

    #[test]
    fn fresh_attempt_is_created_and_tracks_deadline() {
        let started_at = SystemTime::now();
        let mut attempt = ConnectivityAttempt::new("attempt-1", "peer-a", 7, started_at, None);
        assert_eq!(attempt.state(), ConnectivityAttemptState::Created);
        assert!(!attempt.is_terminal());
        assert_eq!(attempt.remote_runtime_epoch(), None);
        assert!(attempt.set_state(ConnectivityAttemptState::Connecting));
        assert_eq!(attempt.state(), ConnectivityAttemptState::Connecting);
        assert!(attempt.direct_deadline().is_none());
        assert!(!attempt.direct_deadline_elapsed(SystemTime::now()));

        attempt.state = ConnectivityAttemptState::Succeeded;
        assert!(attempt.is_terminal());
        assert!(!attempt.set_state(ConnectivityAttemptState::Connecting));
    }

    #[test]
    fn with_connect_window_derives_absolute_deadline() {
        let started_at = SystemTime::now();
        let attempt = ConnectivityAttempt::with_connect_window(
            "attempt-1",
            "peer-a",
            7,
            started_at,
            Duration::from_secs(5),
        );
        let deadline = attempt.direct_deadline().unwrap();
        assert!(deadline > started_at);
        let window = deadline.duration_since(started_at).unwrap();
        assert_eq!(window.as_secs(), 5);
    }

    #[test]
    fn apply_signal_sets_remote_discovery_within_the_attempt() {
        let mut attempt = attempt("attempt-a");
        assert!(attempt
            .apply_signal(&signal(CandidateSignalKind::Offer, "attempt-a", 2, 40002))
            .unwrap());
        assert_eq!(attempt.remote_runtime_epoch(), Some(2));
        assert_eq!(attempt.remote_discovery_revision(), Some(2));
        assert_eq!(attempt.remote_candidates().len(), 1);
        assert_eq!(attempt.remote_candidates()[0].endpoint.port(), 40002);
        assert_eq!(attempt.all_candidates().len(), 1);
    }

    #[test]
    fn stale_attempt_signal_is_rejected_without_mutating_state() {
        let mut attempt = attempt("attempt-a");
        assert!(attempt
            .apply_signal(&signal(CandidateSignalKind::Offer, "attempt-a", 2, 40002))
            .unwrap());
        assert!(!attempt
            .apply_signal(&signal(
                CandidateSignalKind::Answer,
                "attempt-other",
                2,
                40003
            ))
            .unwrap());
        assert_eq!(attempt.remote_runtime_epoch(), Some(2));
        assert_eq!(attempt.remote_candidates().len(), 1);
        assert_eq!(attempt.remote_candidates()[0].endpoint.port(), 40002);
    }

    #[test]
    fn stale_epoch_cannot_regress_a_live_attempt() {
        let mut attempt = attempt("attempt-a");
        assert!(attempt
            .apply_signal(&signal(CandidateSignalKind::Offer, "attempt-a", 4, 40004))
            .unwrap());
        assert!(!attempt
            .apply_signal(&signal(CandidateSignalKind::Answer, "attempt-a", 1, 40001))
            .unwrap());
        assert_eq!(attempt.remote_runtime_epoch(), Some(4));
        assert_eq!(attempt.remote_candidates()[0].endpoint.port(), 40004);
    }

    #[test]
    fn v2_epoch_and_revision_are_carried_into_the_attempt() {
        let mut attempt = attempt("attempt-v2");
        let mut offer = signal(CandidateSignalKind::Offer, "attempt-v2", 3, 40009);
        offer = offer.with_epoch_revision(11, 22);
        assert!(attempt.apply_signal(&offer).unwrap());
        assert_eq!(attempt.remote_runtime_epoch(), Some(11));
        assert_eq!(attempt.remote_discovery_revision(), Some(22));
    }

    #[test]
    fn candidate_pool_merges_local_and_remote() {
        let local = Candidate::new(
            "192.168.1.20:41020".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        );
        let mut attempt = attempt("attempt-a").with_local_candidates(vec![local]);
        assert!(attempt
            .apply_signal(&signal(CandidateSignalKind::Offer, "attempt-a", 2, 40002))
            .unwrap());
        let pool = attempt.all_candidates();
        assert_eq!(pool.len(), 2);
        assert_eq!(pool[0].endpoint.port(), 41020);
        assert_eq!(pool[1].endpoint.port(), 40002);
    }

    #[test]
    fn discovery_snapshot_merge_replaces_removed_candidates_and_keeps_epoch_monotonic() {
        let first = Candidate::new(
            "192.168.1.20:41020".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        );
        let second = Candidate::new(
            "198.51.100.20:42020".parse().unwrap(),
            CandidateKind::PublicIpv6,
            "public".into(),
        );
        let mut attempt = attempt("attempt-a");
        assert!(attempt
            .apply_remote_candidates(Some(7), 1, vec![first.clone(), second.clone()])
            .unwrap());
        assert_eq!(attempt.remote_candidates().len(), 2);

        assert!(attempt
            .apply_remote_candidates(Some(7), 2, vec![second.clone()])
            .unwrap());
        assert_eq!(attempt.remote_candidates().len(), 1);
        assert_eq!(
            attempt.remote_candidates()[0].candidate_id,
            second.candidate_id
        );

        assert!(!attempt
            .apply_remote_candidates(Some(6), 3, vec![first])
            .unwrap());
        assert_eq!(attempt.remote_candidates().len(), 1);
        assert_eq!(attempt.remote_discovery_revision(), Some(2));
    }

    #[test]
    fn older_revision_and_terminal_attempt_cannot_update_candidates() {
        let first = Candidate::new(
            "192.168.1.20:41020".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        );
        let replacement = Candidate::new(
            "198.51.100.20:42020".parse().unwrap(),
            CandidateKind::PublicIpv6,
            "public".into(),
        );
        let mut attempt = attempt("attempt-a");
        assert!(attempt
            .apply_remote_candidates(Some(7), 2, vec![first.clone()])
            .unwrap());
        assert!(!attempt
            .apply_remote_candidates(Some(7), 1, vec![replacement.clone()])
            .unwrap());
        assert_eq!(
            attempt.remote_candidates()[0].candidate_id,
            first.candidate_id
        );

        assert!(attempt.set_state(ConnectivityAttemptState::Succeeded));
        assert!(!attempt
            .apply_remote_candidates(Some(8), 3, vec![replacement])
            .unwrap());
        assert_eq!(
            attempt.remote_candidates()[0].candidate_id,
            first.candidate_id
        );
    }
}
