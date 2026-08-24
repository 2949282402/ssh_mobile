//! QUIC P2P transport implementation using Quinn.

pub mod channel;
pub mod endpoint;
pub mod file_stream;
pub mod peer_session;

pub use channel::{
    read_channel_frame, send_channel_frame, write_channel_frame, ChannelFrameKind,
    MAX_CHANNEL_FRAME_BYTES,
};
pub use endpoint::{QuicEndpointManager, QUIC_ALPN_V2, QUIC_CANDIDATE_TRANSPORTS};
pub use file_stream::{
    read_file_completion, read_file_decision, read_file_offer, write_file_completion,
    write_file_decision, write_file_offer,
};
pub use peer_session::QuicPeerSession;
