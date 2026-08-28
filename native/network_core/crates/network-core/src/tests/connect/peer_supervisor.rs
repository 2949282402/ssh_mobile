//! PeerSupervisor boundary tests kept outside the implementation module.

// Include ordered chunks into the same module so shared fixtures and private
// owner state retain their existing test boundary.
include!("peer_supervisor/part_01.rs");
include!("peer_supervisor/part_02.rs");
