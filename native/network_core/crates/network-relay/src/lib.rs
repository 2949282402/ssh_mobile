//! Relay 客户端：v1 兼容客户端与 v2 控制/数据分离客户端。

pub mod client;
pub mod v2;

pub use client::{PeerSummary, RelayClient, RelayError, RelayEvent};
pub use v2::{
    ControlEvent, DataEvent, RelayControlClient, RelayDataClient, RelayDataFrame,
    RelayDataFrameKind, RelayFrame, RelayFrameKind,
};

/// Go Relay 和设备端共享的 v1 协议版本。
pub const RELAY_PROTOCOL_VERSION: u32 = 1;

/// 传输网络 v2 冻结的 Relay 协议版本。
pub const RELAY_V2_PROTOCOL_VERSION: u32 = v2::RELAY_V2_VERSION;
