//! Core network runtime and lifecycle management.

use std::sync::Arc;
use tokio::runtime::Runtime;
use tracing::info;

#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    #[error("Failed to initialize async runtime: {0}")]
    RuntimeInitFailed(String),
    #[error("Invalid runtime handle")]
    InvalidHandle,
}

/// Manages the Tokio async runtime lifecycle for the network core.
pub struct NetworkRuntime {
    runtime: Arc<Runtime>,
}

impl NetworkRuntime {
    /// Creates a new `NetworkRuntime` instance with a multi-thread Tokio runtime.
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|e| NetworkError::RuntimeInitFailed(e.to_string()))?;

        info!("NetworkRuntime initialized successfully");

        Ok(Self {
            runtime: Arc::new(runtime),
        })
    }

    /// Returns a reference to the inner Tokio runtime handle.
    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }
}
