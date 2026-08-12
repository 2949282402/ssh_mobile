use crate::candidate::{Candidate, CandidateAdvertisement};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const CANDIDATE_SIGNAL_VERSION: u32 = 1;
pub const MAX_CANDIDATES_PER_SIGNAL: usize = 32;
pub const MIN_CONNECT_WINDOW_MS: u32 = 500;
pub const MAX_CONNECT_WINDOW_MS: u32 = 8_000;
pub const DEFAULT_CONNECT_WINDOW_MS: u32 = 4_000;
pub const MAX_ATTEMPT_ID_BYTES: usize = 128;

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
    /// Identifies one simultaneous QUIC connectivity window. Answers echo
    /// the offer's ID so stale answers cannot update a newer attempt.
    pub attempt_id: String,
    /// Shared bounded time budget for parallel direct connection attempts.
    pub connect_window_ms: u32,
    pub candidates: Vec<CandidateAdvertisement>,
}

impl CandidateSignal {
    pub fn offer(
        generation: u64,
        attempt_id: String,
        connect_window_ms: u32,
        candidates: Vec<CandidateAdvertisement>,
    ) -> Self {
        Self {
            version: CANDIDATE_SIGNAL_VERSION,
            kind: CandidateSignalKind::Offer,
            generation,
            attempt_id,
            connect_window_ms,
            candidates,
        }
    }

    pub fn answer(
        generation: u64,
        attempt_id: String,
        connect_window_ms: u32,
        candidates: Vec<CandidateAdvertisement>,
    ) -> Self {
        Self {
            version: CANDIDATE_SIGNAL_VERSION,
            kind: CandidateSignalKind::Answer,
            generation,
            attempt_id,
            connect_window_ms,
            candidates,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != CANDIDATE_SIGNAL_VERSION {
            return Err("unsupported candidate signal version".into());
        }
        if self.generation == 0
            || self.attempt_id.is_empty()
            || self.attempt_id.len() > MAX_ATTEMPT_ID_BYTES
            || !self.attempt_id.bytes().all(|byte| byte.is_ascii_graphic())
            || !(MIN_CONNECT_WINDOW_MS..=MAX_CONNECT_WINDOW_MS).contains(&self.connect_window_ms)
            || self.candidates.len() > MAX_CANDIDATES_PER_SIGNAL
        {
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
    attempt_id: Option<String>,
    connect_window_ms: u32,
    candidates: HashMap<String, Candidate>,
}

impl CandidateExchangeState {
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn attempt_id(&self) -> Option<&str> {
        self.attempt_id.as_deref()
    }

    pub fn connect_window_ms(&self) -> u32 {
        self.connect_window_ms
    }

    pub fn apply(&mut self, signal: &CandidateSignal) -> Result<bool, String> {
        signal.validate()?;
        if signal.generation < self.generation {
            return Ok(false);
        }
        let is_new_attempt = self
            .attempt_id
            .as_deref()
            .is_some_and(|attempt_id| attempt_id != signal.attempt_id);
        if signal.generation > self.generation
            || (is_new_attempt && signal.kind == CandidateSignalKind::Offer)
        {
            self.generation = signal.generation;
            self.attempt_id = Some(signal.attempt_id.clone());
            self.connect_window_ms = signal.connect_window_ms;
            self.candidates.clear();
        } else if is_new_attempt {
            return Ok(false);
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
        if self.attempt_id.is_none() {
            self.attempt_id = Some(signal.attempt_id.clone());
            self.connect_window_ms = signal.connect_window_ms;
        } else {
            self.connect_window_ms = signal.connect_window_ms;
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
        match kind {
            CandidateSignalKind::Offer => CandidateSignal::offer(
                generation,
                "attempt-a".into(),
                DEFAULT_CONNECT_WINDOW_MS,
                vec![candidate.advertisement()],
            ),
            CandidateSignalKind::Answer => CandidateSignal::answer(
                generation,
                "attempt-a".into(),
                DEFAULT_CONNECT_WINDOW_MS,
                vec![candidate.advertisement()],
            ),
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
        assert_eq!(state.attempt_id(), Some("attempt-a"));
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
        let mut signal = CandidateSignal::offer(
            3,
            "attempt-a".into(),
            DEFAULT_CONNECT_WINDOW_MS,
            vec![candidate.clone(), candidate],
        );
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

    #[test]
    fn stale_answer_attempt_is_rejected_but_new_offer_starts_a_window() {
        let mut state = CandidateExchangeState::default();
        assert!(state
            .apply(&signal(CandidateSignalKind::Offer, 5, 40005))
            .unwrap());
        let mut stale_answer = signal(CandidateSignalKind::Answer, 5, 40006);
        stale_answer.attempt_id = "attempt-old".into();
        assert!(!state.apply(&stale_answer).unwrap());
        let mut new_offer = signal(CandidateSignalKind::Offer, 5, 40007);
        new_offer.attempt_id = "attempt-new".into();
        assert!(state.apply(&new_offer).unwrap());
        assert_eq!(state.attempt_id(), Some("attempt-new"));
        assert_eq!(state.candidates()[0].endpoint.port(), 40007);
    }

    #[test]
    fn signal_bounds_connect_window_and_attempt_id() {
        let candidate = Candidate::new(
            "192.168.1.10:40008".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        )
        .with_generation(6)
        .advertisement();
        let mut signal = CandidateSignal::offer(
            6,
            "attempt-a".into(),
            MIN_CONNECT_WINDOW_MS - 1,
            vec![candidate],
        );
        assert!(signal.validate().is_err());
        signal.connect_window_ms = MAX_CONNECT_WINDOW_MS + 1;
        assert!(signal.validate().is_err());
        signal.connect_window_ms = DEFAULT_CONNECT_WINDOW_MS;
        signal.attempt_id = " ".into();
        assert!(signal.validate().is_err());
    }
}
