//! Native-only WebRTC peer connection and bounded realtime media QoS.
//!
//! WebRTC remains a separate realtime subsystem. It owns SDP/ICE/DataChannel and
//! RTP media negotiation while generic TCP/UDP/WebSocket transports stay in the
//! `network-transport` crate. The FFI/client protocol is intentionally unchanged.

mod peer;
mod qos;
mod signaling;

pub use peer::{
    DataChannelReliability, IceServerConfig, MediaDirection, WebRtcConfig, WebRtcError, WebRtcPeer,
    MAX_DATA_CHANNEL_PAYLOAD_BYTES,
};
pub use qos::{
    EnqueueResult, MediaFrame, MediaKind, MediaQos, MediaQosConfig, MediaQosPolicy, QosError,
    QosStats,
};
pub use signaling::{
    DescriptionType, IceCandidate, SessionDescription, SignalingError, SignalingState,
    SignalingStateMachine, MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES,
};
