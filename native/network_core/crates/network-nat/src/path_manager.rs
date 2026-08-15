use crate::candidate::{Candidate, CandidateKind};
use crate::exchange::CandidateSignalKind;
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;
use tracing::info;

const MIGRATION_SCORE_HYSTERESIS: f32 = 15.0;

/// Per-established-connection path metrics (V2 §13). Unlike [`Candidate`],
/// which carries identity plus live quality samples for scoring, this record is
/// keyed by a live connection endpoint and holds only observed quality for an
/// already-established path. It is never a validity gatekeeper.
#[derive(Debug, Clone, PartialEq)]
pub struct ConnectionPathMetrics {
    pub endpoint: SocketAddr,
    pub rtt_ms: u32,
    pub jitter_ms: u32,
    pub loss_rate: f32,
    pub sample_count: u32,
    pub last_sample_at: SystemTime,
}

impl ConnectionPathMetrics {
    pub fn new(endpoint: SocketAddr) -> Self {
        Self {
            endpoint,
            rtt_ms: 0,
            jitter_ms: 0,
            loss_rate: 0.0,
            sample_count: 0,
            last_sample_at: UNIX_EPOCH,
        }
    }

    /// Merges a fresh sample into the connection's EWMA, mirroring the
    /// candidate-side `record_quality` so the two metrics stay consistent.
    pub fn update(&mut self, rtt_ms: u32, jitter_ms: u32, loss_rate: f32) {
        if self.sample_count == 0 {
            self.rtt_ms = rtt_ms;
            self.jitter_ms = jitter_ms;
            self.loss_rate = loss_rate;
        } else {
            self.jitter_ms =
                ((self.jitter_ms as u64 * 3 + jitter_ms as u64) / 4).min(u32::MAX as u64) as u32;
            self.rtt_ms =
                ((self.rtt_ms as u64 * 3 + rtt_ms as u64) / 4).min(u32::MAX as u64) as u32;
            self.loss_rate = self.loss_rate * 0.75 + loss_rate * 0.25;
        }
        self.sample_count = self.sample_count.saturating_add(1);
        self.last_sample_at = SystemTime::now();
    }
}

/// Historical path metrics (V2 §13): pure performance hints for ranking local
/// candidates. They must never decide whether a candidate is still valid —
/// only a `ConnectivityAttempt` owns candidate validity.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoricalPathMetrics {
    pub endpoint: SocketAddr,
    pub avg_rtt_ms: u32,
    pub avg_jitter_ms: u32,
    pub avg_loss_rate: f32,
    pub sample_count: u32,
    pub last_seen_at: SystemTime,
}

/// Manages LOCAL candidate scoring, live path-metrics sampling, and path
/// migration for the current transport endpoint.
///
/// V2 (§13): `PathManager` is metrics-only. Remote discovery truth (remote
/// epoch, remote attempt id, remote connect window, and the remote candidate
/// set) is owned by a one-shot [`crate::attempt::ConnectivityAttempt`] and must
/// never live in this long-lived state. The only remote state that remains is
/// a `#[deprecated]` bridge (`legacy_remote`) kept so v1 callers (network-core
/// Step 5/6) still compile against the old API; Step 11 deletes it.
pub struct PathManager {
    /// Local candidate pool with live quality samples (RTT/jitter/loss).
    candidates: Arc<RwLock<Vec<Candidate>>>,
    active_candidate: Arc<RwLock<Option<Candidate>>>,
    local_generation: Arc<RwLock<u64>>,
    /// Per-established-connection metrics (forward-facing).
    connection_path_metrics: Arc<RwLock<HashMap<SocketAddr, ConnectionPathMetrics>>>,
    /// Historical performance hints (forward-facing, never validity).
    historical_path_metrics: Arc<RwLock<HashMap<SocketAddr, HistoricalPathMetrics>>>,
    /// DEPRECATED v1 remote discovery truth, kept only for additive-first
    /// compatibility. Deleted in Step 11. Use `ConnectivityAttempt` instead.
    #[deprecated(note = "v1 remote discovery truth on PathManager; use ConnectivityAttempt")]
    legacy_remote: Arc<RwLock<LegacyRemoteState>>,
}

/// v1 remote discovery truth that used to live directly on `PathManager`.
/// Kept behind a deprecated shim so Step 5 stays additive-first; Step 11
/// deletes it in favor of `ConnectivityAttempt`. Do not add new code here.
#[derive(Debug)]
struct LegacyRemoteState {
    remote_generation: u64,
    remote_attempt_id: Option<String>,
    remote_connect_window_ms: u32,
    remote_candidates: Vec<Candidate>,
}

impl Default for LegacyRemoteState {
    fn default() -> Self {
        Self {
            remote_generation: 0,
            remote_attempt_id: None,
            // Preserves the v1 default so legacy callers that read
            // `remote_connect_window()` before any offer/answer still get the
            // bounded direct window instead of a zero-length deadline.
            remote_connect_window_ms: crate::exchange::DEFAULT_CONNECT_WINDOW_MS,
            remote_candidates: Vec::new(),
        }
    }
}

impl Default for PathManager {
    fn default() -> Self {
        Self::new()
    }
}

impl PathManager {
    #[allow(deprecated)]
    pub fn new() -> Self {
        Self {
            candidates: Arc::new(RwLock::new(Vec::new())),
            active_candidate: Arc::new(RwLock::new(None)),
            local_generation: Arc::new(RwLock::new(0)),
            connection_path_metrics: Arc::new(RwLock::new(HashMap::new())),
            historical_path_metrics: Arc::new(RwLock::new(HashMap::new())),
            legacy_remote: Arc::new(RwLock::new(LegacyRemoteState::default())),
        }
    }

    /// Adds or updates discovered local candidates.
    pub async fn add_candidates(&self, list: Vec<Candidate>) {
        let mut guard = self.candidates.write().await;
        for item in list {
            if let Some(existing) = guard.iter_mut().find(|c| c.endpoint == item.endpoint) {
                let previous_quality = existing.sample_count > 0;
                existing.candidate_id = item.candidate_id;
                existing.interface_name = item.interface_name;
                existing.kind = item.kind;
                existing.priority = item.priority;
                existing.generation = item.generation;
                if !previous_quality {
                    existing.rtt_ms = item.rtt_ms;
                    existing.jitter_ms = item.jitter_ms;
                    existing.loss_rate = item.loss_rate;
                    existing.last_success_timestamp = item.last_success_timestamp;
                    existing.sample_count = item.sample_count;
                }
            } else {
                guard.push(item);
            }
        }
    }

    /// Sets the local candidate generation before it is advertised.
    pub async fn set_generation(&self, generation: u64) {
        *self.local_generation.write().await = generation;
        let mut guard = self.candidates.write().await;
        for candidate in guard.iter_mut() {
            candidate.generation = generation;
        }
    }

    pub async fn generation(&self) -> u64 {
        *self.local_generation.read().await
    }

    /// Returns all candidates for signaling or a multi-candidate connectivity
    /// check, ordered by priority and observed quality. Local candidates come
    /// from the forward-facing pool; v1 remote candidates are still merged in
    /// from the deprecated bridge until Step 11.
    pub async fn ranked_candidates(&self) -> Vec<Candidate> {
        let mut candidates = self.candidate_pool().await;
        candidates.sort_by(|left, right| {
            candidate_score(right)
                .partial_cmp(&candidate_score(left))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        candidates
    }

    /// Records a QUIC path sample for a candidate.
    pub async fn record_quic_sample(
        &self,
        endpoint: SocketAddr,
        rtt: Duration,
        sent_packets: u64,
        lost_packets: u64,
    ) {
        let rtt_ms = rtt.as_millis().min(u32::MAX as u128) as u32;
        let loss_rate = if sent_packets == 0 {
            0.0
        } else {
            (lost_packets as f32 / sent_packets as f32).clamp(0.0, 1.0)
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // Update whichever pool owns the endpoint: the local candidate pool or
        // the deprecated v1 remote pool (bridged until Step 11).
        let updated = self
            .update_candidate_quality(endpoint, rtt_ms, loss_rate, now)
            .await;

        let candidate = match updated {
            Some(candidate) => candidate,
            None => {
                let mut guard = self.candidates.write().await;
                guard.push(Candidate::new(
                    endpoint,
                    CandidateKind::ServerReflexive,
                    "quic-observed".to_string(),
                ));
                let candidate = guard.last_mut().expect("candidate was just inserted");
                candidate.record_quality(rtt_ms, loss_rate);
                candidate.last_success_timestamp = now;
                candidate.clone()
            }
        };

        let mut active = self.active_candidate.write().await;
        if active
            .as_ref()
            .is_some_and(|active| active.endpoint == endpoint)
        {
            *active = Some(candidate);
        }
    }

    /// Selects the best candidate based on priority, RTT, jitter, and loss.
    pub async fn select_best_path(&self) -> Option<Candidate> {
        let best = self.ranked_candidates().await.into_iter().next();

        if let Some(ref selected) = best {
            let mut active = self.active_candidate.write().await;
            *active = Some(selected.clone());
            info!("PathManager selected active path: {:?}", selected.endpoint);
        }

        best
    }

    /// Returns a materially better path without changing the active path yet.
    /// The caller must establish and authenticate the replacement first.
    pub async fn better_path_than_active(&self) -> Option<Candidate> {
        let pool = self.candidate_pool().await;
        let active = self.active_candidate.read().await.clone()?;
        let active_score = candidate_score(&active);
        pool.iter()
            .filter(|candidate| candidate.endpoint != active.endpoint)
            .max_by(|left, right| {
                candidate_score(left)
                    .partial_cmp(&candidate_score(right))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .filter(|candidate| {
                candidate_score(candidate) > active_score + MIGRATION_SCORE_HYSTERESIS
            })
            .cloned()
    }

    /// Commits a path after its replacement Connection is ready.
    pub async fn activate_path(&self, endpoint: SocketAddr) -> bool {
        let candidate = self
            .candidate_pool()
            .await
            .into_iter()
            .find(|candidate| candidate.endpoint == endpoint);
        let Some(candidate) = candidate else {
            return false;
        };
        *self.active_candidate.write().await = Some(candidate);
        info!(%endpoint, "PathManager activated migrated path");
        true
    }

    /// Returns the currently active path.
    pub async fn get_active_path(&self) -> Option<Candidate> {
        self.active_candidate.read().await.clone()
    }

    /// Returns the latest metrics snapshot for one endpoint.
    pub async fn get_candidate(&self, endpoint: SocketAddr) -> Option<Candidate> {
        self.candidate_pool()
            .await
            .into_iter()
            .find(|candidate| candidate.endpoint == endpoint)
    }

    /// Records an established-connection sample for the forward-facing
    /// [`ConnectionPathMetrics`] map.
    pub async fn record_connection_path_metrics(
        &self,
        endpoint: SocketAddr,
        rtt_ms: u32,
        jitter_ms: u32,
        loss_rate: f32,
    ) {
        let mut metrics = self.connection_path_metrics.write().await;
        let entry = metrics
            .entry(endpoint)
            .or_insert_with(|| ConnectionPathMetrics::new(endpoint));
        entry.update(rtt_ms, jitter_ms, loss_rate.clamp(0.0, 1.0));
    }

    /// Returns the forward-facing per-established-connection metrics.
    pub async fn connection_path_metrics(&self) -> Vec<ConnectionPathMetrics> {
        self.connection_path_metrics
            .read()
            .await
            .values()
            .cloned()
            .collect()
    }

    /// Records a historical performance hint for an endpoint. Purely advisory:
    /// never used to decide candidate validity.
    pub async fn record_historical_path_metrics(
        &self,
        endpoint: SocketAddr,
        avg_rtt_ms: u32,
        avg_jitter_ms: u32,
        avg_loss_rate: f32,
        sample_count: u32,
    ) {
        let mut metrics = self.historical_path_metrics.write().await;
        metrics.insert(
            endpoint,
            HistoricalPathMetrics {
                endpoint,
                avg_rtt_ms,
                avg_jitter_ms,
                avg_loss_rate: avg_loss_rate.clamp(0.0, 1.0),
                sample_count,
                last_seen_at: SystemTime::now(),
            },
        );
    }

    /// Returns all historical performance hints.
    pub async fn historical_path_metrics(&self) -> Vec<HistoricalPathMetrics> {
        self.historical_path_metrics
            .read()
            .await
            .values()
            .cloned()
            .collect()
    }

    /// Merged candidate pool: local candidates plus any v1 remote candidates
    /// still bridged through the deprecated legacy state.
    #[allow(deprecated)]
    async fn candidate_pool(&self) -> Vec<Candidate> {
        let mut pool = self.candidates.read().await.clone();
        pool.extend(
            self.legacy_remote
                .read()
                .await
                .remote_candidates
                .iter()
                .cloned(),
        );
        pool
    }

    #[allow(deprecated)]
    async fn update_candidate_quality(
        &self,
        endpoint: SocketAddr,
        rtt_ms: u32,
        loss_rate: f32,
        now: u64,
    ) -> Option<Candidate> {
        {
            let mut guard = self.candidates.write().await;
            if let Some(candidate) = guard.iter_mut().find(|c| c.endpoint == endpoint) {
                candidate.record_quality(rtt_ms, loss_rate);
                candidate.last_success_timestamp = now;
                return Some(candidate.clone());
            }
        }
        let mut legacy = self.legacy_remote.write().await;
        if let Some(candidate) = legacy
            .remote_candidates
            .iter_mut()
            .find(|c| c.endpoint == endpoint)
        {
            candidate.record_quality(rtt_ms, loss_rate);
            candidate.last_success_timestamp = now;
            return Some(candidate.clone());
        }
        None
    }

    /// DEPRECATED (Step 11): applies a complete remote Candidate Offer/Answer
    /// into PathManager's legacy remote state. New code must use
    /// [`crate::attempt::ConnectivityAttempt`].
    #[deprecated(note = "v1 remote discovery truth on PathManager; use ConnectivityAttempt")]
    #[allow(deprecated)]
    pub async fn apply_remote_candidates(
        &self,
        signal_kind: CandidateSignalKind,
        attempt_id: &str,
        connect_window_ms: u32,
        generation: u64,
        list: Vec<Candidate>,
    ) -> bool {
        let incoming_ids = list
            .iter()
            .map(|candidate| candidate.candidate_id.clone())
            .collect::<HashSet<_>>();
        if generation == 0
            || attempt_id.is_empty()
            || attempt_id.len() > crate::exchange::MAX_ATTEMPT_ID_BYTES
            || !attempt_id.bytes().all(|byte| byte.is_ascii_graphic())
            || !(crate::exchange::MIN_CONNECT_WINDOW_MS..=crate::exchange::MAX_CONNECT_WINDOW_MS)
                .contains(&connect_window_ms)
            || list.len() > crate::exchange::MAX_CANDIDATES_PER_SIGNAL
            || incoming_ids.len() != list.len()
            || list
                .iter()
                .any(|candidate| candidate.generation != generation)
        {
            return false;
        }
        let mut legacy = self.legacy_remote.write().await;
        if generation < legacy.remote_generation {
            return false;
        }
        let is_new_attempt = legacy
            .remote_attempt_id
            .as_deref()
            .is_some_and(|current| current != attempt_id);
        if is_new_attempt && signal_kind == CandidateSignalKind::Answer {
            return false;
        }
        if generation > legacy.remote_generation || is_new_attempt {
            legacy.remote_candidates.clear();
            legacy.remote_generation = generation;
            legacy.remote_attempt_id = Some(attempt_id.to_string());
            legacy.remote_connect_window_ms = connect_window_ms;
        } else {
            legacy
                .remote_candidates
                .retain(|candidate| incoming_ids.contains(&candidate.candidate_id));
        }
        if legacy.remote_attempt_id.is_none() {
            legacy.remote_attempt_id = Some(attempt_id.to_string());
        }
        for candidate in list {
            if let Some(existing) = legacy
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
                legacy.remote_candidates.push(candidate);
            }
        }
        true
    }

    /// DEPRECATED (Step 11): returns the v1 remote attempt id. New code must
    /// read it from the owning `ConnectivityAttempt`.
    #[deprecated(note = "v1 remote attempt id on PathManager; use ConnectivityAttempt")]
    #[allow(deprecated)]
    pub async fn remote_attempt_id(&self) -> Option<String> {
        self.legacy_remote.read().await.remote_attempt_id.clone()
    }

    /// DEPRECATED (Step 11): returns the v1 remote connect window. New code
    /// must read it from the owning `ConnectivityAttempt`.
    #[deprecated(note = "v1 remote connect window on PathManager; use ConnectivityAttempt")]
    #[allow(deprecated)]
    pub async fn remote_connect_window(&self) -> Duration {
        Duration::from_millis(u64::from(
            self.legacy_remote.read().await.remote_connect_window_ms,
        ))
    }
}

fn candidate_score(candidate: &Candidate) -> f32 {
    // Unmeasured candidates retain their configured priority instead of
    // receiving an artificial zero-RTT advantage.
    let quality_penalty = if candidate.sample_count == 0 {
        0.0
    } else {
        (candidate.rtt_ms as f32) * 0.1
            + (candidate.jitter_ms as f32) * 0.05
            + candidate.loss_rate * 500.0
    };
    candidate.priority as f32 - quality_penalty
}

impl Candidate {
    fn record_quality(&mut self, rtt_ms: u32, loss_rate: f32) {
        if self.sample_count == 0 {
            self.rtt_ms = rtt_ms;
            self.jitter_ms = 0;
            self.loss_rate = loss_rate;
        } else {
            let delta = self.rtt_ms.abs_diff(rtt_ms);
            self.jitter_ms =
                ((self.jitter_ms as u64 * 3 + delta as u64) / 4).min(u32::MAX as u64) as u32;
            self.rtt_ms =
                ((self.rtt_ms as u64 * 3 + rtt_ms as u64) / 4).min(u32::MAX as u64) as u32;
            self.loss_rate = self.loss_rate * 0.75 + loss_rate * 0.25;
        }
        self.sample_count = self.sample_count.saturating_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    fn candidate(address: &str, kind: CandidateKind) -> Candidate {
        Candidate::new(address.parse::<SocketAddr>().unwrap(), kind, "test".into())
    }

    #[tokio::test]
    async fn quality_samples_update_rtt_jitter_and_loss() {
        let manager = PathManager::new();
        let endpoint = "127.0.0.1:41001".parse().unwrap();
        manager
            .add_candidates(vec![candidate("127.0.0.1:41001", CandidateKind::Lan)])
            .await;
        manager
            .record_quic_sample(endpoint, Duration::from_millis(40), 100, 5)
            .await;
        manager
            .record_quic_sample(endpoint, Duration::from_millis(80), 200, 20)
            .await;

        let selected = manager.select_best_path().await.unwrap();
        assert_eq!(selected.rtt_ms, 50);
        assert_eq!(selected.jitter_ms, 10);
        assert!(selected.loss_rate > 0.05 && selected.loss_rate < 0.1);
        assert_eq!(selected.sample_count, 2);
    }

    #[tokio::test]
    async fn materially_better_candidate_is_selected_for_migration() {
        let manager = PathManager::new();
        let active = candidate("127.0.0.1:41002", CandidateKind::Lan);
        let alternative = candidate("127.0.0.1:41003", CandidateKind::ServerReflexive);
        manager
            .add_candidates(vec![active.clone(), alternative])
            .await;
        manager.select_best_path().await;
        manager
            .record_quic_sample(active.endpoint, Duration::from_millis(350), 100, 15)
            .await;
        manager
            .record_quic_sample(
                "127.0.0.1:41003".parse().unwrap(),
                Duration::from_millis(30),
                100,
                0,
            )
            .await;

        let better = manager.better_path_than_active().await.unwrap();
        assert_eq!(better.endpoint, "127.0.0.1:41003".parse().unwrap());
        assert!(manager.activate_path(better.endpoint).await);
        assert_eq!(
            manager.get_active_path().await.unwrap().endpoint,
            better.endpoint
        );
    }

    #[tokio::test]
    async fn nat_fixture_candidate_priority_prefers_direct_paths_and_keeps_relay_fallback() {
        let manager = PathManager::new();
        let candidates = vec![
            candidate("192.168.1.10:41010", CandidateKind::Lan),
            candidate("[2001:db8::10]:41011", CandidateKind::PublicIpv6),
            candidate("198.51.100.10:41012", CandidateKind::PortMapped),
            candidate("203.0.113.10:41013", CandidateKind::ServerReflexive),
            candidate("203.0.113.20:41014", CandidateKind::Relay),
        ];
        manager.add_candidates(candidates).await;

        let ranked = manager.ranked_candidates().await;
        assert_eq!(ranked[0].kind, CandidateKind::Lan);
        assert_eq!(ranked[1].kind, CandidateKind::PublicIpv6);
        assert_eq!(ranked[2].kind, CandidateKind::PortMapped);
        assert_eq!(ranked[3].kind, CandidateKind::ServerReflexive);
        assert_eq!(ranked[4].kind, CandidateKind::Relay);
    }

    #[tokio::test]
    async fn connection_path_metrics_track_established_connection() {
        let manager = PathManager::new();
        let endpoint = "127.0.0.1:41020".parse().unwrap();
        manager
            .record_connection_path_metrics(endpoint, 40, 5, 0.05)
            .await;
        manager
            .record_connection_path_metrics(endpoint, 80, 15, 0.15)
            .await;
        let metrics = manager.connection_path_metrics().await;
        assert_eq!(metrics.len(), 1);
        let entry = &metrics[0];
        assert_eq!(entry.endpoint, endpoint);
        assert_eq!(entry.rtt_ms, 50); // (40*3 + 80)/4
        assert_eq!(entry.jitter_ms, 7); // (5*3 + 15)/4
        assert!(entry.loss_rate > 0.05 && entry.loss_rate < 0.1);
        assert_eq!(entry.sample_count, 2);
    }

    #[tokio::test]
    async fn historical_path_metrics_are_advisory_hints() {
        let manager = PathManager::new();
        let endpoint = "127.0.0.1:41021".parse().unwrap();
        manager
            .record_historical_path_metrics(endpoint, 30, 4, 0.02, 100)
            .await;
        let hints = manager.historical_path_metrics().await;
        assert_eq!(hints.len(), 1);
        assert_eq!(hints[0].endpoint, endpoint);
        assert_eq!(hints[0].avg_rtt_ms, 30);
        assert_eq!(hints[0].sample_count, 100);
        // Historical hints must never affect the live candidate pool.
        assert!(manager.ranked_candidates().await.is_empty());
    }

    #[allow(deprecated)]
    #[tokio::test]
    async fn multiple_candidates_rank_and_replace_by_generation() {
        let manager = PathManager::new();
        let lan = candidate("192.168.1.10:41004", CandidateKind::Lan).with_generation(2);
        let srflx =
            candidate("203.0.113.10:41005", CandidateKind::ServerReflexive).with_generation(2);
        assert!(
            manager
                .apply_remote_candidates(
                    CandidateSignalKind::Answer,
                    "attempt-a",
                    crate::exchange::DEFAULT_CONNECT_WINDOW_MS,
                    2,
                    vec![srflx.clone(), lan.clone()],
                )
                .await
        );

        let ranked = manager.ranked_candidates().await;
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0].candidate_id, lan.candidate_id);

        let stale = candidate("192.168.1.10:41006", CandidateKind::Lan).with_generation(1);
        assert!(
            !manager
                .apply_remote_candidates(
                    CandidateSignalKind::Answer,
                    "attempt-a",
                    crate::exchange::DEFAULT_CONNECT_WINDOW_MS,
                    1,
                    vec![stale]
                )
                .await
        );
        assert_eq!(manager.ranked_candidates().await.len(), 2);

        let ipv6 = candidate("[2001:db8::10]:41007", CandidateKind::PublicIpv6).with_generation(3);
        assert!(
            manager
                .apply_remote_candidates(
                    CandidateSignalKind::Offer,
                    "attempt-b",
                    crate::exchange::DEFAULT_CONNECT_WINDOW_MS,
                    3,
                    vec![ipv6.clone()]
                )
                .await
        );
        let ranked = manager.ranked_candidates().await;
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].candidate_id, ipv6.candidate_id);
        assert_eq!(
            manager.remote_attempt_id().await.as_deref(),
            Some("attempt-b")
        );
    }
}
