> Last updated: 2026-08-21

# Relay Security Audit

Status: BLOCKED

Scope: Relay authentication, credential expiry, Ready-session behavior, and
revocation. This was a read-only audit; no implementation files were changed.

## Findings

- PASS: Authentication binds Device proof, reservation role, and role-specific
  token (`relay/internal/relay/device_enrollment.go:201-243`;
  `reservation.go:959-1008,1014-1073,781-805`).
- PASS: Expired credentials reject new Control/Data admission
  (`credential.go:65-72`; `control_v2.go:60-69`; `reservation.go:968-978`),
  covered by `TestConnectExpiredCredentialReturnsCode12` and
  `TestNetworkV2ExpiredCredentialCannotOpenDataSocket`.
- TEST GAP: `TestRelayDataIdleCredentialExpiryKeepsReadySessionAlive`
  (`control_v2_test.go:1753-1799`) configures `CredentialTTL: time.Hour`; it
  does not prove a real credential expiry followed by Ready-session Continue.
- PASS: Revocation closes pending endpoints, active pairs, and counterparts
  (`admin_access.go:63-81`; `reservation.go:248-255,432-452`), covered by
  `TestRelayDataCloseDeviceClosesPendingActiveAndCounterpart`.
- BUG: Admission has a revoke TOCTOU window. Authentication releases the
  per-device lock before v2 Control/Data upgrade and admission
  (`device_enrollment.go:221-243`; `control_v2.go:60-119`;
  `reservation.go:962-1011`), so a concurrent revoke can miss a newly admitted
  socket.
- ARCHITECTURE RISK: Replay-protection cache failure is explicitly fail-open
  (`device_enrollment.go:230-238`; `redis_cache_test.go:417-451`), conflicting
  with the README's replay rejection model.
- ARCHITECTURE RISK: `relay/README.md:156-158` still documents `/v1/connect`,
  while `server.go:187-192` registers only v2 Control/Data and the README later
  says no v1 compatibility fallback (`:228-229`).

## Required Changes

- Serialize final Control/Data admission with revocation or recheck authoritative
  enrollment/revocation immediately before admission; add a concurrent test.
- Use a short real credential TTL to verify new admission Reject and an already
  PairReady path Continue for both roles and active relay.
- Extend revocation coverage to initiator, responder, active relay,
  counterpart, and upgrade sockets before `RelayDataConnect`.
- Make replay-protection cache failure fail closed, or explicitly re-approve a
  documented security exception.
- Correct the stale `/v1/connect` endpoint documentation.

## Risk

The TOCTOU window may allow a revoked device to establish a new Control/Data
admission. A fail-open nonce cache can accept replayed proofs during cache
failure. Relay security acceptance cannot pass.
