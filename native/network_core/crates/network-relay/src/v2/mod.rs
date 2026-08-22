//! Relay Protocol V2 客户端。
//!
//! Transport-network v2（§24/§31/§32）把 v1 单一 `RelayClient` 拆成物理隔离的
//! 两个客户端，二者绝不共享 socket、outbound queue 或 rate budget：
//!
//! - [`RelayControlClient`]：长期 `/v2/control` 控制面。只发控制消息
//!   （Ready/Heartbeat/Discovery/Resolve/Connectivity/Reservation/Realtime/
//!   PresenceHint），按 `request_id` / `attempt_id` 做应答关联，不再使用全局
//!   `Notify`。
//! - [`RelayDataClient`]：reservation 作用域 `/v2/relay/{reservation_id}` 数据面。
//!   先等待 PairReady Ping，再转发不透明 EncryptedPayload；拥有自己的 socket、
//!   队列与速率预算。
//!
//! 消息编解码与帧边界在 [`proto`] 中自包含实现，锁定冻结的 `relay_v2.proto`。

pub mod control_client;
pub mod data_client;
pub mod proto;
mod shared;

#[cfg(test)]
mod golden_tests;

pub use control_client::{ConnectivityAttemptStart, ControlEvent, RelayControlClient};
pub use data_client::{DataEvent, RelayDataClient};
pub use proto::{
    relay_data_frame::Kind as RelayDataFrameKind, relay_frame::Kind as RelayFrameKind,
    CandidateBundle, ConnectivityAnswer, ConnectivityOffer, DiscoveryAck, DiscoveryPublish,
    DiscoverySnapshot, ErrorCode, Heartbeat, HeartbeatAck, IncomingRelayReservation,
    PeerAvailableHint, PeerPresenceHint, PeerUnavailableHint, PresenceHintSnapshot, ProtocolError,
    Ready, RealtimeSignal, RealtimeSignalKind, RelayDataAck, RelayDataClose, RelayDataConnect,
    RelayDataFrame, RelayDataPayload, RelayFrame, RelayReserveRequest, RelayReserveResponse,
    ResolvePeerRequest, ResolvePeerResponse, ResolveStatus, RuntimeEpoch, TransportCapability,
};
pub use shared::RelayError;

pub use proto::{
    MAX_ATTEMPT_ID_BYTES, MAX_DEVICE_ID_BYTES, MAX_DISCOVERY_CANDIDATES,
    MAX_DISCOVERY_CANDIDATE_BYTES, MAX_DISCOVERY_CAPABILITIES, MAX_REALTIME_ID_BYTES,
    MAX_REALTIME_SIGNAL_PAYLOAD_BYTES, MAX_RELAY_DATA_FRAME_BYTES, MAX_RELAY_FRAME_BYTES,
    PRESENCE_TTL_S, RELAY_V2_VERSION, RESERVATION_ID_HEX_CHARS, RESERVATION_TOKEN_BYTES,
    RESOLVE_RETRY_HINT_NOT_READY_MS, RESOLVE_RETRY_HINT_UNKNOWN_MS,
};
