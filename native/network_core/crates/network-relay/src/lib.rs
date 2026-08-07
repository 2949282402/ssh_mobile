//! v1 Relay 客户端与路径管理。

pub mod client;

pub use client::{RelayClient, RelayEvent};
pub const RELAY_PROTOCOL_VERSION: u32 = 1;
