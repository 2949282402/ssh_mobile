//! Relay v2 控制面客户端（`/v2/control`）。
//!
//! 只发送控制消息，绝不携带 file chunk / delivery payload。应答关联完全基于
//! 逐请求 `request_id` 与逐 attempt `attempt_id`：
//!
//! - `pending: HashMap<request_id, oneshot::Sender<ControlEvent>>` —— 同步
//!   请求/应答（HeartbeatAck、DiscoveryAck、ResolvePeerResponse、
//!   RelayReserveResponse）。
//! - `attempts: HashMap<attempt_id, AttemptTracker>` —— 异步 attempt 关联
//!   （ConnectivityOffer→ConnectivityAnswer），tracker 持有该 attempt 的
//!   应答 oneshot 与创建时间。
//!
//! 不存在 v1 的全局 `Notify`；所有应答归属都由消息自身的 id 判定。

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::info;
use url::Url;

use super::proto::*;
use crate::client::{
    authenticated_ws_request, map_connect_error, normalize_relay_url, unix_timestamp_ms,
};
use crate::RelayError;

/// v2 控制面 WebSocket 路径。
pub(crate) const RELAY_V2_CONTROL_PATH: &str = "/v2/control";

const CONTROL_QUEUE_CAPACITY: usize = 8;
const EVENT_QUEUE_CAPACITY: usize = 32;
const SOCKET_OPERATION_TIMEOUT: Duration = Duration::from_secs(12);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
const CONNECTIVITY_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(12);

/// 异步控制面事件：presence hints、incoming reservation、被转发的信令等。
///
/// 同步请求/应答（resolve、discovery ack、reservation、heartbeat ack）通过
/// `pending`/`attempts` oneshot 直接投递给等待方；只有无等待方的帧才落到该流。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    HeartbeatAck(HeartbeatAck),
    DiscoveryAck(DiscoveryAck),
    ResolvePeerResponse(ResolvePeerResponse),
    /// 对端发起的连接 attempt（应答方视角）。
    ConnectivityOffer(ConnectivityOffer),
    ConnectivityAnswer(ConnectivityAnswer),
    PresenceHintSnapshot(PresenceHintSnapshot),
    PeerAvailableHint(PeerAvailableHint),
    PeerUnavailableHint(PeerUnavailableHint),
    RelayReserveResponse(RelayReserveResponse),
    IncomingRelayReservation(IncomingRelayReservation),
    RealtimeSignal(RealtimeSignal),
    ProtocolError(ProtocolError),
    Disconnected {
        reason: String,
    },
}

/// 一个进行中的异步 connectivity attempt。
struct AttemptTracker {
    created_at: Instant,
    response_tx: oneshot::Sender<ControlEvent>,
}

/// 控制面应答归属判定。
enum RouteAction {
    RequestId(u64),
    AttemptId(String),
    Event,
}

/// 连接 `/v2/control` 的长期控制面客户端。
///
/// 拥有自己的 WebSocket 与 outbound 队列；与 [`super::RelayDataClient`] 物理隔离。
pub struct RelayControlClient {
    relay_url: Url,
    device_id: String,
    credential: String,
    signing_key: SigningKey,
    outbound: Option<mpsc::Sender<Message>>,
    inbound: Option<mpsc::Receiver<ControlEvent>>,
    inbound_tx: mpsc::Sender<ControlEvent>,
    /// 逐 `request_id` 的同步请求/应答关联表。
    pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>>,
    /// 逐 `attempt_id` 的异步 attempt 关联表。
    attempts: Arc<RwLock<HashMap<String, AttemptTracker>>>,
    next_request_id: Arc<AtomicU64>,
    writer_task: Option<JoinHandle<()>>,
    reader_task: Option<JoinHandle<()>>,
    is_connected: Arc<RwLock<bool>>,
    disconnect_notified: Arc<AtomicBool>,
    intentional_disconnect: Arc<AtomicBool>,
    heartbeat_interval: Duration,
}

impl Drop for RelayControlClient {
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

impl RelayControlClient {
    /// 创建并校验一个 Relay v2 控制面客户端。
    pub fn new(
        relay_url: String,
        device_id: String,
        credential: String,
        signing_seed: [u8; 32],
    ) -> Result<Self, RelayError> {
        if device_id.is_empty()
            || device_id.len() > MAX_DEVICE_ID_BYTES
            || credential.is_empty()
            || credential.len() > 16 * 1024
            || relay_url.len() > 2048
        {
            return Err(RelayError::InvalidConfiguration(
                "Relay URL, device ID, or credential is outside protocol bounds".into(),
            ));
        }
        let relay_url = normalize_relay_url(&relay_url, RELAY_V2_CONTROL_PATH)?;
        let (inbound_tx, inbound) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        Ok(Self {
            relay_url,
            device_id,
            credential,
            signing_key: SigningKey::from_bytes(&signing_seed),
            outbound: None,
            inbound: Some(inbound),
            inbound_tx,
            pending: Arc::new(RwLock::new(HashMap::new())),
            attempts: Arc::new(RwLock::new(HashMap::new())),
            next_request_id: Arc::new(AtomicU64::new(1)),
            writer_task: None,
            reader_task: None,
            is_connected: Arc::new(RwLock::new(false)),
            disconnect_notified: Arc::new(AtomicBool::new(false)),
            intentional_disconnect: Arc::new(AtomicBool::new(false)),
            heartbeat_interval: Duration::from_secs(u64::from(HEARTBEAT_INTERVAL_S)),
        })
    }

    /// 使用设备凭据和签名证明建立 `/v2/control` 连接，并等待 Ready 帧。
    pub async fn connect(&mut self) -> Result<Ready, RelayError> {
        if *self.is_connected.read().await {
            return Err(RelayError::Protocol(
                "Relay control client is already connected".into(),
            ));
        }
        if self.outbound.is_some() {
            self.disconnect().await;
        }
        self.disconnect_notified.store(false, Ordering::Release);
        self.intentional_disconnect.store(false, Ordering::Release);
        let request = authenticated_ws_request(
            &self.relay_url,
            RELAY_V2_CONTROL_PATH,
            &self.credential,
            &self.signing_key,
        )?;
        let (socket, _) = tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| RelayError::Socket("Relay control connection timed out".into()))?
            .map_err(map_connect_error)?;
        let (mut writer, mut reader) = socket.split();
        let ready = tokio::time::timeout(Duration::from_secs(8), reader.next())
            .await
            .map_err(|_| RelayError::Authentication("Relay v2 ready frame timed out".into()))?
            .ok_or_else(|| {
                RelayError::Authentication("Relay socket closed before ready frame".into())
            })?
            .map_err(|error| RelayError::Socket(error.to_string()))?;
        let ready = validate_ready(ready, &self.device_id)?;
        self.heartbeat_interval = Duration::from_secs(u64::from(ready.heartbeat_interval_s.max(1)));

        let (outbound, mut outbound_rx) = mpsc::channel::<Message>(CONTROL_QUEUE_CAPACITY);
        self.outbound = Some(outbound);
        *self.is_connected.write().await = true;

        let connected_for_writer = Arc::clone(&self.is_connected);
        let inbound_for_writer = self.inbound_tx.clone();
        let notified_for_writer = Arc::clone(&self.disconnect_notified);
        let intentional_for_writer = Arc::clone(&self.intentional_disconnect);
        let pending_for_writer = Arc::clone(&self.pending);
        let attempts_for_writer = Arc::clone(&self.attempts);
        let heartbeat_interval = self.heartbeat_interval;
        let next_request_id = Arc::clone(&self.next_request_id);
        self.writer_task = Some(tokio::spawn(async move {
            let mut heartbeat = tokio::time::interval(heartbeat_interval);
            heartbeat.tick().await;
            let mut reason = "Relay control writer stopped".to_string();
            loop {
                let message = tokio::select! {
                    message = outbound_rx.recv() => {
                        let Some(message) = message else {
                            reason = "Relay control outbound queue closed".to_string();
                            break;
                        };
                        message
                    }
                    _ = heartbeat.tick() => {
                        // 心跳 fire-and-forget：server 的 HeartbeatAck 会在 reader 中
                        // 发现没有等待方而被静默丢弃。
                        let request_id = next_request_id.fetch_add(1, Ordering::Relaxed);
                        let frame = RelayFrame {
                            version: RELAY_V2_VERSION,
                            kind: Some(relay_frame::Kind::Heartbeat(Heartbeat {
                                request_id,
                                sent_at_ms: unix_timestamp_ms() as i64,
                            })),
                        };
                        match encode_control_frame(&frame) {
                            Ok(encoded) => Message::Binary(encoded.into()),
                            Err(_) => continue,
                        }
                    }
                };
                let should_stop = matches!(message, Message::Close(_));
                if !matches!(
                    tokio::time::timeout(SOCKET_OPERATION_TIMEOUT, writer.send(message)).await,
                    Ok(Ok(()))
                ) {
                    reason = "Relay control writer failed".to_string();
                    break;
                }
                if should_stop {
                    break;
                }
            }
            mark_control_disconnected(
                &connected_for_writer,
                &inbound_for_writer,
                &notified_for_writer,
                &intentional_for_writer,
                &pending_for_writer,
                &attempts_for_writer,
                reason,
            )
            .await;
        }));

        let inbound_tx = self.inbound_tx.clone();
        let connected_for_reader = Arc::clone(&self.is_connected);
        let notified_for_reader = Arc::clone(&self.disconnect_notified);
        let intentional_for_reader = Arc::clone(&self.intentional_disconnect);
        let pending_for_reader = Arc::clone(&self.pending);
        let attempts_for_reader = Arc::clone(&self.attempts);
        self.reader_task = Some(tokio::spawn(async move {
            let mut reason = "Relay control reader stopped".to_string();
            while let Some(message) = reader.next().await {
                let Ok(message) = message else {
                    reason = "Relay control reader failed".to_string();
                    break;
                };
                match decode_control_event(message) {
                    Ok(Some(event)) => {
                        route_control_event(
                            event,
                            &pending_for_reader,
                            &attempts_for_reader,
                            &inbound_tx,
                        )
                        .await;
                    }
                    Ok(None) => {}
                    Err(_) => {
                        reason = "Relay control protocol stream failed".to_string();
                        break;
                    }
                }
            }
            mark_control_disconnected(
                &connected_for_reader,
                &inbound_tx,
                &notified_for_reader,
                &intentional_for_reader,
                &pending_for_reader,
                &attempts_for_reader,
                reason,
            )
            .await;
        }));
        info!("Relay v2 control client connected");
        Ok(ready)
    }

    /// 取出唯一的异步控制面事件接收器。
    pub fn take_events(&mut self) -> Result<mpsc::Receiver<ControlEvent>, RelayError> {
        self.inbound.take().ok_or_else(|| {
            RelayError::Protocol("Relay control events were already consumed".into())
        })
    }

    /// 返回 presence hint 等异步控制面事件流。
    ///
    /// 与 [`Self::take_events`] 等价，是设计 §31 中 `presenceHints` 的入口：
    /// 流上包含 PresenceHintSnapshot / PeerAvailableHint / PeerUnavailableHint、
    /// IncomingRelayReservation 以及被转发的 inbound ConnectivityOffer/Answer 与
    /// RealtimeSignal。
    pub fn presence_hints(&mut self) -> Result<mpsc::Receiver<ControlEvent>, RelayError> {
        self.take_events()
    }

    /// 返回控制面 socket 是否仍可用于新的控制帧。
    pub async fn is_usable(&self) -> bool {
        *self.is_connected.read().await
            && self
                .outbound
                .as_ref()
                .is_some_and(|sender| !sender.is_closed())
    }

    /// 发送一次显式 Heartbeat，并等待对应的 HeartbeatAck 回显 `request_id`。
    pub async fn heartbeat(&self) -> Result<HeartbeatAck, RelayError> {
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::Heartbeat(Heartbeat {
                request_id,
                sent_at_ms: unix_timestamp_ms() as i64,
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::HeartbeatAck(ack) => Ok(ack),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay heartbeat".into(),
            )),
        }
    }

    /// 发布当前设备的 DiscoverySnapshot，等待 server 的 DiscoveryAck（CAS）。
    pub async fn publish_discovery(
        &self,
        snapshot: DiscoverySnapshot,
    ) -> Result<DiscoveryAck, RelayError> {
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::DiscoveryPublish(DiscoveryPublish {
                request_id,
                snapshot: Some(snapshot),
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::DiscoveryAck(ack) => Ok(ack),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay discovery publish".into(),
            )),
        }
    }

    /// 按设备 ID 解析对端当前 Discovery（READY/OFFLINE/NOT_READY/UNKNOWN）。
    pub async fn resolve_peer(
        &self,
        target_device_id: &str,
    ) -> Result<ResolvePeerResponse, RelayError> {
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "resolve target must contain 1-128 characters".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
                request_id,
                target_device_id: target_device_id.to_string(),
            })),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::ResolvePeerResponse(response) => Ok(response),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay resolve".into(),
            )),
        }
    }

    /// 开启一个异步 connectivity attempt，并按 `attempt_id` 关联应答。
    ///
    /// 返回对端的 ConnectivityAnswer（其 `request_id` 是对端自己的，因此本方法
    /// 只依赖 `attempts: HashMap<attempt_id, tracker>` 完成关联）。
    pub async fn start_connectivity_attempt(
        &self,
        attempt_id: String,
        initiator_device_id: String,
        initiator_runtime_epoch: RuntimeEpoch,
        initiator_revision: u32,
        initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> Result<ConnectivityAnswer, RelayError> {
        if attempt_id.is_empty() || attempt_id.len() > MAX_ATTEMPT_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "attempt_id must contain 1-128 characters".into(),
            ));
        }
        if initiator_device_id.is_empty() || initiator_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "initiator device ID is outside protocol bounds".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.attempts.write().await.insert(
            attempt_id.clone(),
            AttemptTracker {
                created_at: Instant::now(),
                response_tx: tx,
            },
        );
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityOffer(ConnectivityOffer {
                request_id,
                attempt_id: attempt_id.clone(),
                initiator_device_id,
                initiator_runtime_epoch: Some(initiator_runtime_epoch),
                initiator_revision,
                initiator_snapshot,
            })),
        };
        if let Err(error) = self.send_frame(&frame).await {
            self.attempts.write().await.remove(&attempt_id);
            return Err(error);
        }
        match tokio::time::timeout(CONNECTIVITY_ATTEMPT_TIMEOUT, rx).await {
            Ok(Ok(ControlEvent::ConnectivityAnswer(answer))) => Ok(answer),
            Ok(Ok(ControlEvent::ProtocolError(error))) => {
                self.attempts.write().await.remove(&attempt_id);
                Err(RelayError::Protocol(error.to_string()))
            }
            Ok(Ok(ControlEvent::Disconnected { .. })) => Err(RelayError::NotConnected),
            Ok(Ok(_)) => {
                self.attempts.write().await.remove(&attempt_id);
                Err(RelayError::Protocol(
                    "unexpected response to connectivity attempt".into(),
                ))
            }
            Ok(Err(_)) => {
                self.attempts.write().await.remove(&attempt_id);
                Err(RelayError::NotConnected)
            }
            Err(_) => {
                self.attempts.write().await.remove(&attempt_id);
                Err(RelayError::Timeout("connectivity attempt timed out".into()))
            }
        }
    }

    /// 发送一个受限的 WebRTC 信令帧（fire-and-forget，不等待应答）。
    pub async fn signal_webrtc(
        &self,
        realtime_id: &str,
        target_device_id: &str,
        kind: RealtimeSignalKind,
        revision: u64,
        payload: &[u8],
    ) -> Result<(), RelayError> {
        if realtime_id.is_empty() || realtime_id.len() > MAX_REALTIME_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "realtime_id must contain 1-128 characters".into(),
            ));
        }
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "WebRTC signal target must contain 1-128 characters".into(),
            ));
        }
        if payload.is_empty() || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "WebRTC signal payload size is outside protocol bounds".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::RealtimeSignal(RealtimeSignal {
                request_id,
                realtime_id: realtime_id.to_string(),
                target_device_id: target_device_id.to_string(),
                kind: kind as i32,
                revision,
                payload: payload.to_vec(),
            })),
        };
        self.send_frame(&frame).await
    }

    /// 请求 Relay 为一条 reservation 分配数据面端点，等待 RelayReserveResponse。
    pub async fn reserve_relay(
        &self,
        attempt_id: &str,
        target_device_id: &str,
        desired_lifetime_s: u32,
    ) -> Result<RelayReserveResponse, RelayError> {
        if attempt_id.is_empty() || attempt_id.len() > MAX_ATTEMPT_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "attempt_id must contain 1-128 characters".into(),
            ));
        }
        if target_device_id.is_empty() || target_device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(RelayError::InvalidConfiguration(
                "reservation target must contain 1-128 characters".into(),
            ));
        }
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::RelayReserveRequest(
                RelayReserveRequest {
                    request_id,
                    attempt_id: attempt_id.to_string(),
                    target_device_id: target_device_id.to_string(),
                    desired_lifetime_s,
                },
            )),
        };
        match self.send_and_await(frame, REQUEST_TIMEOUT).await? {
            ControlEvent::RelayReserveResponse(response) => Ok(response),
            ControlEvent::ProtocolError(error) => Err(RelayError::Protocol(error.to_string())),
            _ => Err(RelayError::Protocol(
                "unexpected response to Relay reservation".into(),
            )),
        }
    }

    /// 应答一个 inbound ConnectivityOffer（应答方视角）。
    pub async fn send_connectivity_answer(
        &self,
        offer: &ConnectivityOffer,
        accepted: bool,
        responder_device_id: &str,
        responder_runtime_epoch: RuntimeEpoch,
        responder_revision: u32,
        responder_snapshot: Option<DiscoverySnapshot>,
    ) -> Result<(), RelayError> {
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer {
                request_id,
                attempt_id: offer.attempt_id.clone(),
                accepted,
                responder_device_id: responder_device_id.to_string(),
                responder_runtime_epoch: Some(responder_runtime_epoch),
                responder_revision,
                responder_snapshot,
            })),
        };
        self.send_frame(&frame).await
    }

    /// 请求关闭控制面 socket 与后台读写 worker。
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
        drain_pending(&self.pending, &self.attempts).await;
        *self.is_connected.write().await = false;
        info!("Relay v2 control client disconnected");
    }

    /// 请求共享控制面客户端主动关闭；适用于运行时保存的 Arc 引用。
    pub async fn request_disconnect(&self) {
        self.intentional_disconnect.store(true, Ordering::Release);
        if let Some(outbound) = self.outbound.as_ref() {
            let _ = outbound
                .send_timeout(Message::Close(None), SOCKET_OPERATION_TIMEOUT)
                .await;
        }
        drain_pending(&self.pending, &self.attempts).await;
        *self.is_connected.write().await = false;
    }

    /// 发送一个 v2 控制帧。
    async fn send_frame(&self, frame: &RelayFrame) -> Result<(), RelayError> {
        let encoded = encode_control_frame(frame)?;
        self.outbound()?
            .send_timeout(Message::Binary(encoded.into()), SOCKET_OPERATION_TIMEOUT)
            .await
            .map_err(|_| RelayError::NotConnected)
    }

    /// 注册 `request_id` 的 oneshot，发送请求并等待应答。
    async fn send_and_await(
        &self,
        frame: RelayFrame,
        timeout: Duration,
    ) -> Result<ControlEvent, RelayError> {
        let request_id = frame_request_id(&frame)
            .ok_or_else(|| RelayError::Protocol("v2 request frame has no request_id".into()))?;
        let (tx, rx) = oneshot::channel();
        self.pending.write().await.insert(request_id, tx);
        if let Err(error) = self.send_frame(&frame).await {
            self.pending.write().await.remove(&request_id);
            return Err(error);
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(ControlEvent::Disconnected { .. })) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::NotConnected)
            }
            Ok(Ok(event)) => {
                self.pending.write().await.remove(&request_id);
                Ok(event)
            }
            Ok(Err(_)) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::NotConnected)
            }
            Err(_) => {
                self.pending.write().await.remove(&request_id);
                Err(RelayError::Timeout(
                    "Relay control request timed out".into(),
                ))
            }
        }
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

/// 校验 Relay v2 Ready 帧的设备绑定和协议版本。
fn validate_ready(message: Message, expected_device_id: &str) -> Result<Ready, RelayError> {
    let Message::Binary(frame) = message else {
        return Err(RelayError::Authentication(
            "Relay v2 ready frame must be a binary protobuf frame".into(),
        ));
    };
    let frame = decode_control_frame(&frame)?;
    let kind = frame.kind.as_ref().ok_or_else(|| {
        RelayError::Authentication("Relay v2 ready frame is missing its message".into())
    })?;
    let relay_frame::Kind::Ready(ready) = kind else {
        return Err(RelayError::Authentication(
            "Relay v2 first frame must be Ready".into(),
        ));
    };
    if frame.version != RELAY_V2_VERSION
        || ready.protocol_version != RELAY_V2_VERSION
        || ready.device_id != expected_device_id
    {
        return Err(RelayError::Authentication(
            "Relay returned an invalid v2 ready frame".into(),
        ));
    }
    Ok(ready.clone())
}

/// 解码一个 Relay v2 控制消息。
fn decode_control_event(message: Message) -> Result<Option<ControlEvent>, RelayError> {
    match message {
        Message::Binary(frame) => {
            let frame = decode_control_frame(&frame)?;
            control_event_from_frame(frame).map(Some)
        }
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        Message::Close(_) => Err(RelayError::Socket("Relay control closed the socket".into())),
        Message::Text(_) | Message::Frame(_) => Err(RelayError::Protocol(
            "Relay v2 control frames must be binary protobuf".into(),
        )),
    }
}

/// 将 v2 控制帧转换为高层面事件，并拒绝方向非法的消息。
fn control_event_from_frame(frame: RelayFrame) -> Result<ControlEvent, RelayError> {
    if frame.version != RELAY_V2_VERSION {
        return Err(RelayError::Protocol(format!(
            "unsupported Relay v2 frame version {}",
            frame.version
        )));
    }
    let kind = frame
        .kind
        .ok_or_else(|| RelayError::Protocol("Relay v2 frame is missing its message kind".into()))?;
    Ok(match kind {
        relay_frame::Kind::Heartbeat(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send Heartbeat frames".into(),
            ))
        }
        relay_frame::Kind::HeartbeatAck(message) => ControlEvent::HeartbeatAck(message),
        relay_frame::Kind::DiscoveryPublish(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send DiscoveryPublish frames".into(),
            ))
        }
        relay_frame::Kind::DiscoveryAck(message) => ControlEvent::DiscoveryAck(message),
        relay_frame::Kind::ResolvePeerRequest(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send ResolvePeerRequest frames".into(),
            ))
        }
        relay_frame::Kind::ResolvePeerResponse(message) => {
            ControlEvent::ResolvePeerResponse(message)
        }
        relay_frame::Kind::ConnectivityOffer(message) => ControlEvent::ConnectivityOffer(message),
        relay_frame::Kind::ConnectivityAnswer(message) => ControlEvent::ConnectivityAnswer(message),
        relay_frame::Kind::PresenceHintSnapshot(message) => {
            ControlEvent::PresenceHintSnapshot(message)
        }
        relay_frame::Kind::PeerAvailableHint(message) => ControlEvent::PeerAvailableHint(message),
        relay_frame::Kind::PeerUnavailableHint(message) => {
            ControlEvent::PeerUnavailableHint(message)
        }
        relay_frame::Kind::RelayReserveRequest(_) => {
            return Err(RelayError::Protocol(
                "Relay server must not send RelayReserveRequest frames".into(),
            ))
        }
        relay_frame::Kind::RelayReserveResponse(message) => {
            ControlEvent::RelayReserveResponse(message)
        }
        relay_frame::Kind::IncomingRelayReservation(message) => {
            ControlEvent::IncomingRelayReservation(message)
        }
        relay_frame::Kind::RealtimeSignal(message) => ControlEvent::RealtimeSignal(message),
        relay_frame::Kind::ProtocolError(message) => ControlEvent::ProtocolError(message),
        relay_frame::Kind::Ready(_) => {
            return Err(RelayError::Protocol(
                "Relay v2 Ready is only valid on the first frame".into(),
            ))
        }
    })
}

/// 判定一个控制事件应投递给哪个关联表。
fn route_action(event: &ControlEvent) -> RouteAction {
    match event {
        ControlEvent::HeartbeatAck(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::DiscoveryAck(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::ResolvePeerResponse(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::RelayReserveResponse(message) => RouteAction::RequestId(message.request_id),
        ControlEvent::ConnectivityAnswer(message) => {
            RouteAction::AttemptId(message.attempt_id.clone())
        }
        ControlEvent::ProtocolError(message) => {
            if message.request_id != 0 {
                RouteAction::RequestId(message.request_id)
            } else if !message.attempt_id.is_empty() {
                RouteAction::AttemptId(message.attempt_id.clone())
            } else {
                RouteAction::Event
            }
        }
        _ => RouteAction::Event,
    }
}

/// 将解码后的控制事件按 `request_id`/`attempt_id` 投递，替代 v1 的全局 Notify。
async fn route_control_event(
    event: ControlEvent,
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &RwLock<HashMap<String, AttemptTracker>>,
    events: &mpsc::Sender<ControlEvent>,
) {
    match route_action(&event) {
        RouteAction::RequestId(request_id) => {
            let sender = pending.write().await.remove(&request_id);
            match sender {
                Some(sender) => {
                    let _ = sender.send(event);
                }
                None => {
                    // 例行的 heartbeat ack 无人等待时静默丢弃，避免污染事件流。
                    if !matches!(event, ControlEvent::HeartbeatAck(_)) {
                        let _ = events.send(event).await;
                    }
                }
            }
        }
        RouteAction::AttemptId(attempt_id) => {
            let tracker = attempts.write().await.remove(&attempt_id);
            match tracker {
                Some(tracker) => {
                    // 过期 attempt 的迟到应答直接丢弃，避免串到同 id 的新 attempt。
                    if tracker.created_at.elapsed() <= CONNECTIVITY_ATTEMPT_TIMEOUT {
                        let _ = tracker.response_tx.send(event);
                    }
                }
                None => {
                    let _ = events.send(event).await;
                }
            }
        }
        RouteAction::Event => {
            let _ = events.send(event).await;
        }
    }
}

/// 将 worker 终止转换为一次性的 Relay v2 断开事件，并失败所有等待方。
async fn mark_control_disconnected(
    connected: &Arc<RwLock<bool>>,
    inbound: &mpsc::Sender<ControlEvent>,
    notified: &Arc<AtomicBool>,
    intentional: &Arc<AtomicBool>,
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &RwLock<HashMap<String, AttemptTracker>>,
    reason: String,
) {
    *connected.write().await = false;
    if !intentional.load(Ordering::Acquire) && !notified.swap(true, Ordering::AcqRel) {
        drain_pending(pending, attempts).await;
        let _ = inbound.send(ControlEvent::Disconnected { reason }).await;
    }
}

/// 失败并清空所有待处理请求/attempt，让等待方快速返回 NotConnected。
async fn drain_pending(
    pending: &RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>,
    attempts: &RwLock<HashMap<String, AttemptTracker>>,
) {
    let mut pending = pending.write().await;
    for (_, sender) in pending.drain() {
        let _ = sender.send(ControlEvent::Disconnected {
            reason: "Relay control socket disconnected".into(),
        });
    }
    drop(pending);
    let mut attempts = attempts.write().await;
    for (_, tracker) in attempts.drain() {
        let _ = tracker.response_tx.send(ControlEvent::Disconnected {
            reason: "Relay control socket disconnected".into(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ready_frame_must_be_binary_and_match_device() {
        let ready = Ready {
            protocol_version: RELAY_V2_VERSION,
            device_id: "device-a".into(),
            server_time_ms: 1723840800123,
            heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
            presence_ttl_s: PRESENCE_TTL_S,
        };
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::Ready(ready.clone())),
        };
        let encoded = encode_control_frame(&frame).expect("encode");
        let message = Message::Binary(encoded.into());
        let validated = validate_ready(message, "device-a").expect("valid ready");
        assert_eq!(validated, ready);

        // 错误设备 ID 必须被拒绝。
        let message = Message::Binary(encode_control_frame(&frame).expect("encode").into());
        assert!(validate_ready(message, "other-device").is_err());
        // 文本帧必须被拒绝。
        assert!(validate_ready(Message::Text("{}".into()), "device-a").is_err());
    }

    #[test]
    fn server_to_client_offers_and_hints_decode_as_events() {
        let offer = ConnectivityOffer {
            request_id: 1001,
            attempt_id: "a1b2c3d4e5f60718293a4b5c6d7e8f90".into(),
            initiator_device_id: "device-a".into(),
            initiator_runtime_epoch: Some(RuntimeEpoch {
                high: 0x6A09E667,
                low: 0xBB67AE85,
            }),
            initiator_revision: 7,
            initiator_snapshot: None,
        };
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityOffer(offer.clone())),
        };
        match control_event_from_frame(frame).expect("event") {
            ControlEvent::ConnectivityOffer(decoded) => assert_eq!(decoded, offer),
            other => panic!("expected ConnectivityOffer, got {other:?}"),
        }

        let hint = PeerUnavailableHint {
            device_id: "device-b".into(),
            reason: "device offline".into(),
        };
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::PeerUnavailableHint(hint.clone())),
        };
        match control_event_from_frame(frame).expect("event") {
            ControlEvent::PeerUnavailableHint(decoded) => assert_eq!(decoded, hint),
            other => panic!("expected PeerUnavailableHint, got {other:?}"),
        }
    }

    #[test]
    fn control_frame_version_must_be_two() {
        let frame = RelayFrame {
            version: 1,
            kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck {
                request_id: 1,
                server_time_ms: 0,
            })),
        };
        assert!(encode_control_frame(&frame).is_err());
    }

    #[tokio::test]
    async fn request_id_response_is_routed_to_the_matching_oneshot() {
        let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let attempts: Arc<RwLock<HashMap<String, AttemptTracker>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let (events_tx, mut events_rx) = mpsc::channel(4);

        let (tx, rx) = oneshot::channel();
        pending.write().await.insert(42, tx);

        let response = ResolvePeerResponse {
            request_id: 42,
            status: ResolveStatus::Ready as i32,
            discovery: None,
            retry_after_ms: 0,
        };
        route_control_event(
            ControlEvent::ResolvePeerResponse(response.clone()),
            &pending,
            &attempts,
            &events_tx,
        )
        .await;

        assert_eq!(
            rx.await.expect("oneshot resolved"),
            ControlEvent::ResolvePeerResponse(response)
        );
        assert!(pending.read().await.is_empty());
        assert!(events_rx.try_recv().is_err(), "no fallback event expected");
    }

    #[tokio::test]
    async fn attempt_id_response_is_routed_by_attempt_tracker() {
        let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let attempts: Arc<RwLock<HashMap<String, AttemptTracker>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let (events_tx, _events_rx) = mpsc::channel(4);

        let attempt_id = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
        let (tx, rx) = oneshot::channel();
        attempts.write().await.insert(
            attempt_id.to_string(),
            AttemptTracker {
                created_at: Instant::now(),
                response_tx: tx,
            },
        );

        let answer = ConnectivityAnswer {
            request_id: 2002,
            attempt_id: attempt_id.to_string(),
            accepted: true,
            responder_device_id: "device-b".into(),
            responder_runtime_epoch: None,
            responder_revision: 3,
            responder_snapshot: None,
        };
        route_control_event(
            ControlEvent::ConnectivityAnswer(answer.clone()),
            &pending,
            &attempts,
            &events_tx,
        )
        .await;

        assert_eq!(
            rx.await.expect("attempt resolved"),
            ControlEvent::ConnectivityAnswer(answer)
        );
        assert!(attempts.read().await.is_empty());
    }

    #[tokio::test]
    async fn async_events_fall_through_to_the_event_stream() {
        let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let attempts: Arc<RwLock<HashMap<String, AttemptTracker>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let (events_tx, mut events_rx) = mpsc::channel(4);

        let hint = PeerUnavailableHint {
            device_id: "device-b".into(),
            reason: "offline".into(),
        };
        route_control_event(
            ControlEvent::PeerUnavailableHint(hint.clone()),
            &pending,
            &attempts,
            &events_tx,
        )
        .await;

        assert_eq!(
            events_rx.recv().await.expect("async event"),
            ControlEvent::PeerUnavailableHint(hint)
        );
    }

    #[tokio::test]
    async fn protocol_error_with_request_id_fails_that_request() {
        let pending: Arc<RwLock<HashMap<u64, oneshot::Sender<ControlEvent>>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let attempts: Arc<RwLock<HashMap<String, AttemptTracker>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let (events_tx, _events_rx) = mpsc::channel(4);

        let (tx, rx) = oneshot::channel();
        pending.write().await.insert(7, tx);

        let error = ProtocolError {
            request_id: 7,
            attempt_id: String::new(),
            code: ErrorCode::EpochConflict as i32,
            message: "revision already published".into(),
        };
        route_control_event(
            ControlEvent::ProtocolError(error.clone()),
            &pending,
            &attempts,
            &events_tx,
        )
        .await;

        match rx.await.expect("oneshot resolved") {
            ControlEvent::ProtocolError(decoded) => assert_eq!(decoded, error),
            other => panic!("expected ProtocolError, got {other:?}"),
        }
    }

    #[test]
    fn request_and_attempt_ids_are_extracted_from_frames() {
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ResolvePeerRequest(ResolvePeerRequest {
                request_id: 1001,
                target_device_id: "device-b".into(),
            })),
        };
        assert_eq!(frame_request_id(&frame), Some(1001));

        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer {
                request_id: 2002,
                attempt_id: "attempt-1".into(),
                accepted: true,
                responder_device_id: "device-b".into(),
                responder_runtime_epoch: None,
                responder_revision: 3,
                responder_snapshot: None,
            })),
        };
        assert_eq!(frame_request_id(&frame), Some(2002));
        match frame.kind.as_ref().expect("kind") {
            relay_frame::Kind::ConnectivityAnswer(answer) => {
                assert_eq!(answer.attempt_id, "attempt-1");
            }
            other => panic!("expected ConnectivityAnswer, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn validation_rejects_out_of_bounds_identifiers() {
        let client = RelayControlClient::new(
            "https://relay.example.test".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("client");
        assert!(matches!(
            client.resolve_peer("").await,
            Err(RelayError::InvalidConfiguration(_))
        ));
        assert!(matches!(
            client
                .resolve_peer("x".repeat(MAX_DEVICE_ID_BYTES + 1).as_str())
                .await,
            Err(RelayError::InvalidConfiguration(_))
        ));
        // 未连接时，合法请求在出站队列阶段返回 NotConnected。
        assert!(matches!(
            client.resolve_peer("device-b").await,
            Err(RelayError::NotConnected)
        ));
    }
}
