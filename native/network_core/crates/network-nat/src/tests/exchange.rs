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

#[test]
fn v1_json_exchange_is_unchanged_when_v2_fields_are_absent() {
    let candidate = Candidate::new(
        "192.168.1.10:40009".parse().unwrap(),
        CandidateKind::Lan,
        "wifi".into(),
    )
    .with_generation(6)
    .advertisement();
    let signal = CandidateSignal::offer(
        6,
        "attempt-a".into(),
        DEFAULT_CONNECT_WINDOW_MS,
        vec![candidate],
    );
    let json = serde_json::to_value(&signal).unwrap();
    let object = json.as_object().unwrap();
    assert!(
        !object.contains_key("runtime_epoch"),
        "v1 JSON must not emit runtime_epoch"
    );
    assert!(
        !object.contains_key("discovery_revision"),
        "v1 JSON must not emit discovery_revision"
    );
    // Old v1 JSON (without the new fields) must still deserialize.
    let old_json = r#"{
            "version": 1,
            "kind": "offer",
            "generation": 6,
            "attempt_id": "attempt-a",
            "connect_window_ms": 4000,
            "candidates": [{
                "candidate_id": "wifi@192.168.1.10:40009",
                "endpoint": "192.168.1.10:40009",
                "kind": "lan",
                "priority": 100,
                "interface": "wifi",
                "generation": 6
            }]
        }"#;
    let decoded: CandidateSignal = serde_json::from_str(old_json).unwrap();
    assert_eq!(decoded.runtime_epoch, None);
    assert_eq!(decoded.discovery_revision, None);
    assert_eq!(decoded.candidates.len(), 1);
}

#[test]
fn v2_epoch_and_revision_round_trip_additively() {
    let candidate = Candidate::new(
        "192.168.1.10:40010".parse().unwrap(),
        CandidateKind::Lan,
        "wifi".into(),
    )
    .with_generation(6)
    .advertisement();
    let signal = CandidateSignal::offer(
        6,
        "attempt-a".into(),
        DEFAULT_CONNECT_WINDOW_MS,
        vec![candidate],
    )
    .with_epoch_revision(RuntimeEpoch { high: 11, low: 12 }, 22);
    let json = serde_json::to_value(&signal).unwrap();
    let object = json.as_object().unwrap();
    let runtime_epoch = object["runtime_epoch"].as_object().unwrap();
    assert_eq!(runtime_epoch["high"], 11);
    assert_eq!(runtime_epoch["low"], 12);
    assert_eq!(object["discovery_revision"], 22);
    let decoded: CandidateSignal = serde_json::from_value(json).unwrap();
    assert_eq!(
        decoded.runtime_epoch,
        Some(RuntimeEpoch { high: 11, low: 12 }),
    );
    assert_eq!(decoded.discovery_revision, Some(22));
}
