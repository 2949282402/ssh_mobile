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
