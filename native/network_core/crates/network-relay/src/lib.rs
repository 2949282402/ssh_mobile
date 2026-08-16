//! Relay 客户端：v2 控制/数据分离客户端（transport-network v2 §24/§31/§32）。
//!
//! v1 单一 `RelayClient` 已在 Step 11 删除：控制面（`/v2/control`）与数据面
//! （`/v2/relay/{reservation_id}`）物理隔离，共享的认证/URL/错误助手归入
//! `v2::shared`。

pub mod v2;

pub use v2::{
    ControlEvent, DataEvent, RelayControlClient, RelayDataClient, RelayDataFrame,
    RelayDataFrameKind, RelayError, RelayFrame, RelayFrameKind,
};

/// 传输网络 v2 冻结的 Relay 协议版本。
pub const RELAY_V2_PROTOCOL_VERSION: u32 = v2::RELAY_V2_VERSION;
