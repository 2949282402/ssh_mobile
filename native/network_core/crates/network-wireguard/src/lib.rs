//! WireGuard virtual network controller and platform abstractions.

pub mod backend;

pub use backend::{PeerConfig, TunnelConfig, TunnelHandle, WireGuardBackend, WireGuardError};
