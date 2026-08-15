//! v1 Relay 客户端与路径管理。

pub mod client;

pub use client::{PeerSummary, RelayClient, RelayError, RelayEvent};

/// Go Relay 和设备端共享的 v1 协议版本。
pub const RELAY_PROTOCOL_VERSION: u32 = 1;
