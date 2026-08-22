use super::*;

#[test]
fn direct_recovery_backoff_matches_frozen_schedule() {
    let expected = [1, 2, 4, 8, 15, 30, 30, 30];
    for (attempt, seconds) in expected.into_iter().enumerate() {
        assert_eq!(
            DirectRecoveryPolicy::base_delay_for_attempt(attempt),
            Duration::from_secs(seconds)
        );
    }
}

#[test]
fn direct_recovery_requires_relay_ready_and_keeps_relay_business_available() {
    let mut policy = DirectRecoveryPolicy::new();
    assert!(!policy.relay_business_available());
    assert!(!policy.can_probe_direct());
    assert_eq!(policy.next_delay_with_jitter(Duration::ZERO), None);

    policy.mark_relay_ready();
    policy.mark_direct_unavailable();
    assert!(policy.relay_business_available());
    assert!(policy.can_probe_direct());
    assert_eq!(
        policy.next_delay_with_jitter(Duration::from_millis(7)),
        Some(Duration::from_secs(1) + Duration::from_millis(7))
    );
}

#[test]
fn environment_change_resets_retry_schedule_without_losing_relay_readiness() {
    let mut policy = DirectRecoveryPolicy::new();
    policy.mark_relay_ready();
    policy.mark_direct_unavailable();
    assert_eq!(
        policy.next_delay_with_jitter(Duration::ZERO),
        Some(Duration::from_secs(1))
    );
    assert_eq!(
        policy.next_delay_with_jitter(Duration::ZERO),
        Some(Duration::from_secs(2))
    );

    policy.mark_direct_ready();
    assert!(!policy.can_probe_direct());
    policy.reset_after_environment_change();
    assert!(policy.relay_business_available());
    assert!(policy.can_probe_direct());
    assert_eq!(
        policy.next_delay_with_jitter(Duration::ZERO),
        Some(Duration::from_secs(1))
    );
}

#[tokio::test(start_paused = true)]
async fn direct_recovery_wait_uses_paused_tokio_time() {
    let mut policy = DirectRecoveryPolicy::new();
    policy.mark_relay_ready();
    policy.mark_direct_unavailable();

    let wait =
        tokio::spawn(async move { policy.wait_for_next_probe_with_jitter(Duration::ZERO).await });
    tokio::task::yield_now().await;
    assert!(!wait.is_finished());
    tokio::time::advance(Duration::from_secs(1)).await;
    assert_eq!(
        wait.await.expect("recovery wait task"),
        Some(Duration::from_secs(1))
    );
}
