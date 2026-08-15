//! transport-network v2：连接编排（设计 §11/§34/§37/§40）。
//!
//! 本模块是连接的唯一入口，实现固定状态机：
//!
//! ```text
//! IDLE → RESOLVING → RESOLVED → COORDINATING → DIRECT_CONNECTING
//!   ├──────────────────────────────→ CONNECTED_DIRECT
//!   ↓
//! DIRECT_FAILED → RELAY_RESERVING → RELAY_CONNECTING → CONNECTED_RELAY
//! ```
//!
//! 不存在 `RECONNECTING` / `DIRECT_UPGRADING` / `PATH_REPAIRING` 长期状态（§11）。
//!
//! - [`orchestrator::ConnectionOrchestrator`]：唯一建连入口（§11/§37）。
//! - [`registry::ConnectionRegistry`]：连接重用注册表（§34：同 epoch + capability → 重用；
//!   新 epoch → 关旧建新）。
//! - [`presence::PresenceHintCache`]：UI-only 的 Presence 提示缓存（§23），绝不影响
//!   ConnectivityAttempt / CandidateSet / ConnectionSession。
//!
//! Relay 控制面（resolve / publish / signaling / reserve）经
//! [`crate::discovery::DiscoveryControlPlane`]（`RelayControlClient` v2 protobuf wire）
//! 路由；Relay 数据面在本轮仍复用 v1 Relay 数据路径（deprecated，Step 11 迁移到
//! `RelayDataClient` reservation 模型）。

pub(crate) mod orchestrator;
pub(crate) mod presence;
pub(crate) mod registry;

pub(crate) use orchestrator::ConnectionOrchestrator;

// ---------------------------------------------------------------------------
// 集中常量（设计 §39：TTL / timeout / connect window 必须集中定义，禁止散落 magic number）
// ---------------------------------------------------------------------------

use std::time::Duration;

/// Direct First 固定直连窗口（§15：`Direct connect window = 4s`）。
pub(crate) const DIRECT_CONNECT_WINDOW: Duration = Duration::from_millis(4000);

/// Resolve（服务器权威解析）的应答等待上限（§10/§33 ResolveTimeout）。
pub(crate) const RESOLVE_TIMEOUT: Duration = Duration::from_secs(8);

/// ReserveRelay 的应答等待上限（§25/§33 RelayReservationFailed）。
pub(crate) const RELAY_RESERVE_TIMEOUT: Duration = Duration::from_secs(8);

/// RelayReserveRequest 期望的数据面 reservation 生命周期（§25）。
pub(crate) const RELAY_RESERVATION_LIFETIME_S: u32 = 300;

/// 默认连接能力（§17）：ReliableStream 基线的 QUIC 能力。本轮未接 CommunicationClass
/// 分层，统一以 QUIC 作为可复用连接的默认能力。
pub(crate) const DEFAULT_CONNECTION_CAPABILITY: u8 = 0;
