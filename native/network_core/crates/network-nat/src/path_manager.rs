use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;
use crate::candidate::Candidate;

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
            if !guard.iter().any(|c| c.endpoint == item.endpoint) {
                guard.push(item);
            }
        }
    }

    /// Selects the best candidate based on priority, RTT, and loss rate.
    pub async fn select_best_path(&self) -> Option<Candidate> {
        let guard = self.candidates.read().await;
        let mut best: Option<Candidate> = None;
        let mut best_score = -1.0f32;

        for cand in guard.iter() {
            // Higher priority, lower RTT, lower loss rate yields higher score
            let rtt_penalty = (cand.rtt_ms as f32) * 0.1;
            let loss_penalty = cand.loss_rate * 500.0;
            let score = (cand.priority as f32) - rtt_penalty - loss_penalty;

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

    /// Returns the currently active path.
    pub async fn get_active_path(&self) -> Option<Candidate> {
        self.active_candidate.read().await.clone()
    }
}
