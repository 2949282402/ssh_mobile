//! Structured protocol error construction.

use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode, RetryDisposition};

/// 构建不带操作上下文的协议错误。
pub(crate) fn protocol_error(code: NetworkErrorCode, message: impl Into<String>) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: String::new(),
        peer_id: String::new(),
        retry_disposition: RetryDisposition::Unspecified as i32,
        retry_after_seconds: 0,
    }
}

/// 构建带操作和可选对端上下文的协议错误。
pub(crate) fn protocol_error_with_context(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: Option<&str>,
) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: operation.to_string(),
        peer_id: peer_id.unwrap_or_default().to_string(),
        retry_disposition: RetryDisposition::Unspecified as i32,
        retry_after_seconds: 0,
    }
}

/// 构建带重试策略的协议错误；服务端设备面错误用其覆盖默认的重试行为。
pub(crate) fn protocol_error_with_retry(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: Option<&str>,
    retry_disposition: RetryDisposition,
    retry_after_seconds: u32,
) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
        operation: operation.to_string(),
        peer_id: peer_id.unwrap_or_default().to_string(),
        retry_disposition: retry_disposition as i32,
        retry_after_seconds,
    }
}

/// 构建与一个对端操作关联的协议错误。
pub(crate) fn protocol_error_with_peer(
    code: NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: &str,
) -> ProtocolError {
    protocol_error_with_context(code, message, operation, Some(peer_id))
}
