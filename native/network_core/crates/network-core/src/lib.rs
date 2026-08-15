//! v1 原生网络运行时外观。
//!
//! 按职责拆分实现，使生命周期、命令分发、对端连接、传输、Relay 处理和
//! 线协议事件可以独立审查。

mod channel;
mod commands;
pub mod connection;
pub(crate) mod crypto;
mod crypto_handshake;
pub mod delivery;
mod discovery;
mod errors;
mod events;
mod generic_auth;
mod peer;
mod realtime;
mod relay;
mod runtime;
mod session;
mod task_supervisor;
mod transfer;

pub use errors::NetworkError;
pub use runtime::NetworkRuntime;

#[cfg(test)]
mod tests;
