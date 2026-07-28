//! Relay client and fallback path management.

pub mod client;

pub use client::{RelayClient, RelayEvent};
pub const RELAY_PROTOCOL_VERSION: u32 = 1;
