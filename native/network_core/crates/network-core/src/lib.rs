//! Core network runtime and lifecycle management.

use std::sync::{Arc, Mutex};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tracing::info;
use network_protocol::{NetworkCommand, NetworkEvent};

#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    #[error("Failed to initialize async runtime: {0}")]
    RuntimeInitFailed(String),
    #[error("Invalid runtime handle")]
    InvalidHandle,
    #[error("Command queue error: {0}")]
    CommandQueueFailed(String),
}

/// Manages the Tokio async runtime lifecycle and command/event channels.
pub struct NetworkRuntime {
    runtime: Arc<Runtime>,
    command_tx: UnboundedSender<NetworkCommand>,
    event_rx: Arc<Mutex<UnboundedReceiver<NetworkEvent>>>,
    event_tx: UnboundedSender<NetworkEvent>,
}

impl NetworkRuntime {
    /// Creates a new `NetworkRuntime` instance with channels and background worker.
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|e| NetworkError::RuntimeInitFailed(e.to_string()))?;

        let (cmd_tx, mut cmd_rx) = unbounded_channel::<NetworkCommand>();
        let (evt_tx, evt_rx) = unbounded_channel::<NetworkEvent>();

        let _evt_tx_clone = evt_tx.clone();

        // Spawn background worker loop to process commands and emit events
        runtime.spawn(async move {
            info!("Network runtime worker started");
            while let Some(cmd) = cmd_rx.recv().await {
                info!("Processed network command: {}", cmd.command_id);
                // Background processing logic will dispatch to QUIC/NAT modules
            }
            info!("Network runtime worker shut down");
        });

        info!("NetworkRuntime initialized successfully");

        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx: cmd_tx,
            event_rx: Arc::new(Mutex::new(evt_rx)),
            event_tx: evt_tx,
        })
    }

    /// Returns a reference to the inner Tokio runtime handle.
    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }

    /// Enqueues a command into the runtime worker queue.
    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        self.command_tx
            .send(command)
            .map_err(|e| NetworkError::CommandQueueFailed(e.to_string()))
    }

    /// Polls for the next available event with timeout (non-blocking if timeout is 0).
    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut rx_guard = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            rx_guard.try_recv().ok()
        } else {
            let handle = self.runtime.handle();
            let _guard = handle.enter();
            let fut = async {
                tokio::time::timeout(
                    std::time::Duration::from_millis(timeout_ms as u64),
                    rx_guard.recv(),
                )
                .await
            };
            handle.block_on(fut).ok()?
        }
    }

    /// Pushes an event directly into the event stream.
    pub fn emit_event(&self, event: NetworkEvent) {
        let _ = self.event_tx.send(event);
    }
}
