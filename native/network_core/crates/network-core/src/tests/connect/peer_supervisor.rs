//! PeerSupervisor boundary tests kept outside the implementation module.

// Include ordered chunks into the same module so shared fixtures and private
// owner state retain their existing test boundary.
include!("peer_supervisor/registry_and_requirements.rs");
include!("peer_supervisor/lifecycle_and_retry.rs");
