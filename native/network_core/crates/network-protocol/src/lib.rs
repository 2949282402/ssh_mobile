//! Network Protocol V2 消息、帧封装与版本信息。

use prost::Enumeration;
use prost::Message;

/// Rust runtime、Dart codec and QUIC share the Network SDK/Data V2 version.
/// Relay Bootstrap V1 has an independent version domain and is not changed by
/// this constant.
pub const NETWORK_PROTOCOL_VERSION: u32 = 2;

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
    CredentialExpired = 12,
    IdentityConflict = 13,
    Configuration = 14,
    SecurityPolicyMismatch = 15,
    RelayRequiresE2ee = 16,
    PeerNotReady = 17,
    ResourceLimit = 18,
    Lifecycle = 19,
    ProtocolMismatch = 20,
    StaleOperation = 21,
    InvalidState = 22,
    PathLost = 23,
    ResumeRejected = 24,
    StreamClosed = 25,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RetryDisposition {
    Unspecified = 0,
    NoRetry = 1,
    RetryWithBackoff = 2,
    RetryAfter = 3,
    RefreshCredentialThenRetry = 4,
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

/// Stable, business-level peer lifecycle. Transport/session states are not
/// part of this public truth.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerState {
    Offline = 0,
    Connecting = 1,
    Online = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum E2eePolicy {
    Required = 0,
    Disabled = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum CommandResultState {
    Succeeded = 0,
    Failed = 1,
    Cancelled = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum NetworkEventLane {
    Control = 0,
    Data = 1,
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
pub enum RouteTopology {
    Unspecified = 0,
    Direct = 1,
    Relay = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteTransport {
    Unspecified = 0,
    Quic = 1,
    Tcp = 2,
    Udp = 3,
    WebSocket = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum RouteAttemptPhase {
    Unspecified = 0,
    DirectFailed = 1,
    RelayFallbackStarted = 2,
    RelayConnected = 3,
    RelayFailed = 4,
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
    /// 服务端建议的重试策略；默认 Unspecified 表示未指定。
    #[prost(enumeration = "RetryDisposition", tag = "5")]
    pub retry_disposition: i32,
    /// 服务端建议的 `RetryAfter` 秒数；0 表示未指定。
    #[prost(uint32, tag = "6")]
    pub retry_after_seconds: u32,
}

/// 业务请求连接的通信类别（设计 §17）。连接层将其映射为 transport capability
/// 与 connection shape；默认（Unspecified）按 ReliableMessage 处理。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum CommunicationClass {
    Unspecified = 0,
    ReliableStream = 1,
    ReliableMessage = 2,
    BulkTransfer = 3,
    UnreliableDatagram = 4,
    RealtimeMedia = 5,
}

#[derive(Clone, PartialEq, Message)]
pub struct ConnectPeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub intent: u32,
    /// 本次连接请求的 CommunicationClass；Unspecified(0) 视为默认 ReliableMessage。
    #[prost(enumeration = "CommunicationClass", tag = "3")]
    pub communication_class: i32,
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

/// Stable peer configuration owned by the Network V2 peer supervisor.
#[derive(Clone, PartialEq, Message)]
pub struct PeerConfig {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub endpoint_address: String,
    #[prost(bytes = "vec", tag = "3")]
    pub identity_public_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub e2e_public_key: Vec<u8>,
    #[prost(enumeration = "E2eePolicy", tag = "5")]
    pub e2ee_policy: i32,
    #[prost(bool, tag = "6")]
    pub allow_direct: bool,
    #[prost(bool, tag = "7")]
    pub allow_relay: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct UpsertPeerV2Command {
    #[prost(message, optional, tag = "1")]
    pub config: Option<PeerConfig>,
}

#[derive(Clone, PartialEq, Message)]
pub struct RemovePeerCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
}

/// V2 message command whose identity is explicitly `(peer_id, message_id)`.
#[derive(Clone, PartialEq, Message)]
pub struct SendMessageV2Command {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub message_id: String,
    #[prost(string, tag = "3")]
    pub channel_id: String,
    #[prost(bytes = "vec", tag = "4")]
    pub payload: Vec<u8>,
    #[prost(enumeration = "DeliveryPolicyCode", tag = "5")]
    pub policy: i32,
    #[prost(enumeration = "E2eePolicy", tag = "6")]
    pub e2ee_policy: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub transfer_id: String,
    #[prost(string, tag = "3")]
    pub file_path: String,
    #[prost(uint64, tag = "4")]
    pub confirmed_offset: u64,
    #[prost(bool, tag = "5")]
    pub resume: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerDiagnosticsCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEnvironmentChangedCommand {
    #[prost(uint64, tag = "1")]
    pub generation: u64,
    #[prost(bool, tag = "2")]
    pub has_connectivity: bool,
    #[prost(bool, tag = "3")]
    pub is_foreground: bool,
    #[prost(bool, tag = "4")]
    pub is_metered: bool,
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

/// 逻辑 ReliableStream 的稳定业务身份。
///
/// `stream_id` 只在同一个 opener 的命名空间内唯一；opener 必须贯穿
/// Wire、native、FFI 与 App，不能再从本地/远端流的存在性推断。
#[derive(Clone, PartialEq, Message)]
pub struct StreamHandle {
    #[prost(string, tag = "1")]
    pub opener_device_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
}

/// 打开一条到对端的 ReliableStream 字节流（设计 §17/§21）。`handle` 由调用方
/// 分配，native 侧校验 `stream_id ≤ u16::MAX`，`service` 是对端网关的服务提示
/// （如 "ssh"）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamOpenCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(string, tag = "3")]
    pub service: String,
}

/// 向一条已打开的 ReliableStream 追加字节（SSH/SFTP 协议数据作为不透明负载）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamDataCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// 关闭一条 ReliableStream。对端会观察到 StreamClosed。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamCloseCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkCommand {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(uint32, tag = "2")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_command::Payload",
        tags = "10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33"
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
        #[prost(message, tag = "25")]
        SshStreamOpen(SshStreamOpenCommand),
        #[prost(message, tag = "26")]
        SshStreamData(SshStreamDataCommand),
        #[prost(message, tag = "27")]
        SshStreamClose(SshStreamCloseCommand),
        #[prost(message, tag = "28")]
        UpsertPeerV2(UpsertPeerV2Command),
        #[prost(message, tag = "29")]
        RemovePeer(RemovePeerCommand),
        #[prost(message, tag = "30")]
        SendMessageV2(SendMessageV2Command),
        #[prost(message, tag = "31")]
        Transfer(TransferCommand),
        #[prost(message, tag = "32")]
        PeerDiagnostics(PeerDiagnosticsCommand),
        #[prost(message, tag = "33")]
        NetworkEnvironmentChanged(NetworkEnvironmentChangedCommand),
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
    /// Route metadata at the time of the Peer event; this is observational
    /// and never a global connectivity authority.
    pub route_type: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
    #[prost(enumeration = "RouteTopology", tag = "5")]
    pub route_topology: i32,
    #[prost(enumeration = "RouteTransport", tag = "6")]
    pub route_transport: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferProgressEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(uint64, tag = "2")]
    pub bytes_transferred: u64,
    #[prost(uint64, tag = "3")]
    pub total_bytes: u64,
    /// Peer scope is mandatory for V2 business consumers. Empty is retained
    /// only for legacy relay progress producers during the cutover.
    #[prost(string, tag = "4")]
    pub peer_id: String,
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
pub struct CommandResult {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(string, tag = "2")]
    pub peer_id: String,
    #[prost(enumeration = "CommandResultState", tag = "3")]
    pub state: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerLifecycleEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "E2eePolicy", tag = "3")]
    pub e2ee_policy: i32,
    #[prost(message, optional, tag = "4")]
    pub error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerDiagnostics {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(enumeration = "PeerState", tag = "2")]
    pub state: i32,
    #[prost(enumeration = "E2eePolicy", tag = "3")]
    pub e2ee_policy: i32,
    #[prost(uint32, tag = "4")]
    pub ready_path_count: u32,
    #[prost(uint32, tag = "5")]
    pub queued_command_count: u32,
    #[prost(uint32, tag = "6")]
    pub active_stream_count: u32,
    #[prost(uint32, tag = "7")]
    pub active_transfer_count: u32,
    #[prost(message, optional, tag = "8")]
    pub last_error: Option<NetworkError>,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkEnvironmentChangedEvent {
    #[prost(uint64, tag = "1")]
    pub generation: u64,
    #[prost(bool, tag = "2")]
    pub has_connectivity: bool,
    #[prost(bool, tag = "3")]
    pub is_foreground: bool,
    #[prost(bool, tag = "4")]
    pub is_metered: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct PeerTransferProgressEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub transfer_id: String,
    #[prost(uint64, tag = "3")]
    pub confirmed_offset: u64,
    #[prost(uint64, tag = "4")]
    pub total_bytes: u64,
    #[prost(bool, tag = "5")]
    pub paused: bool,
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
    /// Optional route metadata carried by the Network Protocol V2 event.
    #[prost(enumeration = "RouteType", optional, tag = "5")]
    pub route_type: Option<i32>,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferCompletedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(string, tag = "2")]
    pub local_path: String,
    #[prost(string, tag = "3")]
    pub peer_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct TransferFailedEvent {
    #[prost(string, tag = "1")]
    pub transfer_id: String,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
    #[prost(string, tag = "3")]
    pub peer_id: String,
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
    #[prost(enumeration = "RouteTopology", tag = "6")]
    pub topology: i32,
    #[prost(enumeration = "RouteTransport", tag = "7")]
    pub transport: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct RouteAttemptChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(string, tag = "2")]
    pub attempt_id: String,
    #[prost(enumeration = "RouteAttemptPhase", tag = "3")]
    pub phase: i32,
    #[prost(enumeration = "RouteType", tag = "4")]
    pub route_type: i32,
    #[prost(message, optional, tag = "5")]
    pub error: Option<NetworkError>,
    #[prost(string, tag = "6")]
    pub command_id: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct RelayStateChangedEvent {
    #[prost(enumeration = "RelayConnectionState", tag = "1")]
    pub state: i32,
    #[prost(message, optional, tag = "2")]
    pub error: Option<NetworkError>,
}

/// Relay Presence 控制面推送给客户端的对端在线状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Enumeration)]
#[repr(i32)]
pub enum PeerPresenceState {
    Unspecified = 0,
    Online = 1,
    Updated = 2,
    Offline = 3,
}

/// 单个对端的 Presence 变化。
#[derive(Clone, PartialEq, Message)]
pub struct PeerPresenceChangedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint64, tag = "2")]
    pub generation: u64,
    #[prost(enumeration = "PeerPresenceState", tag = "3")]
    pub state: i32,
}

/// Relay 认证连接后推送的完整在线设备快照。
#[derive(Clone, PartialEq, Message)]
pub struct PeerPresenceSnapshotEvent {
    #[prost(message, repeated, tag = "1")]
    pub peers: Vec<PeerPresenceChangedEvent>,
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

/// Realtime Session 稳定后发布的完整状态快照；携带当前 revision 与最近错误。
#[derive(Clone, PartialEq, Message)]
pub struct RealtimeSnapshotEvent {
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

/// ReliableStream 收到对端字节后发布的事件（设计 §17）。字节是不透明负载。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamDataReceivedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// ReliableStream 关闭事件（本端 close_stream / 对端 StreamClose / transport 丢失）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamClosedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(message, optional, tag = "2")]
    pub handle: Option<StreamHandle>,
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
        tags = "10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33"
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
        #[prost(message, tag = "23")]
        RealtimeSnapshot(RealtimeSnapshotEvent),
        #[prost(message, tag = "24")]
        PeerPresenceChanged(PeerPresenceChangedEvent),
        #[prost(message, tag = "25")]
        PeerPresenceSnapshot(PeerPresenceSnapshotEvent),
        #[prost(message, tag = "26")]
        SshStreamDataReceived(SshStreamDataReceivedEvent),
        #[prost(message, tag = "27")]
        SshStreamClosed(SshStreamClosedEvent),
        #[prost(message, tag = "28")]
        PeerLifecycle(PeerLifecycleEvent),
        #[prost(message, tag = "29")]
        CommandResultV2(CommandResult),
        #[prost(message, tag = "30")]
        PeerDiagnostics(PeerDiagnostics),
        #[prost(message, tag = "31")]
        NetworkEnvironmentChanged(NetworkEnvironmentChangedEvent),
        #[prost(message, tag = "32")]
        PeerTransferProgress(PeerTransferProgressEvent),
        #[prost(message, tag = "33")]
        RouteAttemptChanged(RouteAttemptChangedEvent),
    }
}

#[cfg(test)]
#[path = "tests/mod.rs"]
mod tests;
