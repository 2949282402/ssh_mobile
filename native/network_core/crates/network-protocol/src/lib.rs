//! Network protocol messages, framing, and versioning.

use prost::Enumeration;
use prost::Message;

pub const NETWORK_PROTOCOL_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum NetworkErrorCode {
    Unspecified = 0,
    InvalidArgument = 1,
    AuthenticationFailed = 2,
    NoRoute = 3,
    Timeout = 4,
    PeerOffline = 5,
    QuicError = 6,
    NatError = 7,
    RelayError = 8,
    WireguardError = 9,
    IoError = 10,
    Cancelled = 11,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkError {
    #[prost(enumeration = "NetworkErrorCode", tag = "1")]
    pub code: i32,
    #[prost(string, tag = "2")]
    pub message: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub intent: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct SendFileCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub file_path: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct CancelTransferCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkCommand {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(oneof = "network_command::Payload", tags = "10, 11, 12")]
    pub payload: Option<network_command::Payload>,
}

pub mod network_command {
    use super::*;

    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        ConnectPeer(ConnectPeerCommand),
        #[prost(message, tag = "11")]
        SendFile(SendFileCommand),
        #[prost(message, tag = "12")]
        CancelTransfer(CancelTransferCommand),
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerStateChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub state: String,
    #[prost(string, tag = "3")]
    pub active_route: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferProgressEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(uint64, tag = "2")]
    pub bytes_transferred: u64,
    #[prost(uint64, tag = "3")]
    pub total_bytes: u64,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEvent {
    #[prost(string, tag = "1")]
    pub event_id: String,
    #[prost(int64, tag = "2")]
    pub timestamp_ms: i64,
    #[prost(oneof = "network_event::Payload", tags = "10, 11, 12")]
    pub payload: Option<network_event::Payload>,
}

pub mod network_event {
    use super::*;

    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        PeerState(PeerStateChangedEvent),
        #[prost(message, tag = "11")]
        TransferProgress(TransferProgressEvent),
        #[prost(message, tag = "12")]
        Error(NetworkError),
    }
}
