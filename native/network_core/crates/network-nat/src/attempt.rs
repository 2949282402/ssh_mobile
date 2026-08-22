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
use crate::exchange::{CandidateSignal, RuntimeEpoch, MAX_CANDIDATES_PER_SIGNAL};
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

/// Boundary result for a candidate Answer arriving at an attempt.
///
/// `CacheOnly` is intentionally distinct from `Applied`: the caller may feed
/// the fresh snapshot into the remote cache, but must not resurrect a direct
/// probe after the one-shot window has closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateUpdateDisposition {
    Applied,
    CacheOnly,
    IgnoredStale,
    Terminal,
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
    pub local_runtime_epoch: RuntimeEpoch,
    /// Runtime epoch of the remote control plane observed during THIS attempt.
    pub remote_runtime_epoch: Option<RuntimeEpoch>,
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
        local_runtime_epoch: RuntimeEpoch,
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
        local_runtime_epoch: RuntimeEpoch,
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

    pub fn local_runtime_epoch(&self) -> RuntimeEpoch {
        self.local_runtime_epoch
    }

    pub fn remote_runtime_epoch(&self) -> Option<RuntimeEpoch> {
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
        runtime_epoch: Option<RuntimeEpoch>,
        discovery_revision: u64,
        candidates: Vec<Candidate>,
    ) -> Result<bool, String> {
        if self.state.is_terminal() {
            return Ok(false);
        }
        // A late Answer may still be useful to a remote cache, but it must not
        // mutate this completed Direct attempt or resurrect its probe queue.
        if self.direct_deadline_elapsed(SystemTime::now()) {
            return Ok(false);
        }
        self.apply_remote_candidates_unchecked(runtime_epoch, discovery_revision, candidates)
    }

    fn apply_remote_candidates_unchecked(
        &mut self,
        runtime_epoch: Option<RuntimeEpoch>,
        discovery_revision: u64,
        candidates: Vec<Candidate>,
    ) -> Result<bool, String> {
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
                Some(current) if signal_epoch != current => {
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
        if self.direct_deadline_elapsed(SystemTime::now()) {
            return Ok(false);
        }
        self.apply_signal_unchecked(signal)
    }

    fn apply_signal_unchecked(&mut self, signal: &CandidateSignal) -> Result<bool, String> {
        signal.validate()?;
        if signal.attempt_id != self.attempt_id {
            // A signal for a different attempt is stale — never cross-attempt.
            return Ok(false);
        }
        let signal_epoch = signal.runtime_epoch;
        let signal_revision = signal.discovery_revision.unwrap_or(signal.generation);

        let candidates = signal
            .candidates
            .iter()
            .map(|candidate| Candidate::from_advertisement(candidate.clone()))
            .collect::<Result<Vec<_>, _>>()?;
        self.apply_remote_candidates_unchecked(signal_epoch, signal_revision, candidates)
    }

    /// Applies a matching Answer while preserving the active-window versus
    /// expired-cache-only boundary. This is the narrow integration seam for a
    /// Coordinator that owns the remote cache and DirectProbe lifecycle.
    pub fn apply_signal_with_deadline(
        &mut self,
        signal: &CandidateSignal,
        now: SystemTime,
    ) -> Result<CandidateUpdateDisposition, String> {
        if self.state.is_terminal() {
            return Ok(CandidateUpdateDisposition::Terminal);
        }
        if signal.attempt_id != self.attempt_id {
            return Ok(CandidateUpdateDisposition::IgnoredStale);
        }
        if self.direct_deadline_elapsed(now) {
            return Ok(CandidateUpdateDisposition::CacheOnly);
        }
        if self.apply_signal_unchecked(signal)? {
            Ok(CandidateUpdateDisposition::Applied)
        } else {
            Ok(CandidateUpdateDisposition::IgnoredStale)
        }
    }
}

#[cfg(test)]
#[path = "tests/attempt.rs"]
mod tests;
