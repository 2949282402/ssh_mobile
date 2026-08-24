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

#[tokio::test]
async fn candidate_lifecycle_handles_missing_paths_generation_and_metric_clamps() {
    let manager = PathManager::default();
    let missing = "127.0.0.1:41999".parse().unwrap();
    assert_eq!(manager.generation().await, 0);
    assert!(manager.ranked_candidates().await.is_empty());
    assert!(manager.get_active_path().await.is_none());
    assert!(manager.better_path_than_active().await.is_none());
    assert!(manager.get_candidate(missing).await.is_none());
    assert!(!manager.activate_path(missing).await);

    let endpoint = "127.0.0.1:41030".parse().unwrap();
    let mut initial = candidate("127.0.0.1:41030", CandidateKind::Lan);
    initial.priority = 70;
    initial.generation = 1;
    manager.add_candidates(vec![initial.clone()]).await;

    // An unmeasured existing candidate takes the replacement quality fields.
    let mut replacement = initial.clone();
    replacement.candidate_id = "replacement".into();
    replacement.interface_name = "ethernet".into();
    replacement.kind = CandidateKind::PublicIpv6;
    replacement.priority = 90;
    replacement.generation = 2;
    replacement.rtt_ms = 99;
    replacement.jitter_ms = 11;
    replacement.loss_rate = 0.7;
    replacement.sample_count = 3;
    manager.add_candidates(vec![replacement.clone()]).await;
    let stored = manager.get_candidate(endpoint).await.expect("candidate");
    assert_eq!(stored.candidate_id, "replacement");
    assert_eq!(stored.sample_count, 3);
    assert_eq!(stored.rtt_ms, 99);

    manager.set_generation(9).await;
    assert_eq!(manager.generation().await, 9);
    assert_eq!(manager.get_candidate(endpoint).await.unwrap().generation, 9);

    // A sample on an existing candidate uses zero-sent semantics, while a
    // previously unseen endpoint becomes a server-reflexive candidate.
    manager
        .record_quic_sample(endpoint, Duration::from_millis(100), 0, 5)
        .await;
    assert!((manager.get_candidate(endpoint).await.unwrap().loss_rate - 0.525).abs() < 0.001);
    let observed = "127.0.0.1:41031".parse().unwrap();
    manager
        .record_quic_sample(observed, Duration::from_millis(20), 2, 99)
        .await;
    let observed_candidate = manager.get_candidate(observed).await.unwrap();
    assert_eq!(observed_candidate.kind, CandidateKind::ServerReflexive);
    assert_eq!(observed_candidate.loss_rate, 1.0);
    assert_eq!(observed_candidate.sample_count, 1);
    assert!(manager.get_active_path().await.is_none());

    let selected = manager.select_best_path().await.expect("selected path");
    assert_eq!(
        manager.get_active_path().await.unwrap().endpoint,
        selected.endpoint
    );
    manager
        .record_quic_sample(selected.endpoint, Duration::from_millis(30), 10, 1)
        .await;
    assert_eq!(
        manager.get_active_path().await.unwrap().endpoint,
        selected.endpoint
    );

    // Once quality has been sampled, an endpoint replacement keeps that live
    // quality instead of accepting stale values from discovery.
    let mut stale_quality = replacement;
    stale_quality.sample_count = 0;
    stale_quality.rtt_ms = u32::MAX;
    manager.add_candidates(vec![stale_quality]).await;
    assert_ne!(
        manager.get_candidate(endpoint).await.unwrap().rtt_ms,
        u32::MAX
    );

    manager
        .record_connection_path_metrics(endpoint, 40, 5, 2.0)
        .await;
    manager
        .record_connection_path_metrics(endpoint, 80, 15, -1.0)
        .await;
    let metrics = manager.connection_path_metrics().await;
    assert_eq!(metrics.len(), 1);
    assert!((metrics[0].loss_rate - 0.75).abs() < 0.001);

    manager
        .record_historical_path_metrics(endpoint, 20, 3, 2.0, 4)
        .await;
    let history = manager.historical_path_metrics().await;
    assert_eq!(history[0].avg_loss_rate, 1.0);
    assert!(manager.activate_path(endpoint).await);
    assert!(!manager.activate_path(missing).await);
}
