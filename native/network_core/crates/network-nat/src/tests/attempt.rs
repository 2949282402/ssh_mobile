use super::*;
use crate::candidate::CandidateKind;
use crate::exchange::{
    CandidateSignal, CandidateSignalKind, RuntimeEpoch, DEFAULT_CONNECT_WINDOW_MS,
};
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

fn epoch(high: u64, low: u64) -> RuntimeEpoch {
    RuntimeEpoch { high, low }
}

fn attempt(attempt_id: &str) -> ConnectivityAttempt {
    ConnectivityAttempt::with_connect_window(
        attempt_id,
        "peer-a",
        RuntimeEpoch { high: 0, low: 7 },
        SystemTime::now(),
        Duration::from_secs(5),
    )
}

#[test]
fn fresh_attempt_is_created_and_tracks_deadline() {
    let started_at = SystemTime::now();
    let mut attempt = ConnectivityAttempt::new(
        "attempt-1",
        "peer-a",
        RuntimeEpoch { high: 0, low: 7 },
        started_at,
        None,
    );
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
        RuntimeEpoch { high: 0, low: 7 },
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
    assert_eq!(attempt.remote_runtime_epoch(), None);
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
    assert_eq!(attempt.remote_runtime_epoch(), None);
    assert_eq!(attempt.remote_candidates().len(), 1);
    assert_eq!(attempt.remote_candidates()[0].endpoint.port(), 40002);
}

#[test]
fn stale_revision_cannot_regress_a_live_attempt() {
    let mut attempt = attempt("attempt-a");
    assert!(attempt
        .apply_signal(&signal(CandidateSignalKind::Offer, "attempt-a", 4, 40004))
        .unwrap());
    assert!(!attempt
        .apply_signal(&signal(CandidateSignalKind::Answer, "attempt-a", 1, 40001))
        .unwrap());
    assert_eq!(attempt.remote_runtime_epoch(), None);
    assert_eq!(attempt.remote_candidates()[0].endpoint.port(), 40004);
}

#[test]
fn different_runtime_epoch_replaces_snapshot_without_numeric_ordering() {
    let first = Candidate::new(
        "192.168.1.20:41020".parse().unwrap(),
        CandidateKind::Lan,
        "first".into(),
    );
    let second = Candidate::new(
        "198.51.100.20:42020".parse().unwrap(),
        CandidateKind::PublicIpv6,
        "second".into(),
    );
    let mut attempt = attempt("attempt-epoch");
    assert!(attempt
        .apply_remote_candidates(Some(epoch(u64::MAX, u64::MAX)), 9, vec![first],)
        .unwrap());
    assert!(attempt
        .apply_remote_candidates(Some(epoch(0, 1)), 1, vec![second.clone()])
        .unwrap());
    assert_eq!(attempt.remote_runtime_epoch(), Some(epoch(0, 1)));
    assert_eq!(attempt.remote_discovery_revision(), Some(1));
    assert_eq!(attempt.remote_candidates().len(), 1);
    assert_eq!(
        attempt.remote_candidates()[0].candidate_id,
        second.candidate_id
    );
}

#[test]
fn v2_epoch_and_revision_are_carried_into_the_attempt() {
    let mut attempt = attempt("attempt-v2");
    let mut offer = signal(CandidateSignalKind::Offer, "attempt-v2", 3, 40009);
    offer = offer.with_epoch_revision(RuntimeEpoch { high: 11, low: 12 }, 22);
    assert!(attempt.apply_signal(&offer).unwrap());
    assert_eq!(attempt.remote_runtime_epoch(), Some(epoch(11, 12)));
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
        .apply_remote_candidates(Some(epoch(0, 7)), 1, vec![first.clone(), second.clone()])
        .unwrap());
    assert_eq!(attempt.remote_candidates().len(), 2);

    assert!(attempt
        .apply_remote_candidates(Some(epoch(0, 7)), 2, vec![second.clone()])
        .unwrap());
    assert_eq!(attempt.remote_candidates().len(), 1);
    assert_eq!(
        attempt.remote_candidates()[0].candidate_id,
        second.candidate_id
    );

    assert!(!attempt
        .apply_remote_candidates(Some(epoch(0, 7)), 1, vec![first])
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
        .apply_remote_candidates(Some(epoch(0, 7)), 2, vec![first.clone()])
        .unwrap());
    assert!(!attempt
        .apply_remote_candidates(Some(epoch(0, 7)), 1, vec![replacement.clone()])
        .unwrap());
    assert_eq!(
        attempt.remote_candidates()[0].candidate_id,
        first.candidate_id
    );

    assert!(attempt.set_state(ConnectivityAttemptState::Succeeded));
    assert!(!attempt
        .apply_remote_candidates(Some(epoch(0, 8)), 3, vec![replacement])
        .unwrap());
    assert_eq!(
        attempt.remote_candidates()[0].candidate_id,
        first.candidate_id
    );
}

#[test]
fn late_matching_answer_is_cache_only_and_does_not_mutate_attempt() {
    let started_at = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
    let mut attempt = ConnectivityAttempt::with_connect_window(
        "attempt-late",
        "peer-a",
        epoch(0, 7),
        started_at,
        Duration::from_secs(5),
    );
    let initial_signal = signal(CandidateSignalKind::Answer, "attempt-late", 2, 40002);
    let before_deadline = started_at + Duration::from_secs(4);
    assert_eq!(
        attempt
            .apply_signal_with_deadline(&initial_signal, before_deadline)
            .unwrap(),
        CandidateUpdateDisposition::Applied
    );
    let candidate_count = attempt.remote_candidates().len();

    let mut late = signal(CandidateSignalKind::Answer, "attempt-late", 3, 40003);
    late.runtime_epoch = Some(epoch(1, 1));
    late.discovery_revision = Some(3);
    assert_eq!(
        attempt
            .apply_signal_with_deadline(&late, started_at + Duration::from_secs(5))
            .unwrap(),
        CandidateUpdateDisposition::CacheOnly
    );
    assert_eq!(attempt.remote_candidates().len(), candidate_count);
}

#[test]
fn wrong_attempt_answer_is_ignored_even_inside_the_direct_window() {
    let started_at = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
    let mut attempt = ConnectivityAttempt::with_connect_window(
        "attempt-current",
        "peer-a",
        epoch(0, 7),
        started_at,
        Duration::from_secs(5),
    );
    let stale = signal(CandidateSignalKind::Answer, "attempt-old", 2, 40002);
    assert_eq!(
        attempt
            .apply_signal_with_deadline(&stale, started_at + Duration::from_secs(1))
            .unwrap(),
        CandidateUpdateDisposition::IgnoredStale
    );
    assert!(attempt.remote_candidates().is_empty());
}
