> Last updated: 2026-08-13

# SDK Lessons

- Session is not Connection. A route or transport replacement does not by
  itself create a new logical Session. See the
  [Session/Connection ADR](../../docs/adr/ADR-007-session-connection-separation.md).
- Queue acceptance, native command completion, transport ACK, and application
  ACK prove different things. See the
  [Delivery recovery ADR](../../docs/adr/ADR-010-delivery-recovery-layer.md) and
  [Realtime command ADR](../../docs/adr/ADR-026-realtime-command-completion-correlation.md).
- Active receive state is not processed dedup history. TTL/LRU pruning must not
  discard in-flight or ordered-buffered work. See the
  [active delivery ADR](../../docs/adr/ADR-025-active-delivery-state-lifetime.md).
- Route migration preserves Session-owned state only after the replacement
  carrier is authenticated and committed. See the
  [generic routes ADR](../../docs/adr/ADR-027-generic-session-routes.md).
- A Noise transcript hash is context, not secret root material. See the
  [forward-secret E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md).
- Relay forwards opaque protocol stages; it does not own plaintext, RootSeed,
  or Application Root.
