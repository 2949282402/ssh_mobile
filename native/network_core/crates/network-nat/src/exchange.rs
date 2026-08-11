use crate::candidate::{Candidate, CandidateAdvertisement};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const CANDIDATE_SIGNAL_VERSION: u32 = 1;
pub const MAX_CANDIDATES_PER_SIGNAL: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateSignalKind {
    Offer,
    Answer,
}

/// Candidate Exchange 的有界 Offer/Answer 信令消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CandidateSignal {
    pub version: u32,
    pub kind: CandidateSignalKind,
    pub generation: u64,
    pub candidates: Vec<CandidateAdvertisement>,
}

impl CandidateSignal {
    pub fn offer(generation: u64, candidates: Vec<CandidateAdvertisement>) -> Self {
        Self {
            version: CANDIDATE_SIGNAL_VERSION,
            kind: CandidateSignalKind::Offer,
            generation,
            candidates,
        }
    }

    pub fn answer(generation: u64, candidates: Vec<CandidateAdvertisement>) -> Self {
        Self {
            version: CANDIDATE_SIGNAL_VERSION,
            kind: CandidateSignalKind::Answer,
            generation,
            candidates,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != CANDIDATE_SIGNAL_VERSION {
            return Err("unsupported candidate signal version".into());
        }
        if self.generation == 0 || self.candidates.len() > MAX_CANDIDATES_PER_SIGNAL {
            return Err("candidate signal generation or size is invalid".into());
        }
        let mut ids = HashMap::new();
        for candidate in &self.candidates {
            if candidate.generation != self.generation
                || ids.insert(candidate.candidate_id.clone(), ()).is_some()
            {
                return Err("candidate signal contains duplicate or stale candidates".into());
            }
            Candidate::from_advertisement(candidate.clone())?;
        }
        Ok(())
    }
}

/// 对一个远端 Candidate generation 的接收状态；旧 generation 永不回写当前集合。
#[derive(Debug, Default)]
pub struct CandidateExchangeState {
    generation: u64,
    candidates: HashMap<String, Candidate>,
}

impl CandidateExchangeState {
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn apply(&mut self, signal: &CandidateSignal) -> Result<bool, String> {
        signal.validate()?;
        if signal.generation < self.generation {
            return Ok(false);
        }
        if signal.generation > self.generation {
            self.generation = signal.generation;
            self.candidates.clear();
        } else {
            let incoming_ids = signal
                .candidates
                .iter()
                .map(|candidate| candidate.candidate_id.clone())
                .collect::<HashSet<_>>();
            self.candidates
                .retain(|candidate_id, _| incoming_ids.contains(candidate_id));
        }
        for advertisement in &signal.candidates {
            self.candidates.insert(
                advertisement.candidate_id.clone(),
                Candidate::from_advertisement(advertisement.clone())?,
            );
        }
        Ok(true)
    }

    pub fn candidates(&self) -> Vec<Candidate> {
        self.candidates.values().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate::{Candidate, CandidateKind};
    use std::net::SocketAddr;

    fn signal(kind: CandidateSignalKind, generation: u64, port: u16) -> CandidateSignal {
        let candidate = Candidate::new(
            SocketAddr::from(([192, 168, 1, 10], port)),
            CandidateKind::Lan,
            "wifi".into(),
        )
        .with_generation(generation);
        CandidateSignal {
            version: CANDIDATE_SIGNAL_VERSION,
            kind,
            generation,
            candidates: vec![candidate.advertisement()],
        }
    }

    #[test]
    fn stale_generation_cannot_replace_new_candidates() {
        let mut state = CandidateExchangeState::default();
        assert!(state
            .apply(&signal(CandidateSignalKind::Offer, 2, 40002))
            .unwrap());
        assert!(!state
            .apply(&signal(CandidateSignalKind::Answer, 1, 40001))
            .unwrap());
        assert_eq!(state.generation(), 2);
        assert_eq!(state.candidates()[0].endpoint.port(), 40002);
    }

    #[test]
    fn candidate_signal_rejects_duplicate_ids_and_mismatched_generation() {
        let candidate = Candidate::new(
            "192.168.1.10:40001".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        )
        .with_generation(3)
        .advertisement();
        let mut signal = CandidateSignal::offer(3, vec![candidate.clone(), candidate]);
        assert!(signal.validate().is_err());
        signal.candidates[0].generation = 2;
        signal.candidates.truncate(1);
        assert!(signal.validate().is_err());
    }

    #[test]
    fn same_generation_update_removes_candidates_not_in_the_new_set() {
        let mut state = CandidateExchangeState::default();
        assert!(state
            .apply(&signal(CandidateSignalKind::Offer, 4, 40004))
            .unwrap());
        assert!(state
            .apply(&signal(CandidateSignalKind::Answer, 4, 40005))
            .unwrap());
        assert_eq!(state.candidates().len(), 1);
        assert_eq!(state.candidates()[0].endpoint.port(), 40005);
    }
}
