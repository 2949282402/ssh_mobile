//! Relay v2 客户端共享的认证/URL/错误助手。
//!
//! transport-network v2（§24/§31/§32）把 v1 单一 `RelayClient` 拆成物理隔离的
//! `RelayControlClient` 与 `RelayDataClient`；二者绝不共享 socket/queue/budget，但
//! 复用同一套设备认证请求构建、URL 规范化与连接错误映射。这些助手在 v1
//! `client.rs` 中提取后归入本模块（Step 11）。

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use rand::RngCore;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};
use url::Url;

/// 描述 Relay v2 连接、认证和帧校验失败。
#[derive(Debug, thiserror::Error)]
pub enum RelayError {
    /// Relay 配置不符合本地协议边界。
    #[error("invalid Relay configuration: {0}")]
    InvalidConfiguration(String),
    /// Relay 设备认证失败。
    #[error("Relay authentication failed: {0}")]
    Authentication(String),
    /// Relay 凭据已过期；重连必须等待新的 ConfigureRelayCommand。
    #[error("Relay credential expired: {0}")]
    CredentialExpired(String),
    /// Relay 设备身份冲突；该错误是终态的，不应盲目重连。
    #[error("Relay identity conflict: {0}")]
    IdentityConflict(String),
    /// Relay v2 帧或控制字段不符合协议。
    #[error("Relay protocol error: {0}")]
    Protocol(String),
    /// Relay 尚未建立连接。
    #[error("Relay is not connected")]
    NotConnected,
    /// Relay 请求在超时时间内未收到应答。
    #[error("Relay request timed out: {0}")]
    Timeout(String),
    /// WebSocket 操作失败。
    #[error("Relay socket error: {0}")]
    Socket(String),
}

/// 返回当前 Unix 毫秒时间戳。
pub(crate) fn unix_timestamp_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn unix_timestamp_seconds() -> Result<i64, RelayError> {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| {
            RelayError::InvalidConfiguration(
                "system clock is before the Unix epoch; cannot sign Relay proof".into(),
            )
        })?
        .as_secs();
    let timestamp = i64::try_from(seconds).map_err(|_| {
        RelayError::InvalidConfiguration("system clock exceeds Relay timestamp range".into())
    })?;
    if timestamp <= 0 {
        return Err(RelayError::InvalidConfiguration(
            "system clock cannot produce a positive Relay timestamp".into(),
        ));
    }
    Ok(timestamp)
}

fn authenticated_proof_transcript(path: &str, timestamp: i64, nonce: &str) -> String {
    format!("{}\n{}\n{}\n{}", Method::GET, path, timestamp, nonce)
}

/// 将 HTTPS/WSS 源站规范化为固定 WebSocket 路径，并返回带设备认证头的请求。
pub(crate) fn authenticated_ws_request(
    relay_url: &Url,
    credential: &str,
    signing_key: &SigningKey,
) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, RelayError> {
    let path = relay_url.path();
    let mut nonce_bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = URL_SAFE_NO_PAD.encode(nonce_bytes);
    let timestamp = unix_timestamp_seconds()?;
    let transcript = authenticated_proof_transcript(path, timestamp, &nonce);
    let signature = URL_SAFE_NO_PAD.encode(signing_key.sign(transcript.as_bytes()).to_bytes());
    let mut request = relay_url
        .as_str()
        .into_client_request()
        .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?;
    request.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {credential}"))
            .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?,
    );
    request.headers_mut().insert(
        "X-Relay-Timestamp",
        HeaderValue::from_str(&timestamp.to_string())
            .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?,
    );
    request.headers_mut().insert(
        "X-Relay-Nonce",
        HeaderValue::from_str(&nonce)
            .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?,
    );
    request.headers_mut().insert(
        "X-Relay-Signature",
        HeaderValue::from_str(&signature)
            .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?,
    );
    Ok(request)
}

/// 将 HTTPS/WSS 源站规范化为指定 WebSocket 路径。
pub(crate) fn normalize_relay_url(value: &str, path: &str) -> Result<Url, RelayError> {
    let mut url =
        Url::parse(value).map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(RelayError::InvalidConfiguration(
            "Relay URL must be an origin without credentials, path, query, or fragment".into(),
        ));
    }
    #[cfg(feature = "test-support")]
    let is_insecure_local_test_url = matches!(url.scheme(), "http" | "ws");
    #[cfg(feature = "test-support")]
    if is_insecure_local_test_url
        && !url.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|address| address.is_loopback())
        })
    {
        return Err(RelayError::InvalidConfiguration(
            "insecure Relay test URLs must target loopback".into(),
        ));
    }
    match url.scheme() {
        "https" => url
            .set_scheme("wss")
            .map_err(|_| RelayError::InvalidConfiguration("invalid Relay URL scheme".into()))?,
        "wss" => {}
        #[cfg(feature = "test-support")]
        "http" => url
            .set_scheme("ws")
            .map_err(|_| RelayError::InvalidConfiguration("invalid Relay URL scheme".into()))?,
        #[cfg(feature = "test-support")]
        "ws" => {}
        _ => {
            return Err(RelayError::InvalidConfiguration(
                "Relay URL must use HTTPS/WSS".into(),
            ));
        }
    }
    url.set_path(path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

/// 将 WebSocket 升级失败映射为类型化 Relay 错误。HTTP 层错误携带设备面
/// JSON `code`（12=凭据过期，13=身份冲突）；其余传输错误保持 `Socket`。
pub(crate) fn map_connect_error(error: tokio_tungstenite::tungstenite::Error) -> RelayError {
    match error {
        tokio_tungstenite::tungstenite::Error::Http(response) => {
            let status = response.status();
            let device_code = response
                .body()
                .as_ref()
                .and_then(|body| serde_json::from_slice::<Value>(body).ok())
                .and_then(|value| value.get("code").and_then(Value::as_u64));
            match device_code {
                Some(12) => RelayError::CredentialExpired(format!(
                    "Relay rejected the connection (HTTP {status}, code 12)"
                )),
                Some(13) => RelayError::IdentityConflict(format!(
                    "Relay rejected the connection (HTTP {status}, code 13)"
                )),
                Some(code) => RelayError::Authentication(format!(
                    "Relay rejected the connection (HTTP {status}, code {code})"
                )),
                None => RelayError::Authentication(format!(
                    "Relay rejected the connection with HTTP {status}"
                )),
            }
        }
        other => RelayError::Socket(other.to_string()),
    }
}

use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    http::{HeaderValue, Method},
};

#[cfg(test)]
#[path = "../tests/v2/shared.rs"]
mod tests;
