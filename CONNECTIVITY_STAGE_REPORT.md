> Last updated: 2026-08-21

# Connectivity Stage Audit

Status: BLOCKED

Scope: connectivity attempts, candidate exchange, and Relay selection. This
was a read-only audit; no implementation files were changed.

## Findings

- TEST GAP: Stage A is Direct-only before Resolve
  (`connect/connectivity_attempt.rs:266-280,648-688`), but
  `stage_a_uses_fresh_cache_and_configured_direct_candidates_only`
  (`:1859-1922`) does not assert zero Resolve, Offer, or Reservation calls.
- TEST GAP: Stage B flow exists (`:283-305,489-533`), while the Resolve gate,
  answer merge, and lower-level late-candidate tests are isolated rather than
  an end-to-end Resolve → Offer → fixed four-second Direct window test.
- ARCHITECTURE RISK: Stage B performs an outer Resolve and
  `start_connectivity_attempt` performs another Resolve before Offer
  (`connect/connectivity_attempt.rs:287-288`; `network-relay/src/v2/control_client.rs:454-498`),
  producing Resolve → Resolve → Offer without call-count coverage.
- BUG: `try_stage_a_direct` returns success when any Direct path exists without
  checking requested capability (`connect/connectivity_attempt.rs:644-645`).
- TEST GAP: Stage C predicate coverage exists in
  `relay_fallback_gate_requires_ready_relay_policy_and_budget`
  (`connectivity_attempt.rs:1975-2034`), but no full flow proves Relay
  reservation only follows Direct failure, Ready state, eligibility, Required
  E2EE, and available resources.

## Required Changes

- Add deterministic fake-control-plane tests equivalent to
  `stage_a_direct_only_test`, `stage_b_timeout_test`, and
  `stage_b_candidate_test`, including forbidden-call counters.
- Assert Stage C order and every negative gate, including unavailable Relay
  resources.
- Unify or formally account for the duplicate Stage B Resolve and test one
  authoritative sequence.
- Make Stage A reuse capability-aware and add weaker-route/stronger-request
  regression coverage.

## Risk

Focused tests pass, but they do not prove forbidden Stage A calls, exact Stage B
ordering/timeout, or full Stage C eligibility. A weaker route can be reported
as satisfying a stronger request.
