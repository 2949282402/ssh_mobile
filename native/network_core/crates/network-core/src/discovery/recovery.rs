//! Direct recovery policy owned by the discovery/reprobe lifecycle.
//!
//! A Direct reprobe is an optimisation after an authenticated Relay path is
//! ready.  It must never become a prerequisite for Relay business traffic and
//! it must not run for a peer that has no usable Relay path.  The coordinator
//! owns the actual connectivity attempt; this module owns only the gate and
//! the frozen delay policy.

use std::time::Duration;

/// Frozen Direct recovery base schedule.  The final delay is reused after the
/// bounded prefix; jitter is added by [`DirectRecoveryPolicy::next_delay`].
pub(crate) const DIRECT_RECOVERY_BASE_BACKOFF: [Duration; 6] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(15),
    Duration::from_secs(30),
];

/// Maximum random additive jitter as a fraction of the current base delay.
/// A small additive window keeps the frozen schedule recognisable while
/// avoiding synchronised probes from many peers after one network change.
const JITTER_DIVISOR: u64 = 10;

/// Explicit state required before a Direct recovery probe may be scheduled.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct DirectRecoveryPolicy {
    relay_ready: bool,
    direct_ready: bool,
    attempt: usize,
}

impl Default for DirectRecoveryPolicy {
    fn default() -> Self {
        Self::new()
    }
}

impl DirectRecoveryPolicy {
    pub(crate) const fn new() -> Self {
        Self {
            relay_ready: false,
            direct_ready: false,
            attempt: 0,
        }
    }

    /// Mark the authenticated Relay route usable.  This is deliberately
    /// separate from Direct readiness: Relay business work can proceed while
    /// Direct recovery is waiting or probing.
    pub(crate) fn mark_relay_ready(&mut self) {
        if !self.relay_ready {
            self.attempt = 0;
        }
        self.relay_ready = true;
    }

    pub(crate) fn mark_relay_lost(&mut self) {
        self.relay_ready = false;
        self.attempt = 0;
    }

    pub(crate) fn mark_direct_unavailable(&mut self) {
        self.direct_ready = false;
    }

    pub(crate) fn mark_direct_ready(&mut self) {
        self.direct_ready = true;
        self.attempt = 0;
    }

    /// Network changes invalidate the old Direct assumptions and restart the
    /// recovery schedule while preserving Relay readiness.  The coordinator
    /// must reprobe Direct rather than treating the old path as still ready.
    pub(crate) fn reset_after_environment_change(&mut self) {
        self.attempt = 0;
        self.direct_ready = false;
    }

    /// Relay business availability is intentionally independent of Direct
    /// recovery.  A caller can use this before scheduling a probe so business
    /// operations do not wait for the background optimisation.
    #[allow(dead_code)]
    pub(crate) const fn relay_business_available(&self) -> bool {
        self.relay_ready
    }

    /// The only state in which a Direct recovery attempt is eligible.
    pub(crate) const fn can_probe_direct(&self) -> bool {
        self.relay_ready && !self.direct_ready
    }

    /// Return the frozen base delay for the next attempt, without consuming
    /// the attempt.  This is useful for deterministic policy tests and
    /// diagnostics.
    pub(crate) const fn base_delay_for_attempt(attempt: usize) -> Duration {
        let index = if attempt < DIRECT_RECOVERY_BASE_BACKOFF.len() {
            attempt
        } else {
            DIRECT_RECOVERY_BASE_BACKOFF.len() - 1
        };
        DIRECT_RECOVERY_BASE_BACKOFF[index]
    }

    /// Consume the next retry slot and add caller-supplied jitter.  Supplying
    /// jitter explicitly keeps scheduling deterministic for paused-time tests;
    /// production callers should use [`Self::next_delay`].
    pub(crate) fn next_delay_with_jitter(&mut self, jitter: Duration) -> Option<Duration> {
        if !self.can_probe_direct() {
            return None;
        }
        let base = Self::base_delay_for_attempt(self.attempt);
        self.attempt = self.attempt.saturating_add(1);
        Some(base.saturating_add(jitter))
    }

    /// Consume the next retry slot with bounded random additive jitter.
    pub(crate) fn next_delay(&mut self) -> Option<Duration> {
        let base = Self::base_delay_for_attempt(self.attempt);
        let jitter_window_ms = (base.as_millis() as u64 / JITTER_DIVISOR).max(1);
        let jitter = Duration::from_millis(rand::random::<u64>() % (jitter_window_ms + 1));
        self.next_delay_with_jitter(jitter)
    }

    /// Wait for the next eligible Direct probe.  The coordinator should start
    /// the probe only after this future completes and must not gate Relay
    /// business calls on it.
    #[allow(dead_code)]
    pub(crate) async fn wait_for_next_probe(&mut self) -> Option<Duration> {
        let delay = self.next_delay()?;
        tokio::time::sleep(delay).await;
        Some(delay)
    }

    #[cfg(test)]
    async fn wait_for_next_probe_with_jitter(&mut self, jitter: Duration) -> Option<Duration> {
        let delay = self.next_delay_with_jitter(jitter)?;
        tokio::time::sleep(delay).await;
        Some(delay)
    }
}

#[cfg(test)]
mod tests {
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
            tokio::spawn(
                async move { policy.wait_for_next_probe_with_jitter(Duration::ZERO).await },
            );
        tokio::task::yield_now().await;
        assert!(!wait.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        assert_eq!(
            wait.await.expect("recovery wait task"),
            Some(Duration::from_secs(1))
        );
    }
}
