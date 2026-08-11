use crate::candidate::{Candidate, CandidateKind};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;
use tracing::info;

const MIGRATION_SCORE_HYSTERESIS: f32 = 15.0;

/// Manages candidate selection, path scoring, keepalives, and reprobing.
pub struct PathManager {
    candidates: Arc<RwLock<Vec<Candidate>>>,
    active_candidate: Arc<RwLock<Option<Candidate>>>,
    local_generation: Arc<RwLock<u64>>,
    remote_generation: Arc<RwLock<u64>>,
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
            remote_generation: Arc::new(RwLock::new(0)),
        }
    }

    /// Adds or updates discovered candidates.
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

    /// Applies a complete remote Candidate Offer/Answer. Older generations are
    /// ignored; a newer generation replaces the previous remote candidate set.
    pub async fn apply_remote_candidates(&self, generation: u64, list: Vec<Candidate>) -> bool {
        let incoming_ids = list
            .iter()
            .map(|candidate| candidate.candidate_id.clone())
            .collect::<HashSet<_>>();
        if generation == 0
            || list.len() > crate::exchange::MAX_CANDIDATES_PER_SIGNAL
            || incoming_ids.len() != list.len()
            || list
                .iter()
                .any(|candidate| candidate.generation != generation)
        {
            return false;
        }
        let mut current_generation = self.remote_generation.write().await;
        if generation < *current_generation {
            return false;
        }
        let mut guard = self.candidates.write().await;
        if generation > *current_generation {
            guard.clear();
            *current_generation = generation;
        } else {
            guard.retain(|candidate| incoming_ids.contains(&candidate.candidate_id));
        }
        for candidate in list {
            if let Some(existing) = guard
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
                guard.push(candidate);
            }
        }
        true
    }

    /// Returns all candidates for signaling or a multi-candidate connectivity
    /// check, ordered by priority and observed quality.
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
        endpoint: std::net::SocketAddr,
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
        let mut guard = self.candidates.write().await;
        let candidate = match guard.iter_mut().find(|c| c.endpoint == endpoint) {
            Some(candidate) => candidate,
            None => {
                guard.push(Candidate::new(
                    endpoint,
                    CandidateKind::ServerReflexive,
                    "quic-observed".to_string(),
                ));
                guard.last_mut().expect("candidate was just inserted")
            }
        };
        candidate.record_quality(rtt_ms, loss_rate);
        candidate.last_success_timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let mut active = self.active_candidate.write().await;
        if active
            .as_ref()
            .is_some_and(|active| active.endpoint == endpoint)
        {
            *active = Some(candidate.clone());
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
        let guard = self.candidates.read().await;
        let active = self.active_candidate.read().await.clone()?;
        let active_score = candidate_score(&active);
        guard
            .iter()
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
    pub async fn activate_path(&self, endpoint: std::net::SocketAddr) -> bool {
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
    pub async fn get_candidate(&self, endpoint: std::net::SocketAddr) -> Option<Candidate> {
        self.candidates
            .read()
            .await
            .iter()
            .find(|candidate| candidate.endpoint == endpoint)
            .cloned()
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
    async fn multiple_candidates_rank_and_replace_by_generation() {
        let manager = PathManager::new();
        let lan = candidate("192.168.1.10:41004", CandidateKind::Lan).with_generation(2);
        let srflx =
            candidate("203.0.113.10:41005", CandidateKind::ServerReflexive).with_generation(2);
        assert!(
            manager
                .apply_remote_candidates(2, vec![srflx.clone(), lan.clone()])
                .await
        );

        let ranked = manager.ranked_candidates().await;
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0].candidate_id, lan.candidate_id);

        let stale = candidate("192.168.1.10:41006", CandidateKind::Lan).with_generation(1);
        assert!(!manager.apply_remote_candidates(1, vec![stale]).await);
        assert_eq!(manager.ranked_candidates().await.len(), 2);

        let ipv6 = candidate("[2001:db8::10]:41007", CandidateKind::PublicIpv6).with_generation(3);
        assert!(manager.apply_remote_candidates(3, vec![ipv6.clone()]).await);
        let ranked = manager.ranked_candidates().await;
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].candidate_id, ipv6.candidate_id);
    }
}
