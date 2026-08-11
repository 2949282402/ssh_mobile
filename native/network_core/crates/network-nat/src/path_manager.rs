use crate::candidate::{Candidate, CandidateKind};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;
use tracing::info;

const MIGRATION_SCORE_HYSTERESIS: f32 = 15.0;

/// Manages candidate selection, path scoring, keepalives, and reprobing.
pub struct PathManager {
    candidates: Arc<RwLock<Vec<Candidate>>>,
    active_candidate: Arc<RwLock<Option<Candidate>>>,
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
        }
    }

    /// Adds or updates discovered candidates.
    pub async fn add_candidates(&self, list: Vec<Candidate>) {
        let mut guard = self.candidates.write().await;
        for item in list {
            if let Some(existing) = guard.iter_mut().find(|c| c.endpoint == item.endpoint) {
                let previous_quality = existing.sample_count > 0;
                existing.interface_name = item.interface_name;
                existing.kind = item.kind;
                existing.priority = item.priority;
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
        let guard = self.candidates.read().await;
        let mut best: Option<Candidate> = None;
        let mut best_score = f32::NEG_INFINITY;

        for cand in guard.iter() {
            let score = candidate_score(cand);

            if score > best_score {
                best_score = score;
                best = Some(cand.clone());
            }
        }

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
}
