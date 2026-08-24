use crate::candidate::{Candidate, CandidateKind};
use std::collections::HashMap;
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
/// never live in this long-lived state. The v1 legacy remote bridge was deleted
/// in Step 11.
pub struct PathManager {
    /// Local candidate pool with live quality samples (RTT/jitter/loss).
    candidates: Arc<RwLock<Vec<Candidate>>>,
    active_candidate: Arc<RwLock<Option<Candidate>>>,
    local_generation: Arc<RwLock<u64>>,
    /// Per-established-connection metrics (forward-facing).
    connection_path_metrics: Arc<RwLock<HashMap<SocketAddr, ConnectionPathMetrics>>>,
    /// Historical performance hints (forward-facing, never validity).
    historical_path_metrics: Arc<RwLock<HashMap<SocketAddr, HistoricalPathMetrics>>>,
}

impl Default for PathManager {
    fn default() -> Self {
        Self::new()
    }
}

impl PathManager {
    pub fn new() -> Self {
        Self {
            candidates: Arc::new(RwLock::new(Vec::new())),
            active_candidate: Arc::new(RwLock::new(None)),
            local_generation: Arc::new(RwLock::new(0)),
            connection_path_metrics: Arc::new(RwLock::new(HashMap::new())),
            historical_path_metrics: Arc::new(RwLock::new(HashMap::new())),
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
    /// check, ordered by priority and observed quality. Only the local candidate
    /// pool is consulted; remote candidates live on `ConnectivityAttempt` (§13).
    pub async fn ranked_candidates(&self) -> Vec<Candidate> {
        let mut candidates = self.candidates.read().await.clone();
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

        // Update only the local candidate pool (V2 §13: PathManager is metrics-only).
        let candidate = {
            let mut guard = self.candidates.write().await;
            let found = guard
                .iter_mut()
                .find(|candidate| candidate.endpoint == endpoint);
            match found {
                Some(candidate) => {
                    candidate.record_quality(rtt_ms, loss_rate);
                    candidate.last_success_timestamp = now;
                    candidate.clone()
                }
                None => {
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
        let pool = self.candidates.read().await.clone();
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
            .candidates
            .read()
            .await
            .iter()
            .find(|candidate| candidate.endpoint == endpoint)
            .cloned();
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
        self.candidates
            .read()
            .await
            .iter()
            .find(|candidate| candidate.endpoint == endpoint)
            .cloned()
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
#[path = "tests/path_manager.rs"]
mod tests;
