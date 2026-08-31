//! ConnectivityAttempt boundary tests kept outside the implementation module.

// The source is included in ordered, focused chunks so every hand-written test
// unit remains reviewable without changing the original shared test namespace.
include!("connectivity_attempt/state_machine_and_guards.rs");
include!("connectivity_attempt/direct_reuse_and_retries.rs");
include!("connectivity_attempt/coordination_and_direct_attach.rs");
include!("connectivity_attempt/candidate_and_relay_gates.rs");
include!("connectivity_attempt/resolve_and_answer_boundaries.rs");
include!("connectivity_attempt/relay_fallback_cleanup.rs");
include!("connectivity_attempt/authoritative_resolve_and_reuse.rs");
include!("connectivity_attempt/connectivity_test_doubles.rs");
include!("connectivity_attempt/cleanup.rs");
