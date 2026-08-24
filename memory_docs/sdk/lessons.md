> Last updated: 2026-08-23

# SDK Lessons

- A `ConnectionSession` is 1:1 with one transport Connection. A new connection
  gets a new `SessionId` and Noise root, and transport loss destroys the
  ConnectionSession; it does not preserve a logical Session across transports.
  See the [Connection lifecycle ADR](../../docs/adr/ADR-CONNECTION-LIFECYCLE-V2.md).
- Queue acceptance, native command completion, transport ACK, and application
  ACK prove different things. See the
  [Delivery recovery ADR](../../docs/adr/ADR-010-delivery-recovery-layer.md) and
  [Realtime command ADR](../../docs/adr/ADR-026-realtime-command-completion-correlation.md).
- Active receive state is not processed dedup history. TTL/LRU pruning must not
  discard in-flight or ordered-buffered work. See the
  [active delivery ADR](../../docs/adr/ADR-025-active-delivery-state-lifetime.md).
- Delivery and Transfer are the cross-connection continuity boundary: Delivery
  resumes by `MessageId`/channel state, and Transfer resumes by `transfer_id`+
  `confirmed_offset` on the new ConnectionSession. See the
  [business recovery ADR](../../docs/adr/ADR-BUSINESS-RECOVERY-V2.md).
- A Noise transcript hash is context, not secret root material. See the
  [forward-secret E2EE ADR](../../docs/adr/ADR-028-forward-secret-session-e2ee.md).
- Relay forwards opaque protocol stages; it does not own plaintext, RootSeed,
  or Application Root.
- A `PathHandle` or runtime projection is not a carrier owner. Direct/Relay
  path ownership stays in `PeerPathManager`; business code must hold a
  `PathLease`, and hard close must close streams bound to an inactive lease.
- Passive inbound is not a reconnect request. Preserve maintenance only when it
  was explicitly enabled, and gate Direct recovery on a ready Relay path so a
  Direct optimisation cannot interrupt healthy Relay/Realtime service.
- Keep test instrumentation in independent test files (for example, the
  `src/tests/` files selected with `#[path]`); do not add `#[cfg(test)]` fields,
  hooks, observers, or other test-only coupling to production implementation
  modules. Test-side fixtures may use existing diagnostic/read-only APIs and
  record their own events without widening a production contract.
- A WSL validation failure may move to native Windows PowerShell 7 (or CI) only
  when the evidence identifies an environment/toolchain gap, such as a Flutter
  VM Service that never starts. A product or test correctness failure must be
  fixed rather than bypassed; Windows evidence remains separately labeled and
  does not turn the WSL/Linux gap into a PASS.
