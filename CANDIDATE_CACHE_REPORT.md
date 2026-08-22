> Last updated: 2026-08-21

# Candidate Cache V2 Audit

Status: BLOCKED

Scope: Candidate cache freshness, epoch invalidation, Stage A/B integration, and
server TTL synchronization. This was a read-only audit; no implementation files
were changed.

## Findings

1. PASS: TTL-in-window freshness uses monotonic `Instant`
   (`network-nat/src/candidate_v2.rs:569,573`); covered by
   `cache_uses_monotonic_age_and_server_confirmed_ttl` and the Stage A cache
   test (`candidate_v2.rs:735`; `connectivity_attempt.rs:1859`).
2. PASS: Expired remote cache entries are excluded from Stage A
   (`connectivity_attempt.rs:648,1541`); the Stage A test confirms configured
   endpoints are retained after expiry.
3. TEST GAP: `expired_stage_b_resolve_snapshot_refreshes_cache`
   (`candidate_v2.rs:780`) tests `apply` directly, not the real Stage A failure
   → Stage B Resolve/Answer → cache update chain.
4. BUG: `PeerAvailableHint.runtime_epoch` is not connected to production cache
   invalidation. The helper is in `candidate_v2.rs:634`; `relay.rs:386` updates
   presence/generation but does not invalidate the old cache, so Stage A can
   still read the old epoch.
5. PASS: Wall-clock fields do not determine freshness; cache uses monotonic
   age (`candidate_v2.rs:14,522,565`).
6. PASS: Heartbeat does not move the candidate learning point; cache updates
   only through Resolve/ConnectivityAnswer paths (`control_client.rs:220,226`;
   `connectivity_attempt.rs:297,937`).
7. BUG: Client TTL synchronization has two authorities. The client reads Ready
   TTL (`control_client.rs:191,193,332`), while Relay Ready uses fixed
   `PRESENCE_TTL_S` (`relay/internal/relay/control_v2.go:87,94`) even when
   `RELAY_PRESENCE_TTL` is configured differently (`config.go:59,150`).

## Required Changes

- Wire `PeerAvailableHint.runtime_epoch` to RuntimeState/cache invalidation and
  reject old candidates until the new epoch snapshot arrives.
- Add event-chain and Stage A → Stage B integration tests, including late old
  snapshots.
- Make Relay Ready TTL use the actual configured presence lease, or constrain
  configuration to the protocol constant, and test non-default TTL plus
  reconnect synchronization.

## Risk

Helper/unit coverage can pass while the production event path remains stale.
The split between Relay presence TTL and client freshness TTL can admit expired
candidates into Stage A for the wrong window.
