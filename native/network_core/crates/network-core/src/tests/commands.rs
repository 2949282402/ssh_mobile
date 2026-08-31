use super::*;

use sha2::Digest;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::oneshot;

use crate::stream::{ReliableStreamManager, StreamConsumer, StreamOpener};

fn manifest(transfer_id: &str) -> network_transfer::FileManifest {
    network_transfer::FileManifest {
        transfer_id: transfer_id.into(),
        file_name: "payload.bin".into(),
        file_size: 4,
        modified_at: 1,
        content_hash: "a".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

include!("commands/command_ledger.rs");
include!("commands/connect_commands.rs");
include!("commands/environment_commands.rs");
include!("commands/peer_lifecycle_and_diagnostics.rs");
include!("commands/command_scope_and_validation.rs");
include!("commands/relay_commands.rs");
include!("commands/dispatch_commands.rs");
