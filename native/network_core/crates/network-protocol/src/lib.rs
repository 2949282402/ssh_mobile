//! 网络协议消息、帧封装与版本信息。

use prost::Enumeration;
use prost::Message;

/// Rust 运行时、Dart 编解码器、QUIC 与文件传输 manifest 共享的版本。
/// 项目保持当前开发线协议版本；结构变化直接在当前版本中修改。
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
    IoError = 10,
    Cancelled = 11,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerConnectionState {
    Unspecified = 0,
    Connecting = 1,
    Connected = 2,
    Disconnected = 3,
    Failed = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteType {
    Unspecified = 0,
    QuicDirect = 1,
    Relay = 2,
    Lan = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RealtimeSessionState {
    Unspecified = 0,
    Negotiating = 1,
    Connected = 2,
    Restarting = 3,
    Closed = 4,
    Failed = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RealtimeSignalKind {
    Unspecified = 0,
    WebRtcOffer = 1,
    WebRtcAnswer = 2,
    IceCandidate = 3,
    IceRestart = 4,
    WebRtcClose = 5,
}

/// 应用消息进入 Delivery Manager 后采用的可靠性策略。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum DeliveryPolicyCode {
    BestEffort = 0,
    LatestState = 1,
    Acked = 2,
    AckedDeduplicated = 3,
    SessionBoundOrdered = 4,
    ResumableTransfer = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RelayConnectionState {
    Unspecified = 0,
    Connecting = 1,
    Connected = 2,
    Disconnected = 3,
    Failed = 4,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkError {
    #[prost(enumeration = "NetworkErrorCode", tag = "1")]
    pub code: i32,
    #[prost(string, tag = "2")]
    pub message: String,
    #[prost(string, tag = "3")]
    pub operation: String,
    #[prost(string, tag = "4")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub intent: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct DisconnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
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
pub struct ConfigureRuntimeCommand {
    #[prost(string, tag = "1")]
    pub device_id: String,
    #[prost(bytes = "vec", tag = "2")]
    pub identity_private_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    pub e2e_private_key: Vec<u8>,
    #[prost(string, tag = "4")]
    pub listen_address: String,
    #[prost(string, tag = "5")]
    pub receive_directory: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct UpsertPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub endpoint_address: String,
    #[prost(bytes = "vec", tag = "3")]
    pub identity_public_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub e2e_public_key: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RespondIncomingTransferCommand {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(bool, tag = "2")]
    pub accept: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct SendMessageCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub payload: Vec<u8>,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "4")]
    pub policy: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct AcknowledgeMessageCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub message_id: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConfigureRelayCommand {
    #[prost(string, tag = "1")]
    pub relay_url: String,
    #[prost(string, tag = "2")]
    pub relay_credential: String,
    #[prost(bytes = "vec", tag = "3")]
    pub relay_signing_seed: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct DisconnectRelayCommand {}

#[derive(Clone, PartialEq, Message)]
pub struct StartRealtimeSessionCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct StopRealtimeSessionCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct SendRealtimeSignalCommand {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSignalKind", tag = "3")]
    pub kind: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(bytes = "vec", tag = "5")]
    pub payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkCommand {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(uint32, tag = "2")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_command::Payload",
        tags = "10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23"
    )]
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
        #[prost(message, tag = "13")]
        ConfigureRuntime(ConfigureRuntimeCommand),
        #[prost(message, tag = "14")]
        UpsertPeer(UpsertPeerCommand),
        #[prost(message, tag = "15")]
        RespondIncomingTransfer(RespondIncomingTransferCommand),
        #[prost(message, tag = "16")]
        ConfigureRelay(ConfigureRelayCommand),
        #[prost(message, tag = "17")]
        DisconnectPeer(DisconnectPeerCommand),
        #[prost(message, tag = "18")]
        DisconnectRelay(DisconnectRelayCommand),
        #[prost(message, tag = "19")]
        SendMessage(SendMessageCommand),
        #[prost(message, tag = "20")]
        AcknowledgeMessage(AcknowledgeMessageCommand),
        #[prost(message, tag = "21")]
        StartRealtimeSession(StartRealtimeSessionCommand),
        #[prost(message, tag = "22")]
        StopRealtimeSession(StopRealtimeSessionCommand),
        #[prost(message, tag = "23")]
        SendRealtimeSignal(SendRealtimeSignalCommand),
    }
}

/// 跨 QUIC Connection 或 Relay 重传的应用消息信封。
#[derive(Clone, PartialEq, Message)]
pub struct DataMessage {
    #[prost(string, tag = "1")]
    pub session_id: String,
    #[prost(string, tag = "2")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "4")]
    pub sequence: u64,
    #[prost(uint64, tag = "5")]
    pub recovery_epoch: u64,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "6")]
    pub policy: i32,
    #[prost(bytes = "vec", tag = "7")]
    pub payload: Vec<u8>,
}

/// 不携带业务正文的应用层 Delivery ACK。
#[derive(Clone, PartialEq, Message)]
pub struct DeliveryAck {
    #[prost(string, tag = "1")]
    pub session_id: String,
    #[prost(bytes = "vec", tag = "2")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "3")]
    pub recovery_epoch: u64,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkErrorEnvelope {
    #[prost(message, optional, tag = "1")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerStateChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerConnectionState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "RouteType", tag = "3")]
    pub active_route: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
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
pub struct CommandResultEvent {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(bool, tag = "2")]
    pub accepted: bool,
    #[prost(message, optional, tag = "3")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct IncomingTransferOfferEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(string, tag = "3")]
    pub file_name: String,
    #[prost(uint64, tag = "4")]
    pub file_size: u64,
    /// Optional route metadata added without changing v1 field meanings.
    #[prost(enumeration = "RouteType", optional, tag = "5")]
    pub route_type: Option<i32>,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferCompletedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub local_path: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferFailedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RouteChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "RouteType", tag = "2")]
    pub route_type: i32,
    #[prost(string, tag = "3")]
    pub endpoint: String,
    #[prost(uint64, tag = "4")]
    pub rtt_ms: u64,
    #[prost(uint32, tag = "5")]
    pub loss_per_mille: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct RelayStateChangedEvent {
    #[prost(enumeration = "RelayConnectionState", tag = "1")]
    pub state: i32,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RealtimeStateChangedEvent {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSessionState", tag = "3")]
    pub state: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(message, optional, tag = "5")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RealtimeSignalEvent {
    #[prost(string, tag = "1")]
    pub realtime_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "RealtimeSignalKind", tag = "3")]
    pub kind: i32,
    #[prost(uint64, tag = "4")]
    pub revision: u64,
    #[prost(bytes = "vec", tag = "5")]
    pub payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct ChannelMessageEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "5")]
    pub sequence: u64,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "6")]
    pub policy: i32,
    #[prost(bytes = "vec", tag = "7")]
    pub payload: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct DeliveryAckedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub session_id: String,
    #[prost(bytes = "vec", tag = "3")]
    pub message_id: Vec<u8>,
    #[prost(uint64, tag = "4")]
    pub recovery_epoch: u64,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEvent {
    #[prost(string, tag = "1")]
    pub event_id: String,
    #[prost(int64, tag = "2")]
    pub timestamp_ms: i64,
    #[prost(uint32, tag = "3")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_event::Payload",
        tags = "10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22"
    )]
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
        #[prost(message, tag = "13")]
        CommandResult(CommandResultEvent),
        #[prost(message, tag = "14")]
        IncomingTransferOffer(IncomingTransferOfferEvent),
        #[prost(message, tag = "15")]
        TransferCompleted(TransferCompletedEvent),
        #[prost(message, tag = "16")]
        TransferFailed(TransferFailedEvent),
        #[prost(message, tag = "17")]
        RouteChanged(RouteChangedEvent),
        #[prost(message, tag = "18")]
        RelayStateChanged(RelayStateChangedEvent),
        #[prost(message, tag = "19")]
        ChannelMessage(ChannelMessageEvent),
        #[prost(message, tag = "20")]
        DeliveryAcked(DeliveryAckedEvent),
        #[prost(message, tag = "21")]
        RealtimeState(RealtimeStateChangedEvent),
        #[prost(message, tag = "22")]
        RealtimeSignal(RealtimeSignalEvent),
    }
}
