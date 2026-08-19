//! Relay v2 数据面客户端（`/v2/relay/{reservation_id}`）。
//!
//! reservation 作用域：先完成 RelayDataConnect/RelayDataReady 配对握手，再转发
//! 不透明的 EncryptedPayload、流控 Ack 与 Close。拥有自己的 socket、outbound 队列
//! 与速率预算，绝不与
//! [`super::RelayControlClient`] 共享任何资源。

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::handshake::client::Request;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::info;
use url::Url;

use super::proto::*;
use super::shared::{authenticated_ws_request, map_connect_error, RelayError};

const DATA_QUEUE_CAPACITY: usize = 8;
const EVENT_QUEUE_CAPACITY: usize = 32;
const SOCKET_OPERATION_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_DATA_PAYLOAD_BYTES: usize = 512 * 1024;
/// 默认持续速率：512 KiB/s。
const DEFAULT_RATE_BYTES_PER_SEC: f64 = 512.0 * 1024.0;
/// 默认突发容量：512 KiB。
const DEFAULT_BURST_BYTES: f64 = 512.0 * 1024.0;

/// Relay v2 数据面事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataEvent {
    /// 对端发来的不透明加密载荷。
    Payload {
        sequence: u64,
        encrypted_payload: Vec<u8>,
    },
    /// 对端收到载荷的流控回执。
    Ack { sequence: u64 },
    /// 对端关闭数据面。
    Close { reason: u32, detail: String },
    /// Relay socket 或后台 worker 意外结束。
    Disconnected { reason: String },
}

/// 简单令牌桶速率预算：限制数据面 outbound 的字节速率，避免触发
/// `ERROR_CODE_RATE_LIMITED`。
struct RateBudget {
    capacity_bytes: f64,
    tokens: f64,
    last_refill: std::time::Instant,
    rate_bytes_per_sec: f64,
}

impl RateBudget {
    fn new(rate_bytes_per_sec: f64, burst_bytes: f64) -> Self {
        Self {
            capacity_bytes: burst_bytes.max(1.0),
            tokens: burst_bytes.max(1.0),
            last_refill: std::time::Instant::now(),
            rate_bytes_per_sec: rate_bytes_per_sec.max(1.0),
        }
    }

    fn refill(&mut self) {
        let elapsed = self.last_refill.elapsed().as_secs_f64();
        if elapsed > 0.0 {
            self.tokens =
                (self.tokens + elapsed * self.rate_bytes_per_sec).min(self.capacity_bytes);
            self.last_refill = std::time::Instant::now();
        }
    }

    /// 等待直到有 `bytes` 字节的预算可用，然后消耗。
    async fn acquire(&mut self, bytes: usize) {
        loop {
            self.refill();
            let required = bytes as f64;
            if self.tokens >= required {
                self.tokens -= required;
                return;
            }
            let deficit = required - self.tokens;
            tokio::time::sleep(Duration::from_secs_f64(deficit / self.rate_bytes_per_sec)).await;
        }
    }
}

/// reservation 作用域的 Relay v2 数据面客户端。
pub struct RelayDataClient {
    data_url: Url,
    reservation_id: String,
    local_token: Vec<u8>,
    credential: String,
    signing_key: SigningKey,
    outbound: Option<mpsc::Sender<Message>>,
    inbound: Option<mpsc::Receiver<DataEvent>>,
    inbound_tx: mpsc::Sender<DataEvent>,
    /// 数据面独享的速率预算。
    rate_budget: Arc<Mutex<RateBudget>>,
    writer_task: Option<JoinHandle<()>>,
    reader_task: Option<JoinHandle<()>>,
    is_connected: Arc<RwLock<bool>>,
    disconnect_notified: Arc<AtomicBool>,
    intentional_disconnect: Arc<AtomicBool>,
}

impl Drop for RelayDataClient {
    fn drop(&mut self) {
        if let Some(task) = self.writer_task.take() {
            task.abort();
        }
        if let Some(task) = self.reader_task.take() {
            task.abort();
        }
    }
}

impl RelayDataClient {
    /// 创建一个 reservation 作用域的数据面客户端。
    ///
    /// `endpoint` 是 server 在 RelayReserveResponse / IncomingRelayReservation
    /// 中下发的自包含 `wss://<host>/v2/relay/{reservation_id}` 地址。
    pub fn new(
        endpoint: String,
        reservation_id: String,
        local_token: Vec<u8>,
        credential: String,
        signing_seed: [u8; 32],
    ) -> Result<Self, RelayError> {
        if reservation_id.len() != RESERVATION_ID_HEX_CHARS
            || !reservation_id.bytes().all(|byte| byte.is_ascii_hexdigit())
            || local_token.len() != RESERVATION_TOKEN_BYTES
            || credential.is_empty()
            || credential.len() > 16 * 1024
        {
            return Err(RelayError::InvalidConfiguration(
                "Relay reservation ID or local token is outside protocol bounds".into(),
            ));
        }
        let data_url = normalize_data_endpoint(&endpoint)?;
        let (inbound_tx, inbound) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        Ok(Self {
            data_url,
            reservation_id,
            local_token,
            credential,
            signing_key: SigningKey::from_bytes(&signing_seed),
            outbound: None,
            inbound: Some(inbound),
            inbound_tx,
            rate_budget: Arc::new(Mutex::new(RateBudget::new(
                DEFAULT_RATE_BYTES_PER_SEC,
                DEFAULT_BURST_BYTES,
            ))),
            writer_task: None,
            reader_task: None,
            is_connected: Arc::new(RwLock::new(false)),
            disconnect_notified: Arc::new(AtomicBool::new(false)),
            intentional_disconnect: Arc::new(AtomicBool::new(false)),
        })
    }

    /// 连接数据面端点，发送 RelayDataConnect，并等待 RelayDataReady。
    ///
    /// WebSocket 建立或 Connect 写入成功都不代表 reservation 已经可用；只有
    /// Relay 确认 initiator/responder 两个角色都已加入后，调用方才能立即发送
    /// E2EE 业务帧。
    pub async fn connect_reservation(&mut self) -> Result<(), RelayError> {
        if *self.is_connected.read().await {
            return Err(RelayError::Protocol(
                "Relay data client is already connected".into(),
            ));
        }
        if self.outbound.is_some() {
            let _ = self.close().await;
        }
        self.disconnect_notified.store(false, Ordering::Release);
        self.intentional_disconnect.store(false, Ordering::Release);
        let request = self.build_data_upgrade_request()?;
        let (socket, _) = tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| RelayError::Socket("Relay data connection timed out".into()))?
            .map_err(map_connect_error)?;
        let (mut writer, mut reader) = socket.split();

        // 首个帧必须是 RelayDataConnect，绑定 reservation 与本地 token。
        let connect_frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Connect(RelayDataConnect {
                reservation_id: self.reservation_id.clone(),
                local_token: self.local_token.clone(),
            })),
        };
        let encoded = encode_data_frame(&connect_frame)?;
        tokio::time::timeout(
            SOCKET_OPERATION_TIMEOUT,
            writer.send(Message::Binary(encoded.into())),
        )
        .await
        .map_err(|_| RelayError::Socket("Relay data connect timed out".into()))?
        .map_err(|error| RelayError::Socket(error.to_string()))?;

        // Connect 只完成本端认证。RelayDataReady 才表示另一端也已加入；在此之前
        // 不启动业务 writer/reader，也不暴露 is_connected=true。
        let reservation_id = self.reservation_id.clone();
        let ready = tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, async {
            loop {
                let message = reader.next().await.ok_or_else(|| {
                    RelayError::Socket("Relay data closed before pairing was ready".into())
                })?;
                let message = message.map_err(|error| RelayError::Socket(error.to_string()))?;
                match message {
                    Message::Binary(frame) => {
                        let frame = decode_data_frame(&frame)?;
                        if frame.version != RELAY_V2_VERSION {
                            return Err(RelayError::Protocol(format!(
                                "unsupported Relay v2 data frame version {}",
                                frame.version
                            )));
                        }
                        match frame.kind.ok_or_else(|| {
                            RelayError::Protocol(
                                "Relay v2 data frame is missing its message kind".into(),
                            )
                        })? {
                            relay_data_frame::Kind::Ready(ready) => {
                                if ready.reservation_id != reservation_id {
                                    return Err(RelayError::Protocol(
                                        "RelayDataReady reservation does not match the client"
                                            .into(),
                                    ));
                                }
                                break Ok(());
                            }
                            relay_data_frame::Kind::Close(close) => {
                                return Err(RelayError::Socket(format!(
                                    "Relay closed data pairing: {}",
                                    close.detail
                                )))
                            }
                            relay_data_frame::Kind::Connect(_) => {
                                return Err(RelayError::Protocol(
                                    "Relay server sent RelayDataConnect during pairing".into(),
                                ))
                            }
                            relay_data_frame::Kind::Payload(_) | relay_data_frame::Kind::Ack(_) => {
                                return Err(RelayError::Protocol(
                                    "Relay sent business data before RelayDataReady".into(),
                                ))
                            }
                        }
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => {
                        return Err(RelayError::Socket(
                            "Relay closed data pairing before Ready".into(),
                        ))
                    }
                    Message::Text(_) | Message::Frame(_) => {
                        return Err(RelayError::Protocol(
                            "Relay v2 data frames must be binary protobuf".into(),
                        ))
                    }
                }
            }
        })
        .await;
        match ready {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                let _ = writer.send(Message::Close(None)).await;
                return Err(error);
            }
            Err(_) => {
                let _ = writer.send(Message::Close(None)).await;
                return Err(RelayError::Socket(
                    "Relay data pairing timed out waiting for Ready".into(),
                ));
            }
        }

        let (outbound, mut outbound_rx) = mpsc::channel::<Message>(DATA_QUEUE_CAPACITY);
        self.outbound = Some(outbound.clone());
        *self.is_connected.write().await = true;

        let connected_for_writer = Arc::clone(&self.is_connected);
        let inbound_for_writer = self.inbound_tx.clone();
        let notified_for_writer = Arc::clone(&self.disconnect_notified);
        let intentional_for_writer = Arc::clone(&self.intentional_disconnect);
        self.writer_task = Some(tokio::spawn(async move {
            let mut reason = "Relay data writer stopped".to_string();
            while let Some(message) = outbound_rx.recv().await {
                let should_stop = matches!(message, Message::Close(_));
                if !matches!(
                    tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, writer.send(message)).await,
                    Ok(Ok(()))
                ) {
                    reason = "Relay data writer failed".to_string();
                    break;
                }
                if should_stop {
                    break;
                }
            }
            mark_data_disconnected(
                &connected_for_writer,
                &inbound_for_writer,
                &notified_for_writer,
                &intentional_for_writer,
                reason,
            )
            .await;
        }));

        let inbound_tx = self.inbound_tx.clone();
        let outbound_for_reader = outbound.clone();
        let connected_for_reader = Arc::clone(&self.is_connected);
        let notified_for_reader = Arc::clone(&self.disconnect_notified);
        let intentional_for_reader = Arc::clone(&self.intentional_disconnect);
        self.reader_task = Some(tokio::spawn(async move {
            let mut reason = "Relay data reader stopped".to_string();
            while let Some(message) = reader.next().await {
                let Ok(message) = message else {
                    reason = "Relay data reader failed".to_string();
                    break;
                };
                if let Message::Ping(payload) = message {
                    // The server owns the single-writer rule.  Route the
                    // control response through the writer queue instead of
                    // writing the WebSocket from the reader task.
                    if outbound_for_reader
                        .send_timeout(Message::Pong(payload), SOCKET_OPERATION_TIMEOUT)
                        .await
                        .is_err()
                    {
                        reason = "Relay data Pong response failed".to_string();
                        break;
                    }
                    continue;
                }
                match decode_data_event(message) {
                    Ok(Some(event)) => {
                        if inbound_tx.send(event).await.is_err() {
                            reason = "Relay data event queue closed".to_string();
                            break;
                        }
                    }
                    Ok(None) => {}
                    Err(_) => {
                        reason = "Relay data protocol stream failed".to_string();
                        break;
                    }
                }
            }
            mark_data_disconnected(
                &connected_for_reader,
                &inbound_tx,
                &notified_for_reader,
                &intentional_for_reader,
                reason,
            )
            .await;
        }));
        info!("Relay v2 data client connected and paired");
        Ok(())
    }

    /// 构建数据面 WebSocket 升级请求：设备认证头 + 校验 reservation 本地 token 的
    /// `X-Relay-Token` 头。
    ///
    /// Go 端 connectRelayData 在升级前必须校验 reservation token（validRelayToken，
    /// 从 `?token=` query 或 `X-Relay-Token` header 读取），否则直接返回 401；而
    /// [`normalize_data_endpoint`] 拒绝端点携带 query，因此 token 只能经 header 传递。
    fn build_data_upgrade_request(&self) -> Result<Request, RelayError> {
        let path = self.data_url.path().to_string();
        let mut request =
            authenticated_ws_request(&self.data_url, &path, &self.credential, &self.signing_key)?;
        request.headers_mut().insert(
            "X-Relay-Token",
            HeaderValue::from_str(&hex::encode(&self.local_token))
                .map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?,
        );
        Ok(request)
    }

    /// 取出数据面事件接收器。
    pub fn take_events(&mut self) -> Result<mpsc::Receiver<DataEvent>, RelayError> {
        self.inbound
            .take()
            .ok_or_else(|| RelayError::Protocol("Relay data events were already consumed".into()))
    }

    /// 接收下一条数据面事件（Payload / Ack / Close / Disconnected）。Ready 只在
    /// `connect_reservation` 建立后台 worker 前消费，不会作为业务事件暴露。
    pub async fn recv(&mut self) -> Option<DataEvent> {
        self.inbound.as_mut()?.recv().await
    }

    /// 发送一个不透明加密载荷，经过数据面独有的速率预算。
    pub async fn send(&self, sequence: u64, encrypted_payload: &[u8]) -> Result<(), RelayError> {
        if encrypted_payload.is_empty() || encrypted_payload.len() > MAX_DATA_PAYLOAD_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "Relay data payload size is outside protocol bounds".into(),
            ));
        }
        {
            let mut budget = self.rate_budget.lock().await;
            budget.acquire(encrypted_payload.len()).await;
        }
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
                sequence,
                encrypted_payload: encrypted_payload.to_vec(),
            })),
        };
        let encoded = encode_data_frame(&frame)?;
        self.outbound()?
            .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)?;
        Ok(())
    }

    /// 发送流控回执。
    pub async fn send_ack(&self, sequence: u64) -> Result<(), RelayError> {
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Ack(RelayDataAck { sequence })),
        };
        let encoded = encode_data_frame(&frame)?;
        self.outbound()?
            .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)?;
        Ok(())
    }

    /// 返回数据面 socket 是否仍可用于新的数据帧。
    pub async fn is_usable(&self) -> bool {
        *self.is_connected.read().await
            && self
                .outbound
                .as_ref()
                .is_some_and(|sender| !sender.is_closed())
    }

    /// 关闭数据面：发送 RelayDataClose，然后关闭 socket 与 worker。
    pub async fn close(&mut self) -> Result<(), RelayError> {
        self.intentional_disconnect.store(true, Ordering::Release);
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Close(RelayDataClose {
                reason: 0,
                detail: String::new(),
            })),
        };
        if let Ok(encoded) = encode_data_frame(&frame) {
            if let Some(outbound) = self.outbound.as_ref() {
                let _ = outbound
                    .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
                    .await;
            }
        }
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
        info!("Relay v2 data client closed");
        Ok(())
    }

    /// 请求共享数据面客户端主动关闭；适用于运行时保存的 Arc 引用。
    pub async fn request_disconnect(&self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Close(RelayDataClose {
                reason: 0,
                detail: String::new(),
            })),
        };
        if let Ok(encoded) = encode_data_frame(&frame) {
            if let Some(outbound) = self.outbound.as_ref() {
                let _ = outbound
                    .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
                    .await;
                let _ = outbound
                    .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                    .await;
            }
        }
        *self.is_connected.write().await = false;
        // 主动断开也必须向事件通道发出终态事件，唤醒阻塞在 recv() 上的消费者
        // （handle_relay_data_events 只在 Close/Disconnected 时退出）；否则 consumer
        // 会永久驻留，连同 Arc<RelayDataClient> 与事件通道一起泄漏。发送失败说明
        // 消费者已退出，此时事件通道关闭即可，忽略 send 错误。
        let _ = self
            .inbound_tx
            .send(DataEvent::Close {
                reason: 0,
                detail: "intentional disconnect".into(),
            })
            .await;
    }

    fn outbound(&self) -> Result<&mpsc::Sender<Message>, RelayError> {
        let outbound = self.outbound.as_ref().ok_or(RelayError::NotConnected)?;
        if outbound.is_closed() {
            return Err(RelayError::NotConnected);
        }
        Ok(outbound)
    }
}

/// 校验数据面端点：必须是 `wss://<host>/v2/relay/{32-hex}`，保留其 path。
fn normalize_data_endpoint(value: &str) -> Result<Url, RelayError> {
    let mut url =
        Url::parse(value).map_err(|error| RelayError::InvalidConfiguration(error.to_string()))?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(RelayError::InvalidConfiguration(
            "Relay data endpoint must not carry credentials, query, or fragment".into(),
        ));
    }
    let expected_prefix = "/v2/relay/";
    let path = url.path();
    if !path.starts_with(expected_prefix)
        || path.len() != expected_prefix.len() + RESERVATION_ID_HEX_CHARS
        || !path[expected_prefix.len()..]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(RelayError::InvalidConfiguration(
            "Relay data endpoint must be wss://host/v2/relay/{32-hex-reservation}".into(),
        ));
    }
    match url.scheme() {
        "https" => url.set_scheme("wss").map_err(|_| {
            RelayError::InvalidConfiguration("invalid Relay data URL scheme".into())
        })?,
        "wss" => {}
        #[cfg(feature = "test-support")]
        "http" => url.set_scheme("ws").map_err(|_| {
            RelayError::InvalidConfiguration("invalid Relay data URL scheme".into())
        })?,
        #[cfg(feature = "test-support")]
        "ws" => {}
        _ => {
            return Err(RelayError::InvalidConfiguration(
                "Relay data URL must use HTTPS/WSS".into(),
            ));
        }
    }
    Ok(url)
}

/// 解码一个 Relay v2 数据面消息。
fn decode_data_event(message: Message) -> Result<Option<DataEvent>, RelayError> {
    match message {
        Message::Binary(frame) => {
            let frame = decode_data_frame(&frame)?;
            data_event_from_frame(frame).map(Some)
        }
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        Message::Close(_) => Err(RelayError::Socket("Relay data closed the socket".into())),
        Message::Text(_) | Message::Frame(_) => Err(RelayError::Protocol(
            "Relay v2 data frames must be binary protobuf".into(),
        )),
    }
}

/// 将 v2 数据帧转换为高层面事件，并拒绝方向非法的消息。
fn data_event_from_frame(frame: RelayDataFrame) -> Result<DataEvent, RelayError> {
    if frame.version != RELAY_V2_VERSION {
        return Err(RelayError::Protocol(format!(
            "unsupported Relay v2 data frame version {}",
            frame.version
        )));
    }
    let kind = frame.kind.ok_or_else(|| {
        RelayError::Protocol("Relay v2 data frame is missing its message kind".into())
    })?;
    Ok(match kind {
        relay_data_frame::Kind::Connect(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send RelayDataConnect frames".into(),
            ))
        }
        relay_data_frame::Kind::Ready(_) => {
            return Err(RelayError::Protocol(
                "RelayDataReady is only valid during data connection setup".into(),
            ))
        }
        relay_data_frame::Kind::Payload(message) => DataEvent::Payload {
            sequence: message.sequence,
            encrypted_payload: message.encrypted_payload,
        },
        relay_data_frame::Kind::Ack(message) => DataEvent::Ack {
            sequence: message.sequence,
        },
        relay_data_frame::Kind::Close(message) => DataEvent::Close {
            reason: message.reason,
            detail: message.detail,
        },
    })
}

/// 将 worker 终止转换为一次性的 Relay v2 数据断开事件。
async fn mark_data_disconnected(
    connected: &Arc<RwLock<bool>>,
    inbound: &mpsc::Sender<DataEvent>,
    notified: &Arc<AtomicBool>,
    intentional: &Arc<AtomicBool>,
    reason: String,
) {
    *connected.write().await = false;
    if !intentional.load(Ordering::Acquire) && !notified.swap(true, Ordering::AcqRel) {
        let _ = inbound.send(DataEvent::Disconnected { reason }).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn data_payload_frame_round_trips() {
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
                sequence: 42,
                encrypted_payload: (65..129).collect::<Vec<u8>>(),
            })),
        };
        let encoded = encode_data_frame(&frame).expect("encode");
        // [4-byte BE length][protobuf]
        assert_eq!(encoded.len(), 4 + frame.encoded_len());
        assert_eq!(
            u32::from_be_bytes(encoded[..4].try_into().unwrap()) as usize,
            encoded.len() - 4
        );
        let decoded = decode_data_frame(&encoded).expect("decode");
        assert_eq!(decoded, frame);
    }

    #[test]
    fn data_connect_frame_is_encoded_for_the_reservation() {
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Connect(RelayDataConnect {
                reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                local_token: (1..33).collect(),
            })),
        };
        let encoded = encode_data_frame(&frame).expect("encode");
        let decoded = decode_data_frame(&encoded).expect("decode");
        assert_eq!(decoded, frame);
    }

    #[test]
    fn data_close_event_decodes() {
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Close(RelayDataClose {
                reason: 1,
                detail: "expiry".into(),
            })),
        };
        let encoded = encode_data_frame(&frame).expect("encode");
        let event =
            data_event_from_frame(decode_data_frame(&encoded).expect("decode")).expect("event");
        assert_eq!(
            event,
            DataEvent::Close {
                reason: 1,
                detail: "expiry".into(),
            }
        );
    }

    #[test]
    fn data_ready_frame_is_a_setup_handshake_not_a_business_event() {
        let frame = RelayDataFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_data_frame::Kind::Ready(RelayDataReady {
                reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            })),
        };
        let encoded = encode_data_frame(&frame).expect("encode");
        let decoded = decode_data_frame(&encoded).expect("decode");
        assert_eq!(decoded, frame);
        assert!(data_event_from_frame(decoded).is_err());
    }

    #[test]
    fn data_frame_version_must_be_two() {
        let frame = RelayDataFrame {
            version: 1,
            kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
                sequence: 1,
                encrypted_payload: vec![0u8; 16],
            })),
        };
        assert!(encode_data_frame(&frame).is_err());
    }

    #[test]
    fn data_endpoint_normalization_requires_v2_reservation_path() {
        assert!(normalize_data_endpoint(
            "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"
        )
        .is_ok());
        // 错误 path（不是 /v2/relay/{32-hex}）必须被拒绝。
        assert!(normalize_data_endpoint("wss://relay.example.test/v2/relay/short").is_err());
        assert!(normalize_data_endpoint("wss://relay.example.test/v1/relay").is_err());
        assert!(normalize_data_endpoint("wss://relay.example.test").is_err());
    }

    #[tokio::test]
    async fn rate_budget_gates_oversized_bursts() {
        let budget = RateBudget::new(1024.0, 1024.0);
        let budget = Arc::new(Mutex::new(budget));
        let (inbound_tx, inbound) = mpsc::channel(4);
        let client = RelayDataClient {
            data_url: Url::parse(
                "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d",
            )
            .expect("url"),
            reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            local_token: (1..33).collect(),
            credential: "credential".into(),
            signing_key: SigningKey::from_bytes(&[0u8; 32]),
            outbound: None,
            inbound: Some(inbound),
            inbound_tx,
            rate_budget: budget,
            writer_task: None,
            reader_task: None,
            is_connected: Arc::new(RwLock::new(false)),
            disconnect_notified: Arc::new(AtomicBool::new(false)),
            intentional_disconnect: Arc::new(AtomicBool::new(false)),
        };
        // 未连接时在出站队列阶段报 NotConnected（速率预算已通过）。
        assert!(matches!(
            client.send(1, &vec![0u8; 1024]).await,
            Err(RelayError::NotConnected)
        ));
    }

    /// 回归 #1：Go 端 connectRelayData 在升级前要求 reservation 本地 token
    /// （`?token=` 或 `X-Relay-Token`），升级请求必须携带 hex 编码的 token 头。
    #[test]
    fn data_upgrade_request_carries_reservation_token_header() {
        let client = RelayDataClient::new(
            "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            (1..33).collect(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("client");
        let request = client
            .build_data_upgrade_request()
            .expect("upgrade request");
        assert_eq!(
            request
                .headers()
                .get("X-Relay-Token")
                .expect("token header")
                .to_str()
                .expect("ascii header"),
            hex::encode(&client.local_token)
        );
        // 设备认证头仍然保留。
        assert!(request.headers().get("Authorization").is_some());
    }

    /// 回归 #14a：主动断开必须向事件通道发出终态事件，否则消费者阻塞在 recv()
    /// 上永久驻留（Arc<RelayDataClient> + 事件通道泄漏）。
    #[tokio::test]
    async fn request_disconnect_emits_terminal_close_event() {
        let mut client = RelayDataClient::new(
            "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            (1..33).collect(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("client");
        let mut events = client.take_events().expect("events");
        client.request_disconnect().await;
        assert_eq!(
            events.recv().await,
            Some(DataEvent::Close {
                reason: 0,
                detail: "intentional disconnect".into(),
            })
        );
    }
}
