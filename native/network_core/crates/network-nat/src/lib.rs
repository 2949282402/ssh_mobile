//! NAT traversal, STUN client, candidate gathering, and path selection.

pub mod attempt;
pub mod candidate;
pub mod discovery;
pub mod exchange;
pub mod path_manager;
pub mod stun;

pub use attempt::{ConnectivityAttempt, ConnectivityAttemptState};
pub use candidate::{Candidate, CandidateAdvertisement, CandidateKind};
pub use discovery::discover_candidates;
pub use exchange::{
    CandidateExchangeState, CandidateSignal, CandidateSignalKind, RuntimeEpoch,
    CANDIDATE_SIGNAL_VERSION, DEFAULT_CONNECT_WINDOW_MS, MAX_ATTEMPT_ID_BYTES,
    MAX_CANDIDATES_PER_SIGNAL, MAX_CONNECT_WINDOW_MS, MIN_CONNECT_WINDOW_MS,
};
pub use path_manager::{ConnectionPathMetrics, HistoricalPathMetrics, PathManager};
pub use stun::query_stun;
