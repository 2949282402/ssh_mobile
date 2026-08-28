//! Network Protocol V2 messages, frames, and version information.
//!
//! The wire contract is organized by stable ownership modules while these
//! re-exports keep the historical crate-root API intact.

pub const NETWORK_PROTOCOL_VERSION: u32 = 2;

mod commands;
mod enums;
mod events;
mod messages;

pub use commands::*;
pub use enums::*;
pub use events::*;
pub use messages::*;

// Prost's generated-style oneof modules are part of the public wire API.
pub use commands::network_command;
pub use events::network_event;

#[cfg(test)]
#[path = "tests/mod.rs"]
mod tests;
