//! QUIC P2P transport implementation using Quinn.

pub mod endpoint;
pub mod peer_session;

pub use endpoint::{QuicEndpointManager, QUIC_ALPN_V1};
pub use peer_session::QuicPeerSession;
