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
    CredentialExpired = 12,
    IdentityConflict = 13,
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
    /// Application payload protection. The zero protobuf value is E2EE so a
    /// caller that does not know about this field remains secure by default.
    #[prost(enumeration = "CryptoModeCode", tag = "5")]
    pub crypto_mode: i32,
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

/// 打开一条到对端的 ReliableStream 字节流（设计 §17/§21）。`stream_id` 由调用方
/// 分配（u32，native 侧校验 ≤ u16::MAX），`service` 是对端网关的服务提示（如 "ssh"）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamOpenCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(string, tag = "3")]
    pub service: String,
}

/// 向一条已打开的 ReliableStream 追加字节（SSH/SFTP 协议数据作为不透明负载）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamDataCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// 关闭一条 ReliableStream。对端会观察到 StreamClosed。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamCloseCommand {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NetworkCommand {
    #[prost(string, tag = "1")]
    pub command_id: String,
    #[prost(uint32, tag = "2")]
    pub protocol_version: u32,
    #[prost(
        oneof = "network_command::Payload",
        tags = "10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27"
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
    /// Application payload protection used for `payload`. The zero protobuf
    /// value is E2EE; the clear mode must be explicitly requested.
    #[prost(enumeration = "CryptoModeCode", tag = "8")]
    pub crypto_mode: i32,
}

/// Application payload protection mode. E2EE is intentionally value zero so
/// older callers that omit the field do not silently downgrade security.
#[derive(Clone, Copy, Debug, PartialEq, Eq, ::prost::Enumeration)]
#[repr(i32)]
pub enum CryptoModeCode {
    E2ee = 0,
    None = 1,
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
    #[prost(enumeration = "RouteTopology", tag = "6")]
    pub topology: i32,
    #[prost(enumeration = "RouteTransport", tag = "7")]
    pub transport: i32,
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
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(bytes = "vec", tag = "3")]
    pub data: Vec<u8>,
}

/// ReliableStream 关闭事件（本端 close_stream / 对端 StreamClose / transport 丢失）。
#[derive(Clone, PartialEq, Message)]
pub struct SshStreamClosedEvent {
    #[prost(string, tag = "1")]
    pub peer_id: String,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
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
        tags = "10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27"
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_error_code_additions_preserve_existing_values() {
        assert_eq!(NetworkErrorCode::IoError as i32, 10);
        assert_eq!(NetworkErrorCode::Cancelled as i32, 11);
        assert_eq!(NetworkErrorCode::CredentialExpired as i32, 12);
        assert_eq!(NetworkErrorCode::IdentityConflict as i32, 13);
    }

    #[test]
    fn retry_disposition_round_trips_as_wire_values() {
        assert_eq!(RetryDisposition::Unspecified as i32, 0);
        assert_eq!(RetryDisposition::NoRetry as i32, 1);
        assert_eq!(RetryDisposition::RetryWithBackoff as i32, 2);
        assert_eq!(RetryDisposition::RetryAfter as i32, 3);
        assert_eq!(RetryDisposition::RefreshCredentialThenRetry as i32, 4);
        assert_eq!(
            RetryDisposition::try_from(4),
            Ok(RetryDisposition::RefreshCredentialThenRetry)
        );
        assert!(RetryDisposition::try_from(99).is_err());
    }

    #[test]
    fn network_error_new_retry_fields_default_to_zero() {
        let error = NetworkError {
            code: NetworkErrorCode::CredentialExpired as i32,
            message: "credential expired".into(),
            operation: "connect".into(),
            peer_id: String::new(),
            retry_disposition: RetryDisposition::Unspecified as i32,
            retry_after_seconds: 0,
        };
        let encoded = error.encode_to_vec();
        let decoded = NetworkError::decode(encoded.as_slice()).expect("decode");
        assert_eq!(decoded.code, NetworkErrorCode::CredentialExpired as i32);
        assert_eq!(decoded.retry_disposition, 0);
        assert_eq!(decoded.retry_after_seconds, 0);
    }

    #[test]
    fn network_error_retry_fields_round_trip() {
        let error = NetworkError {
            code: NetworkErrorCode::CredentialExpired as i32,
            message: "credential expired".into(),
            operation: "connect".into(),
            peer_id: "peer-a".into(),
            retry_disposition: RetryDisposition::RefreshCredentialThenRetry as i32,
            retry_after_seconds: 30,
        };
        let encoded = error.encode_to_vec();
        let decoded = NetworkError::decode(encoded.as_slice()).expect("decode");
        assert_eq!(
            decoded.retry_disposition,
            RetryDisposition::RefreshCredentialThenRetry as i32
        );
        assert_eq!(decoded.retry_after_seconds, 30);
        assert_eq!(decoded.peer_id, "peer-a");
    }

    #[test]
    fn realtime_snapshot_event_round_trips_state_and_revision() {
        let event = RealtimeSnapshotEvent {
            realtime_id: "00112233445566778899aabbccddeeff".into(),
            peer_id: "peer-a".into(),
            state: RealtimeSessionState::Connected as i32,
            revision: 7,
            error: Some(NetworkError {
                code: NetworkErrorCode::IdentityConflict as i32,
                message: "identity conflict".into(),
                operation: "connect".into(),
                peer_id: "peer-a".into(),
                retry_disposition: RetryDisposition::NoRetry as i32,
                retry_after_seconds: 0,
            }),
        };
        let encoded = event.encode_to_vec();
        let decoded = RealtimeSnapshotEvent::decode(encoded.as_slice()).expect("decode");
        assert_eq!(decoded.realtime_id, "00112233445566778899aabbccddeeff");
        assert_eq!(decoded.peer_id, "peer-a");
        assert_eq!(decoded.state, RealtimeSessionState::Connected as i32);
        assert_eq!(decoded.revision, 7);
        let error = decoded.error.expect("snapshot error");
        assert_eq!(error.code, NetworkErrorCode::IdentityConflict as i32);
        assert_eq!(error.retry_disposition, RetryDisposition::NoRetry as i32);
    }

    #[test]
    fn peer_presence_snapshot_round_trips_peers_and_state() {
        let event = NetworkEvent {
            event_id: "presence-event".into(),
            timestamp_ms: 123,
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_event::Payload::PeerPresenceSnapshot(
                PeerPresenceSnapshotEvent {
                    peers: vec![
                        PeerPresenceChangedEvent {
                            peer_id: "peer-a".into(),
                            generation: 3,
                            state: PeerPresenceState::Online as i32,
                        },
                        PeerPresenceChangedEvent {
                            peer_id: "peer-b".into(),
                            generation: 0,
                            state: PeerPresenceState::Offline as i32,
                        },
                    ],
                },
            )),
        };
        let encoded = event.encode_to_vec();
        let decoded = NetworkEvent::decode(encoded.as_slice()).expect("decode");
        match decoded.payload {
            Some(network_event::Payload::PeerPresenceSnapshot(snapshot)) => {
                assert_eq!(snapshot.peers.len(), 2);
                assert_eq!(snapshot.peers[0].peer_id, "peer-a");
                assert_eq!(snapshot.peers[0].generation, 3);
                assert_eq!(snapshot.peers[0].state, PeerPresenceState::Online as i32);
                assert_eq!(snapshot.peers[1].state, PeerPresenceState::Offline as i32);
            }
            other => panic!("unexpected event payload: {other:?}"),
        }
    }

    #[test]
    fn communication_class_values_are_stable_wire_identifiers() {
        // §17：五种固定 CommunicationClass，值不允许漂移。
        assert_eq!(CommunicationClass::Unspecified as i32, 0);
        assert_eq!(CommunicationClass::ReliableStream as i32, 1);
        assert_eq!(CommunicationClass::ReliableMessage as i32, 2);
        assert_eq!(CommunicationClass::BulkTransfer as i32, 3);
        assert_eq!(CommunicationClass::UnreliableDatagram as i32, 4);
        assert_eq!(CommunicationClass::RealtimeMedia as i32, 5);
        assert_eq!(
            CommunicationClass::try_from(5),
            Ok(CommunicationClass::RealtimeMedia)
        );
        assert!(CommunicationClass::try_from(99).is_err());
    }

    #[test]
    fn connect_peer_command_defaults_communication_class_to_unspecified() {
        let command = ConnectPeerCommand {
            peer_id: "peer-a".into(),
            intent: 0,
            communication_class: 0,
        };
        let encoded = command.encode_to_vec();
        let decoded = ConnectPeerCommand::decode(encoded.as_slice()).expect("decode");
        assert_eq!(
            decoded.communication_class,
            CommunicationClass::Unspecified as i32
        );
    }

    #[test]
    fn ssh_stream_commands_and_events_round_trip_through_the_wire() {
        let open = NetworkCommand {
            command_id: "ssh-open".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SshStreamOpen(
                SshStreamOpenCommand {
                    peer_id: "peer-a".into(),
                    stream_id: 7,
                    service: "ssh".into(),
                },
            )),
        };
        let decoded = NetworkCommand::decode(open.encode_to_vec().as_slice()).expect("decode open");
        match decoded.payload {
            Some(network_command::Payload::SshStreamOpen(open)) => {
                assert_eq!(open.peer_id, "peer-a");
                assert_eq!(open.stream_id, 7);
                assert_eq!(open.service, "ssh");
            }
            other => panic!("unexpected command payload: {other:?}"),
        }

        let data = NetworkCommand {
            command_id: "ssh-data".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SshStreamData(
                SshStreamDataCommand {
                    peer_id: "peer-a".into(),
                    stream_id: 7,
                    data: b"SSH-bytes".to_vec(),
                },
            )),
        };
        let decoded = NetworkCommand::decode(data.encode_to_vec().as_slice()).expect("decode data");
        match decoded.payload {
            Some(network_command::Payload::SshStreamData(data)) => {
                assert_eq!(data.stream_id, 7);
                assert_eq!(data.data, b"SSH-bytes");
            }
            other => panic!("unexpected command payload: {other:?}"),
        }

        let close = NetworkCommand {
            command_id: "ssh-close".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::SshStreamClose(
                SshStreamCloseCommand {
                    peer_id: "peer-a".into(),
                    stream_id: 7,
                },
            )),
        };
        let decoded =
            NetworkCommand::decode(close.encode_to_vec().as_slice()).expect("decode close");
        assert!(matches!(
            decoded.payload,
            Some(network_command::Payload::SshStreamClose(close)) if close.stream_id == 7
        ));

        let received = NetworkEvent {
            event_id: "ssh-recv".into(),
            timestamp_ms: 123,
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_event::Payload::SshStreamDataReceived(
                SshStreamDataReceivedEvent {
                    peer_id: "peer-a".into(),
                    stream_id: 7,
                    data: b"reply".to_vec(),
                },
            )),
        };
        let decoded =
            NetworkEvent::decode(received.encode_to_vec().as_slice()).expect("decode event");
        match decoded.payload {
            Some(network_event::Payload::SshStreamDataReceived(recv)) => {
                assert_eq!(recv.stream_id, 7);
                assert_eq!(recv.data, b"reply");
            }
            other => panic!("unexpected event payload: {other:?}"),
        }

        let closed = NetworkEvent {
            event_id: "ssh-closed".into(),
            timestamp_ms: 124,
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_event::Payload::SshStreamClosed(
                SshStreamClosedEvent {
                    peer_id: "peer-a".into(),
                    stream_id: 7,
                },
            )),
        };
        let decoded =
            NetworkEvent::decode(closed.encode_to_vec().as_slice()).expect("decode closed event");
        assert!(matches!(
            decoded.payload,
            Some(network_event::Payload::SshStreamClosed(closed)) if closed.stream_id == 7
        ));
    }
}
