//! NAT traversal, STUN client, candidate gathering, and path selection.

pub mod candidate;
pub mod discovery;
pub mod exchange;
pub mod hole_punch;
pub mod path_manager;
pub mod stun;

pub use candidate::{Candidate, CandidateAdvertisement, CandidateKind};
pub use discovery::discover_candidates;
pub use exchange::{
    CandidateExchangeState, CandidateSignal, CandidateSignalKind, CANDIDATE_SIGNAL_VERSION,
    MAX_CANDIDATES_PER_SIGNAL,
};
pub use hole_punch::{probe_candidate, respond_to_probe};
pub use path_manager::PathManager;
pub use stun::query_stun;
