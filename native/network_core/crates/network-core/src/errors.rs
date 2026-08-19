//! Network Protocol V2 网络运行时的内部错误类型。
//!
//! 该错误只描述 runtime 生命周期和命令队列边界；线协议错误仍由
//! `network-protocol` 中的结构化 `NetworkError` 表示。

/// 描述原生网络运行时边界上的不可恢复操作错误。
#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    /// Tokio 异步运行时初始化失败。
    #[error("Failed to initialize async runtime: {0}")]
    RuntimeInitFailed(String),

    /// FFI 或内部调用提供了无效句柄。
    #[error("Invalid runtime handle")]
    InvalidHandle,

    /// 命令队列或其同步边界失败。
    #[error("Command queue error: {0}")]
    CommandQueueFailed(String),

    /// 运行时尚未处于 Running 状态。
    #[error("Network runtime is not running")]
    RuntimeNotRunning,
}

/// Errors owned by the peer/path coordination slice.
///
/// These errors deliberately stay below the wire-protocol boundary.  The
/// existing transport/relay implementations still expose their protocol
/// errors, while the Core Network owner can make lifecycle and resource
/// decisions without inventing a second wire error contract.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum CoreNetworkError {
    #[error("peer id must contain 1-128 characters")]
    InvalidPeerId,

    #[error("peer mailbox is full")]
    MailboxFull,

    #[error("peer supervisor is stopping")]
    SupervisorStopping,

    #[error("peer command id is already complete or pending")]
    DuplicateCommand,

    #[error("command id must contain 1-128 characters")]
    InvalidCommandId,

    #[error("peer has no compatible ready path")]
    NoRoute,

    #[error("peer operation was cancelled")]
    Cancelled,

    #[error("peer establishment attempt is stale")]
    StaleAttempt,

    #[error("peer intent generation is stale")]
    StaleIntent,

    #[error("requested path capability is not available")]
    CapabilityUnavailable,

    #[error("resource limit exceeded: {0}")]
    ResourceLimit(&'static str),
}
