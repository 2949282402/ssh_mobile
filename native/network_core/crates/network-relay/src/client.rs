//! v1 Relay WebSocket 客户端。
//!
//! 客户端只转发经过设备端 E2E 加密的 offer 和分块，不保存明文文件，
//! 并严格固定设备认证、ready 帧、会话控制和二进制帧边界。

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tokio::sync::{mpsc, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{
        client::IntoClientRequest,
        http::{HeaderValue, Method},
        Message,
    },
};
use tracing::info;
use url::Url;

const RELAY_PROTOCOL_VERSION: u32 = 1;
const RELAY_CONNECT_PATH: &str = "/v1/connect";
const MAX_CONTROL_BYTES: usize = 64 * 1024;
const MAX_BINARY_PAYLOAD_BYTES: usize = 512 * 1024 + 16;
const MAX_CHANNEL_PAYLOAD_BYTES: usize = 48 * 1024;
const SOCKET_OPERATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);

/// 描述 Relay v1 连接、认证和帧校验失败。
#[derive(Debug, thiserror::Error)]
pub enum RelayError {
    /// Relay 配置不符合本地协议边界。
    #[error("invalid Relay configuration: {0}")]
    InvalidConfiguration(String),
    /// Relay 设备认证失败。
    #[error("Relay authentication failed: {0}")]
    Authentication(String),
    /// Relay v1 帧或控制字段不符合协议。
    #[error("Relay protocol error: {0}")]
    Protocol(String),
    /// Relay 尚未建立连接。
    #[error("Relay is not connected")]
    NotConnected,
    /// WebSocket 操作失败。
    #[error("Relay socket error: {0}")]
    Socket(String),
}

/// 表示从 Relay v1 收到的透明事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayEvent {
    Lookup {
        peer_id: String,
        online: bool,
    },
    Control {
        kind: String,
        session_id: String,
        peer_id: Option<String>,
        payload: Option<String>,
    },
    Binary {
        kind: u8,
        session_id: String,
        sequence: u64,
        payload: Vec<u8>,
    },
    /// Relay socket 或后台 worker 意外结束。
    Disconnected {
        reason: String,
    },
}

/// 连接驻留内存的 Go Relay，并只转发不透明的 E2E 信封。
pub struct RelayClient {
    relay_url: Url,
    device_id: String,
    credential: String,
    signing_key: SigningKey,
    outbound: Option<mpsc::Sender<Message>>,
    inbound: Option<mpsc::Receiver<RelayEvent>>,
    inbound_tx: mpsc::Sender<RelayEvent>,
    writer_task: Option<JoinHandle<()>>,
    reader_task: Option<JoinHandle<()>>,
    pub is_connected: Arc<RwLock<bool>>,
    disconnect_notified: Arc<AtomicBool>,
    intentional_disconnect: Arc<AtomicBool>,
}

impl Drop for RelayClient {
    /// 中止尚未结束的读写 worker，避免运行时销毁后继续占用 socket。
    fn drop(&mut self) {
        if let Some(task) = self.writer_task.take() {
            task.abort();
        }
        if let Some(task) = self.reader_task.take() {
            task.abort();
        }
    }
}

impl RelayClient {
    /// 创建并校验一个 Relay v1 客户端。
    pub fn new(
        relay_url: String,
        device_id: String,
        credential: String,
        signing_seed: [u8; 32],
    ) -> Result<Self, RelayError> {
        if device_id.is_empty()
            || device_id.len() > 128
            || credential.is_empty()
            || credential.len() > 16 * 1024
            || relay_url.len() > 2048
        {
            return Err(RelayError::InvalidConfiguration(
                "Relay URL, device ID, or credential is outside protocol bounds".into(),
            ));
        }
        let relay_url = normalize_relay_url(&relay_url)?;
        let (inbound_tx, inbound) = mpsc::channel(16);
        Ok(Self {
            relay_url,
            device_id,
            credential,
            signing_key: SigningKey::from_bytes(&signing_seed),
            outbound: None,
            inbound: Some(inbound),
            inbound_tx,
            writer_task: None,
            reader_task: None,
            is_connected: Arc::new(RwLock::new(false)),
            disconnect_notified: Arc::new(AtomicBool::new(false)),
            intentional_disconnect: Arc::new(AtomicBool::new(false)),
        })
    }

    /// 使用设备凭据和签名证明建立 v1 WebSocket 连接。
    pub async fn connect(&mut self) -> Result<(), RelayError> {
        if *self.is_connected.read().await {
            return Ok(());
        }
        if self.outbound.is_some() {
            self.disconnect().await;
        }
        self.disconnect_notified.store(false, Ordering::Release);
        self.intentional_disconnect.store(false, Ordering::Release);
        let mut nonce_bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = URL_SAFE_NO_PAD.encode(nonce_bytes);
        let transcript = format!("{}\n{}\n{}", Method::GET, RELAY_CONNECT_PATH, nonce);
        let signature =
            URL_SAFE_NO_PAD.encode(self.signing_key.sign(transcript.as_bytes()).to_bytes());
        let mut request = self
            .relay_url
            .as_str()
            .into_client_request()
            .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?;
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {}", self.credential))
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
        let (socket, _) = tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| RelayError::Socket("connection timed out".into()))?
            .map_err(|error| RelayError::Socket(error.to_string()))?;
        let (mut writer, mut reader) = socket.split();
        let ready = tokio::time::timeout(std::time::Duration::from_secs(8), reader.next())
            .await
            .map_err(|_| RelayError::Authentication("ready frame timed out".into()))?
            .ok_or_else(|| RelayError::Authentication("socket closed before ready".into()))?
            .map_err(|error| RelayError::Socket(error.to_string()))?;
        validate_ready(ready, &self.device_id)?;

        let (outbound, mut outbound_rx) = mpsc::channel::<Message>(8);
        self.outbound = Some(outbound);
        *self.is_connected.write().await = true;
        let connected_for_writer = Arc::clone(&self.is_connected);
        let inbound_for_writer = self.inbound_tx.clone();
        let notified_for_writer = Arc::clone(&self.disconnect_notified);
        let intentional_for_writer = Arc::clone(&self.intentional_disconnect);
        self.writer_task = Some(tokio::spawn(async move {
            let mut heartbeat = tokio::time::interval(std::time::Duration::from_secs(20));
            heartbeat.tick().await;
            let mut reason = "Relay writer stopped".to_string();
            loop {
                let message = tokio::select! {
                    message = outbound_rx.recv() => {
                        let Some(message) = message else {
                            reason = "Relay outbound queue closed".to_string();
                            break;
                        };
                        message
                    }
                    _ = heartbeat.tick() => Message::Text(
                        json!({
                            "type": "heartbeat",
                            "timestamp": unix_timestamp_ms(),
                        })
                        .to_string()
                        .into(),
                    ),
                };
                let should_stop = matches!(message, Message::Close(_));
                if !matches!(
                    tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, writer.send(message)).await,
                    Ok(Ok(()))
                ) {
                    reason = "Relay writer failed".to_string();
                    break;
                }
                if should_stop {
                    break;
                }
            }
            mark_disconnected(
                &connected_for_writer,
                &inbound_for_writer,
                &notified_for_writer,
                &intentional_for_writer,
                reason,
            )
            .await;
        }));
        let inbound_tx = self.inbound_tx.clone();
        let connected_for_reader = Arc::clone(&self.is_connected);
        let notified_for_reader = Arc::clone(&self.disconnect_notified);
        let intentional_for_reader = Arc::clone(&self.intentional_disconnect);
        self.reader_task = Some(tokio::spawn(async move {
            let mut reason = "Relay reader stopped".to_string();
            while let Some(message) = reader.next().await {
                let Ok(message) = message else {
                    reason = "Relay reader failed".to_string();
                    break;
                };
                match decode_event(message) {
                    Ok(Some(event)) => {
                        if inbound_tx.send(event).await.is_err() {
                            reason = "Relay event queue closed".to_string();
                            break;
                        }
                    }
                    Ok(None) => {}
                    Err(_) => {
                        reason = "Relay protocol stream failed".to_string();
                        break;
                    }
                }
            }
            mark_disconnected(
                &connected_for_reader,
                &inbound_tx,
                &notified_for_reader,
                &intentional_for_reader,
                reason,
            )
            .await;
        }));
        info!("Relay client connected using protocol v1");
        Ok(())
    }

    /// 取出唯一的 Relay 事件接收器。
    pub fn take_events(&mut self) -> Result<mpsc::Receiver<RelayEvent>, RelayError> {
        self.inbound
            .take()
            .ok_or_else(|| RelayError::Protocol("Relay events were already consumed".into()))
    }

    /// 返回 Relay socket 是否仍可用于新的控制/数据帧。
    pub async fn is_usable(&self) -> bool {
        *self.is_connected.read().await
            && self
                .outbound
                .as_ref()
                .is_some_and(|sender| !sender.is_closed())
    }

    /// 发送经过 E2E 加密的文件 offer。
    pub async fn send_offer(
        &self,
        session_id: &str,
        target_id: &str,
        opaque_payload: &str,
    ) -> Result<(), RelayError> {
        validate_session_id(session_id)?;
        if target_id.is_empty() || target_id.len() > 128 || opaque_payload.is_empty() {
            return Err(RelayError::InvalidConfiguration(
                "target and opaque offer are required".into(),
            ));
        }
        self.send_control(json!({
            "type": "offer",
            "session_id": session_id,
            "target_id": target_id,
            "payload": opaque_payload,
        }))
        .await
    }

    /// 发送不透明的 Delivery DataMessage；Relay 只按 target_id 转发，
    /// 不解析 session、MessageId 或业务 payload。
    pub async fn send_channel_message(
        &self,
        session_token: &str,
        target_id: &str,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        self.send_channel_control("channel_message", session_token, target_id, payload)
            .await
    }

    /// 发送不透明的 DeliveryAck；它与 DataMessage 使用同一 message token。
    pub async fn send_channel_ack(
        &self,
        session_token: &str,
        target_id: &str,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        self.send_channel_control("channel_ack", session_token, target_id, payload)
            .await
    }

    /// 请求 Relay 返回目标设备当前在线状态。
    pub async fn lookup_peer(&self, target_id: &str) -> Result<(), RelayError> {
        if target_id.is_empty() || target_id.len() > 128 {
            return Err(RelayError::InvalidConfiguration(
                "lookup target must contain 1-128 characters".into(),
            ));
        }
        self.send_control(json!({
            "type": "lookup",
            "target_id": target_id,
        }))
        .await
    }

    /// 发送一个受限的 v1 会话控制帧。
    pub async fn send_session_control(
        &self,
        kind: &str,
        session_id: &str,
    ) -> Result<(), RelayError> {
        self.send_session_control_with_payload(kind, session_id, None)
            .await
    }

    /// 发送一个带小型应用层确认 payload 的会话控制帧。
    ///
    /// Relay 只校验并转发这个字符串，不读取其中的文件元数据；文件恢复所需的
    /// TransferId、Manifest Hash 和 Offset 仍由设备端 E2E 逻辑解释。
    pub async fn send_session_control_with_payload(
        &self,
        kind: &str,
        session_id: &str,
        payload: Option<&str>,
    ) -> Result<(), RelayError> {
        if !matches!(kind, "accept" | "complete" | "complete_ack" | "cancel") {
            return Err(RelayError::InvalidConfiguration(
                "unsupported Relay control type".into(),
            ));
        }
        validate_session_id(session_id)?;
        let mut value = json!({"type": kind, "session_id": session_id});
        if let Some(payload) = payload {
            if payload.is_empty() || payload.len() > MAX_CONTROL_BYTES / 2 {
                return Err(RelayError::InvalidConfiguration(
                    "Relay control payload is outside protocol bounds".into(),
                ));
            }
            value["payload"] = Value::String(payload.to_string());
        }
        self.send_control(value).await
    }

    async fn send_channel_control(
        &self,
        kind: &str,
        session_token: &str,
        target_id: &str,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        if !matches!(kind, "channel_message" | "channel_ack") {
            return Err(RelayError::InvalidConfiguration(
                "unsupported Relay channel control type".into(),
            ));
        }
        validate_session_id(session_token)?;
        if target_id.is_empty() || target_id.len() > 128 {
            return Err(RelayError::InvalidConfiguration(
                "channel target must contain 1-128 characters".into(),
            ));
        }
        if payload.is_empty() || payload.len() > MAX_CHANNEL_PAYLOAD_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "channel payload size is outside protocol bounds".into(),
            ));
        }
        self.send_control(json!({
            "type": kind,
            "session_id": session_token,
            "target_id": target_id,
            "payload": URL_SAFE_NO_PAD.encode(payload),
        }))
        .await
    }

    /// 转发一个带会话和序号的 E2E 加密二进制分块。
    pub async fn forward_opaque_payload(
        &self,
        session_id: &str,
        sequence: u64,
        ciphertext: &[u8],
    ) -> Result<usize, RelayError> {
        validate_session_id(session_id)?;
        if ciphertext.is_empty() || ciphertext.len() > MAX_BINARY_PAYLOAD_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "opaque payload size is outside protocol bounds".into(),
            ));
        }
        let frame = encode_binary_frame(session_id, sequence, ciphertext)?;
        self.outbound()?
            .send_timeout(Message::Binary(frame.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)?;
        Ok(ciphertext.len())
    }

    /// 关闭 Relay socket 和后台读写 worker。
    pub async fn disconnect(&mut self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        if let Some(outbound) = self.outbound.take() {
            let _ = outbound
                .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                .await;
        }
        if let Some(task) = self.writer_task.take() {
            let _ = task.await;
        }
        if let Some(task) = self.reader_task.take() {
            task.abort();
            let _ = task.await;
        }
        *self.is_connected.write().await = false;
        info!("Relay client disconnected");
    }

    /// 请求共享 Relay 客户端主动关闭；适用于运行时保存的 Arc 引用。
    pub async fn request_disconnect(&self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        if let Some(outbound) = self.outbound.as_ref() {
            let _ = outbound
                .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                .await;
        }
        *self.is_connected.write().await = false;
    }

    /// 序列化并发送一个受大小限制的控制信封。
    async fn send_control(&self, value: Value) -> Result<(), RelayError> {
        let encoded = serde_json::to_string(&value)
            .map_err(|error| RelayError::Protocol(error.to_string()))?;
        if encoded.len() > MAX_CONTROL_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "Relay control frame is too large".into(),
            ));
        }
        self.outbound()?
            .send_timeout(Message::Text(encoded.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)
    }

    /// 返回已建立连接的出站队列。
    fn outbound(&self) -> Result<&mpsc::Sender<Message>, RelayError> {
        let outbound = self.outbound.as_ref().ok_or(RelayError::NotConnected)?;
        if outbound.is_closed() {
            return Err(RelayError::NotConnected);
        }
        Ok(outbound)
    }
}

/// 将 worker 终止转换为一次性的 Relay 断开事件。
async fn mark_disconnected(
    connected: &Arc<RwLock<bool>>,
    inbound: &mpsc::Sender<RelayEvent>,
    notified: &Arc<AtomicBool>,
    intentional: &Arc<AtomicBool>,
    reason: String,
) {
    *connected.write().await = false;
    if !intentional.load(Ordering::Acquire) && !notified.swap(true, Ordering::AcqRel) {
        let _ = inbound.send(RelayEvent::Disconnected { reason }).await;
    }
}

/// 返回当前 Unix 毫秒时间戳。
fn unix_timestamp_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

/// 将 HTTPS/WSS 源站规范化为固定的 v1 WebSocket 路径。
fn normalize_relay_url(value: &str) -> Result<Url, RelayError> {
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
    match url.scheme() {
        "https" => url
            .set_scheme("wss")
            .map_err(|_| RelayError::InvalidConfiguration("invalid Relay URL scheme".into()))?,
        "wss" => {}
        _ => {
            return Err(RelayError::InvalidConfiguration(
                "Relay URL must use HTTPS/WSS".into(),
            ));
        }
    }
    url.set_path(RELAY_CONNECT_PATH);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

/// 校验 Relay v1 ready 帧的设备绑定和协议版本。
fn validate_ready(message: Message, expected_device_id: &str) -> Result<(), RelayError> {
    let Message::Text(text) = message else {
        return Err(RelayError::Authentication(
            "Relay ready frame must be text".into(),
        ));
    };
    let value: Value = serde_json::from_str(&text)
        .map_err(|error| RelayError::Authentication(error.to_string()))?;
    if value.get("type").and_then(Value::as_str) != Some("ready")
        || value.get("device_id").and_then(Value::as_str) != Some(expected_device_id)
        || value.get("protocol_version").and_then(Value::as_u64)
            != Some(RELAY_PROTOCOL_VERSION as u64)
    {
        return Err(RelayError::Authentication(
            "Relay returned an invalid ready frame".into(),
        ));
    }
    Ok(())
}

/// 解码并校验 Relay 控制帧或不透明二进制分块。
fn decode_event(message: Message) -> Result<Option<RelayEvent>, RelayError> {
    match message {
        Message::Text(text) => {
            if text.len() > MAX_CONTROL_BYTES {
                return Err(RelayError::Protocol("control frame is too large".into()));
            }
            let value: Value = serde_json::from_str(&text)
                .map_err(|error| RelayError::Protocol(error.to_string()))?;
            let kind = value
                .get("type")
                .and_then(Value::as_str)
                .ok_or_else(|| RelayError::Protocol("control type is missing".into()))?;
            if kind == "heartbeat_ack" {
                return Ok(None);
            }
            if kind == "lookup_response" {
                let peer_id = value
                    .get("target_id")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty() && value.len() <= 128)
                    .ok_or_else(|| RelayError::Protocol("lookup target is missing".into()))?;
                let online = value
                    .get("online")
                    .and_then(Value::as_bool)
                    .ok_or_else(|| RelayError::Protocol("lookup status is missing".into()))?;
                return Ok(Some(RelayEvent::Lookup {
                    peer_id: peer_id.to_string(),
                    online,
                }));
            }
            if !matches!(
                kind,
                "offer"
                    | "accept"
                    | "complete"
                    | "complete_ack"
                    | "cancel"
                    | "channel_message"
                    | "channel_ack"
            ) {
                return Err(RelayError::Protocol("unsupported control type".into()));
            }
            let session_id = value
                .get("session_id")
                .and_then(Value::as_str)
                .ok_or_else(|| RelayError::Protocol("session ID is missing".into()))?;
            validate_session_id(session_id)?;
            Ok(Some(RelayEvent::Control {
                kind: kind.to_string(),
                session_id: session_id.to_string(),
                peer_id: value
                    .get("sender_id")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                payload: value
                    .get("payload")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            }))
        }
        Message::Binary(frame) => decode_binary_frame(&frame).map(Some),
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        Message::Close(_) => Err(RelayError::Socket("Relay closed the socket".into())),
        Message::Frame(_) => Err(RelayError::Protocol("raw frame is unsupported".into())),
    }
}

/// 编码带固定类型、会话标识和大端序号的二进制帧。
fn encode_binary_frame(
    session_id: &str,
    sequence: u64,
    ciphertext: &[u8],
) -> Result<Vec<u8>, RelayError> {
    let session = hex::decode(session_id)
        .map_err(|_| RelayError::InvalidConfiguration("session ID is not hex".into()))?;
    if session.len() != 16 {
        return Err(RelayError::InvalidConfiguration(
            "session ID must contain 16 bytes".into(),
        ));
    }
    let mut frame = Vec::with_capacity(25 + ciphertext.len());
    frame.push(0x10);
    frame.extend_from_slice(&session);
    frame.extend_from_slice(&sequence.to_be_bytes());
    frame.extend_from_slice(ciphertext);
    Ok(frame)
}

/// 解码并校验 Relay 二进制帧边界。
fn decode_binary_frame(frame: &[u8]) -> Result<RelayEvent, RelayError> {
    if frame.len() <= 25 || frame.len() > 25 + MAX_BINARY_PAYLOAD_BYTES || frame[0] != 0x10 {
        return Err(RelayError::Protocol("invalid binary frame".into()));
    }
    let session_id = hex::encode(&frame[1..17]);
    let sequence = u64::from_be_bytes(
        frame[17..25]
            .try_into()
            .map_err(|_| RelayError::Protocol("invalid sequence".into()))?,
    );
    Ok(RelayEvent::Binary {
        kind: frame[0],
        session_id,
        sequence,
        payload: frame[25..].to_vec(),
    })
}

/// 校验会话标识是 16 字节十六进制值。
fn validate_session_id(session_id: &str) -> Result<(), RelayError> {
    if session_id.len() != 32 || !session_id.bytes().all(|value| value.is_ascii_hexdigit()) {
        return Err(RelayError::InvalidConfiguration(
            "session ID must be 32 hexadecimal characters".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// 验证 Relay 二进制帧与 Dart、Go v1 契约一致。
    fn binary_frame_matches_the_current_dart_and_go_contract() {
        let session_id = "00112233445566778899aabbccddeeff";
        let encoded = encode_binary_frame(session_id, 7, &[1, 2, 3]).expect("encode");
        assert_eq!(encoded.len(), 28);
        assert_eq!(encoded[0], 0x10);
        assert_eq!(&encoded[17..25], &7u64.to_be_bytes());
        assert_eq!(
            decode_binary_frame(&encoded).expect("decode"),
            RelayEvent::Binary {
                kind: 0x10,
                session_id: session_id.into(),
                sequence: 7,
                payload: vec![1, 2, 3],
            }
        );
    }

    #[test]
    /// 验证 lookup 响应必须携带明确的在线布尔值。
    fn lookup_response_requires_an_explicit_online_boolean() {
        assert_eq!(
            decode_event(Message::Text(
                r#"{"type":"lookup_response","target_id":"offline-peer","online":false}"#.into(),
            ))
            .expect("decode"),
            Some(RelayEvent::Lookup {
                peer_id: "offline-peer".into(),
                online: false,
            })
        );
        assert!(decode_event(Message::Text(
            r#"{"type":"lookup_response","target_id":"offline-peer"}"#.into(),
        ))
        .is_err());
    }

    #[test]
    /// 验证 Delivery channel 控制帧只保留 sender、session 和 opaque payload。
    fn channel_control_preserves_opaque_payload() {
        let event = decode_event(Message::Text(
            r#"{"type":"channel_message","session_id":"00112233445566778899aabbccddeeff","sender_id":"device-a","payload":"b3BhcXVl"}"#.into(),
        ))
        .expect("decode")
        .expect("channel event");
        assert_eq!(
            event,
            RelayEvent::Control {
                kind: "channel_message".into(),
                session_id: "00112233445566778899aabbccddeeff".into(),
                peer_id: Some("device-a".into()),
                payload: Some("b3BhcXVl".into()),
            }
        );
    }

    #[test]
    /// 验证生产客户端拒绝缺失的 v1 身份材料。
    fn production_client_requires_current_protocol_identity_material() {
        assert!(RelayClient::new(
            "https://relay.example.test".into(),
            "".into(),
            "".into(),
            [0u8; 32],
        )
        .is_err());
    }
}
