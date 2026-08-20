//! ReliableStream byte-stream carrier (design §17 ReliableStream / §21 SSH).
//!
//! A ConnectionSession carries multiple logical byte streams multiplexed over
//! one framed carrier:
//! - Generic routes (TCP / Relay): `StreamOpen`/`StreamBytes`/`StreamClose`
//!   frames (`connection.rs` `GenericFrameKind`).
//! - QUIC direct: one real bidirectional QUIC stream per logical stream, so
//!   SSH bytes ride on a genuine QUIC stream without re-framing.
//!
//! The peer that receives a stream whose service hint is `ssh` bridges the
//! stream bytes to a local TCP sshd socket (option B of the SSH design): a
//! native gateway task pumps bytes between the native stream and the local
//! socket. There is zero SSH protocol code in the native runtime.
//!
//! Backpressure: the generic writer already blocks on the bounded route
//! channel (`GENERIC_ROUTE_CHANNEL_CAPACITY`); a stream send therefore awaits
//! the bounded native send and never drops. The receive path buffers per
//! stream (bounded at `MAX_PER_STREAM_BUFFER_CAPACITY`) and blocks the writer
//! while a consumer drains, for every consumer mode: Bridge/Poll consumers
//! drain through `receive_stream`, and Event-mode streams drain through a
//! per-stream emitter task that turns the buffered bytes into
//! `SshStreamDataReceived` events. An SSH burst therefore cannot grow memory
//! without bound or be silently discarded.

#[cfg(test)]
use network_protocol::{network_event, NetworkEvent};
use network_protocol::{
    CommunicationClass, NetworkError as ProtocolError, NetworkErrorCode, SshStreamCloseCommand,
    SshStreamDataCommand, SshStreamOpenCommand, StreamHandle,
};
use quinn::SendStream;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{watch, Mutex};

use crate::channel::{select_business_path_lease, send_business_frame};
use crate::connect::{PathLease, CAPABILITY_RELIABLE_STREAM};
use crate::connection::GenericFrameKind;
use crate::connection::RouteTransport;
use crate::events::{emit_stream_closed, emit_stream_data_received, protocol_error_with_peer};
use crate::runtime::{EventSender, RuntimeState};

// ---------------------------------------------------------------------------
// Centralized constants (design §39: no magic numbers)
// ---------------------------------------------------------------------------

/// Service hint for the SSH gateway (design §21 option B: bridge to sshd).
pub(crate) const STREAM_SERVICE_SSH: &str = "ssh";
/// Local host the SSH gateway connects to.
pub(crate) const STREAM_LOCAL_HOST: &str = "127.0.0.1";
/// Local OS sshd port the SSH gateway bridges to (desktop sshd).
pub(crate) const STREAM_LOCAL_SSH_PORT: u16 = 22;
/// Maximum data bytes carried by one generic StreamBytes frame.
pub(crate) const MAX_STREAM_FRAME_BYTES: usize = 64 * 1024;
/// Per-stream receive buffer cap; the reader blocks while a consumer drains.
pub(crate) const MAX_PER_STREAM_BUFFER_CAPACITY: usize = 256 * 1024;
/// Maximum concurrent byte streams per peer.
pub(crate) const MAX_CONCURRENT_STREAMS: usize = 32;
/// Maximum service-hint length in bytes.
pub(crate) const MAX_SERVICE_BYTES: usize = 128;

/// Frozen ReliableStream identity. The opener device is part of the key so a
/// numeric stream ID can safely be reused by the two peers.
#[allow(dead_code)]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct ReliableStreamIdentity {
    pub peer_id: String,
    pub opener_device_id: String,
    pub stream_id: u16,
}

impl ReliableStreamIdentity {
    #[allow(dead_code)]
    pub(crate) fn new(
        peer_id: impl Into<String>,
        opener_device_id: impl Into<String>,
        stream_id: u16,
    ) -> Result<Self, StreamError> {
        let identity = Self {
            peer_id: peer_id.into(),
            opener_device_id: opener_device_id.into(),
            stream_id,
        };
        if identity.peer_id.is_empty()
            || identity.opener_device_id.is_empty()
            || identity.stream_id == 0
        {
            return Err(StreamError::InvalidArgument);
        }
        Ok(identity)
    }
}

#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReliableStreamLifecycle {
    Open,
    Closed,
}
/// Chunk size for the gateway socket pump.
pub(crate) const STREAM_SOCKET_CHUNK_BYTES: usize = 16 * 1024;
/// QUIC bidi preamble magic; distinguishes reliable streams from file offers
/// (file offers use `SMFT`) on the shared `accept_bi` loop.
pub(crate) const STREAM_QUIC_PREAMBLE_MAGIC: [u8; 4] = *b"SMSS";
/// File offer magic mirrored from `network_quic::file_stream` for dispatch.
pub(crate) const FILE_OFFER_MAGIC: [u8; 4] = *b"SMFT";
/// Generic stream frame header: opener_len(u8) + opener bytes +
/// stream_id(u16) + the frame-specific fields.  The opener is carried on
/// every frame because bytes flow in both directions on one logical stream;
/// transport direction alone is not enough to disambiguate two peers opening
/// the same stream_id at the same time.
const STREAM_OPENER_LENGTH_BYTES: usize = 1;
const STREAM_ID_BYTES: usize = 2;
const STREAM_GENERIC_BYTES_HEADER_BYTES: usize =
    STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES + 8 + 4;
const STREAM_GENERIC_OPEN_HEADER_BYTES: usize = STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES + 2;
const STREAM_GENERIC_CLOSE_HEADER_BYTES: usize = STREAM_OPENER_LENGTH_BYTES + STREAM_ID_BYTES;

// ---------------------------------------------------------------------------
// Stream errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub(crate) enum StreamError {
    #[error("stream is not open")]
    NotFound,
    #[error("stream is already open")]
    AlreadyOpen,
    #[error("stream is closed")]
    Closed,
    #[error("stream frame is invalid")]
    InvalidFrame,
    #[error("stream argument is invalid")]
    InvalidArgument,
    #[error("stream capacity exceeded")]
    CapacityExceeded,
    #[error("peer is not connected")]
    NotConnected,
    #[error("current route does not support byte streams")]
    #[allow(dead_code)] // retained for the public stream error taxonomy
    UnsupportedTransport,
    #[error("route send failed: {0}")]
    Send(String),
}

impl StreamError {
    fn into_protocol(self, peer_id: &str, operation: &str) -> ProtocolError {
        let code = if matches!(self, StreamError::InvalidArgument) {
            NetworkErrorCode::InvalidArgument
        } else {
            NetworkErrorCode::IoError
        };
        protocol_error_with_peer(code, self.to_string(), operation, peer_id)
    }
}

// ---------------------------------------------------------------------------
// Wire encoders / decoders (generic-route frames and QUIC preamble)
// ---------------------------------------------------------------------------

fn append_stream_opener(out: &mut Vec<u8>, opener_peer_id: &str) -> Result<(), StreamError> {
    if opener_peer_id.is_empty() || opener_peer_id.len() > 128 {
        return Err(StreamError::InvalidArgument);
    }
    out.push(opener_peer_id.len() as u8);
    out.extend_from_slice(opener_peer_id.as_bytes());
    Ok(())
}

fn decode_stream_opener(payload: &[u8], cursor: &mut usize) -> Result<String, StreamError> {
    if payload.len() < *cursor + STREAM_OPENER_LENGTH_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let opener_len = payload[*cursor] as usize;
    *cursor += STREAM_OPENER_LENGTH_BYTES;
    if opener_len == 0 || opener_len > 128 || payload.len() < *cursor + opener_len {
        return Err(StreamError::InvalidFrame);
    }
    let opener = std::str::from_utf8(&payload[*cursor..*cursor + opener_len])
        .map_err(|_| StreamError::InvalidFrame)?
        .to_string();
    *cursor += opener_len;
    Ok(opener)
}

pub(crate) fn encode_stream_bytes_frame(
    opener_peer_id: &str,
    stream_id: u16,
    seq: u64,
    data: &[u8],
) -> Result<Vec<u8>, StreamError> {
    if data.is_empty() {
        return Err(StreamError::InvalidArgument);
    }
    let mut out =
        Vec::with_capacity(STREAM_GENERIC_BYTES_HEADER_BYTES + opener_peer_id.len() + data.len());
    append_stream_opener(&mut out, opener_peer_id)?;
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
    Ok(out)
}

pub(crate) fn decode_stream_bytes_frame(
    payload: &[u8],
) -> Result<(String, u16, u64, &[u8]), StreamError> {
    if payload.len() < STREAM_GENERIC_BYTES_HEADER_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let mut cursor = 0;
    let opener = decode_stream_opener(payload, &mut cursor)?;
    if payload.len() < cursor + STREAM_ID_BYTES + 8 + 4 {
        return Err(StreamError::InvalidFrame);
    }
    let stream_id = u16::from_be_bytes(
        payload[cursor..cursor + STREAM_ID_BYTES]
            .try_into()
            .expect("stream_id bytes"),
    );
    cursor += STREAM_ID_BYTES;
    let seq = u64::from_be_bytes(payload[cursor..cursor + 8].try_into().expect("seq bytes"));
    cursor += 8;
    let len =
        u32::from_be_bytes(payload[cursor..cursor + 4].try_into().expect("len bytes")) as usize;
    cursor += 4;
    if len == 0 || cursor + len != payload.len() {
        return Err(StreamError::InvalidFrame);
    }
    Ok((opener, stream_id, seq, &payload[cursor..cursor + len]))
}

pub(crate) fn encode_stream_open_frame(
    opener_peer_id: &str,
    stream_id: u16,
    service: &str,
) -> Result<Vec<u8>, StreamError> {
    if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
        return Err(StreamError::InvalidArgument);
    }
    let mut out =
        Vec::with_capacity(STREAM_GENERIC_OPEN_HEADER_BYTES + opener_peer_id.len() + service.len());
    append_stream_opener(&mut out, opener_peer_id)?;
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&(service.len() as u16).to_be_bytes());
    out.extend_from_slice(service.as_bytes());
    Ok(out)
}

pub(crate) fn decode_stream_open_frame(
    payload: &[u8],
) -> Result<(String, u16, String), StreamError> {
    if payload.len() < STREAM_GENERIC_OPEN_HEADER_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let mut cursor = 0;
    let opener = decode_stream_opener(payload, &mut cursor)?;
    if payload.len() < cursor + STREAM_ID_BYTES + 2 {
        return Err(StreamError::InvalidFrame);
    }
    let stream_id = u16::from_be_bytes(
        payload[cursor..cursor + STREAM_ID_BYTES]
            .try_into()
            .expect("stream_id bytes"),
    );
    cursor += STREAM_ID_BYTES;
    let service_len = u16::from_be_bytes(
        payload[cursor..cursor + 2]
            .try_into()
            .expect("service_len bytes"),
    ) as usize;
    cursor += 2;
    if service_len == 0 || service_len > MAX_SERVICE_BYTES || cursor + service_len != payload.len()
    {
        return Err(StreamError::InvalidFrame);
    }
    let service = std::str::from_utf8(&payload[cursor..cursor + service_len])
        .map_err(|_| StreamError::InvalidFrame)?
        .to_string();
    Ok((opener, stream_id, service))
}

pub(crate) fn encode_stream_close_frame(
    opener_peer_id: &str,
    stream_id: u16,
) -> Result<Vec<u8>, StreamError> {
    let mut out = Vec::with_capacity(STREAM_GENERIC_CLOSE_HEADER_BYTES + opener_peer_id.len());
    append_stream_opener(&mut out, opener_peer_id)?;
    out.extend_from_slice(&stream_id.to_be_bytes());
    Ok(out)
}

pub(crate) fn decode_stream_close_frame(payload: &[u8]) -> Result<(String, u16), StreamError> {
    if payload.len() < STREAM_GENERIC_CLOSE_HEADER_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let mut cursor = 0;
    let opener = decode_stream_opener(payload, &mut cursor)?;
    if payload.len() != cursor + STREAM_ID_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let stream_id = u16::from_be_bytes(
        payload[cursor..cursor + STREAM_ID_BYTES]
            .try_into()
            .expect("close stream_id bytes"),
    );
    Ok((opener, stream_id))
}

/// Extracts the stable `(opener_peer_id, stream_id)` identity from any stream
/// frame. Relay uses the same identity to validate its opaque token before
/// dispatching the frame to the stream manager.
pub(crate) fn decode_stream_frame_identity(
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(String, u16), StreamError> {
    match kind {
        GenericFrameKind::StreamOpen => {
            let (opener, stream_id, _) = decode_stream_open_frame(payload)?;
            Ok((opener, stream_id))
        }
        GenericFrameKind::StreamBytes => {
            let (opener, stream_id, _, _) = decode_stream_bytes_frame(payload)?;
            Ok((opener, stream_id))
        }
        GenericFrameKind::StreamClose => decode_stream_close_frame(payload),
        _ => Err(StreamError::InvalidFrame),
    }
}

pub(crate) fn encode_quic_stream_preamble(
    stream_id: u16,
    service: &str,
) -> Result<Vec<u8>, StreamError> {
    if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
        return Err(StreamError::InvalidArgument);
    }
    let mut out = Vec::with_capacity(8 + service.len());
    out.extend_from_slice(&STREAM_QUIC_PREAMBLE_MAGIC);
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&(service.len() as u16).to_be_bytes());
    out.extend_from_slice(service.as_bytes());
    Ok(out)
}

/// Reads the remainder of a QUIC bidi preamble after the four magic bytes have
/// already been consumed by the bidi dispatcher.
pub(crate) async fn read_quic_stream_preamble_after_magic(
    receive: &mut quinn::RecvStream,
) -> Result<(u16, String), StreamError> {
    let stream_id = receive
        .read_u16()
        .await
        .map_err(|_| StreamError::InvalidFrame)?;
    let service_len = receive
        .read_u16()
        .await
        .map_err(|_| StreamError::InvalidFrame)? as usize;
    if service_len == 0 || service_len > MAX_SERVICE_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let mut service = vec![0u8; service_len];
    receive
        .read_exact(&mut service)
        .await
        .map_err(|_| StreamError::InvalidFrame)?;
    let service = String::from_utf8(service).map_err(|_| StreamError::InvalidFrame)?;
    Ok((stream_id, service))
}

/// Relay 路由的流令牌：稳定绑定 opener peer 与 stream_id，避免两个方向
/// 同时使用同一逻辑 id 时共享数据面 token。
pub(crate) fn stream_relay_token(opener_peer_id: &str, stream_id: u16) -> String {
    format!("stream:{opener_peer_id}:{stream_id}")
}

// ---------------------------------------------------------------------------
// Per-stream receive/send state
// ---------------------------------------------------------------------------

/// How a stream's inbound bytes are consumed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StreamConsumer {
    /// Delivered as `SshStreamDataReceived` events (FFI client mode).
    Event,
    /// Buffered and drained by a native bridge task (gateway to sshd).
    Bridge,
    /// Buffered and drained by `receive_stream` (programmatic API).
    #[allow(dead_code)] // programmatic API consumer; exercised by tests
    Poll,
}

struct StreamEntry {
    consumer: StreamConsumer,
    recv_chunks: VecDeque<Vec<u8>>,
    recv_bytes: usize,
    recv_closed: bool,
    next_recv_seq: u64,
    /// 唤醒广播源（代次计数器）。watch 保存值：等待者必须在锁内订阅，
    /// 这样「条件检查 + 订阅」与生产者改动是原子临界区，检查-等待间隙里
    /// 的唤醒不会丢失（修复 `Notify` lost-wakeup 导致的背压 writer 永久
    /// 阻塞）。`watch::Sender` 不可 Clone，故保存在 entry 上，等待者通过
    /// `subscribe()` 派生 Receiver。
    wake_tx: watch::Sender<u64>,
    wake_gen: u64,
    quic_send: Option<SendStream>,
    next_send_seq: u64,
    send_closed: bool,
    send_lock: Arc<Mutex<()>>,
    /// One business path reservation held from StreamOpen through StreamClose.
    /// It is never replaced by a later path/session selection.
    path_lease: Option<PathLease>,
}

impl StreamEntry {
    /// 唤醒所有等待者。必须持锁调用（生产者改动状态后）：自增代次并广播，
    /// watch 保存最新代次，因此即使等待者尚未 poll，其 `changed()` 也会在
    /// 下一次 poll 时立即返回，而不是像 `Notify::notify_waiters()` 那样不带
    /// 许可地把唤醒丢掉。
    fn wake(&mut self) {
        self.wake_gen += 1;
        let _ = self.wake_tx.send(self.wake_gen);
    }

    /// 在锁内订阅最新代次（与条件检查同属一个临界区，生产者无法插入），
    /// 返回 Receiver 后即可在锁外 `changed().await` 等待下一次状态变化。
    fn wait_rx(&self) -> watch::Receiver<u64> {
        self.wake_tx.subscribe()
    }
}

#[derive(Default)]
struct StreamState {
    streams: HashMap<StreamKey, StreamEntry>,
    /// Stream identities retired by a Session teardown.  Keeping tombstones
    /// in the per-peer manager prevents an old FFI handle from addressing a
    /// newly-created stream with the same opener/id after reconnect.
    retired: HashSet<StreamKey>,
}

const MAX_RETIRED_STREAM_KEYS: usize = 131_072;

/// Direction-independent logical stream opener.  A per-peer manager has one
/// local device and one authenticated remote peer, so Local/Remote is the
/// compact representation of the opener peer id used on the wire.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum StreamOpener {
    Local,
    Remote,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct StreamKey {
    opener: StreamOpener,
    stream_id: u16,
}

impl StreamKey {
    fn new(opener: StreamOpener, stream_id: u16) -> Self {
        Self { opener, stream_id }
    }
}

/// Cloneable per-peer owner of every byte-stream receive buffer and QUIC send
/// half. The generic route receiver, QUIC bidi receivers, FFI commands and the
/// gateway bridge all share one manager per peer.
#[derive(Clone)]
pub(crate) struct ReliableStreamManager {
    inner: Arc<Mutex<StreamState>>,
    event_tx: EventSender,
}

impl ReliableStreamManager {
    pub(crate) fn new<S: Into<EventSender>>(event_tx: S) -> Self {
        Self {
            inner: Arc::new(Mutex::new(StreamState::default())),
            event_tx: event_tx.into(),
        }
    }

    pub(crate) async fn active_count(&self) -> u32 {
        self.inner.lock().await.streams.len().min(u32::MAX as usize) as u32
    }

    pub(crate) async fn open(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        service: &str,
        consumer: StreamConsumer,
    ) -> Result<(), StreamError> {
        if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
            return Err(StreamError::InvalidArgument);
        }
        let mut state = self.inner.lock().await;
        if state.streams.len() >= MAX_CONCURRENT_STREAMS {
            return Err(StreamError::CapacityExceeded);
        }
        let key = StreamKey::new(opener, stream_id);
        if state.streams.contains_key(&key) {
            return Err(StreamError::AlreadyOpen);
        }
        if state.retired.contains(&key) {
            return Err(StreamError::Closed);
        }
        if state.retired.len() >= MAX_RETIRED_STREAM_KEYS {
            return Err(StreamError::CapacityExceeded);
        }
        let (wake_tx, _) = watch::channel(0u64);
        state.streams.insert(
            key,
            StreamEntry {
                consumer,
                recv_chunks: VecDeque::new(),
                recv_bytes: 0,
                recv_closed: false,
                next_recv_seq: 0,
                wake_tx,
                wake_gen: 0,
                quic_send: None,
                next_send_seq: 0,
                send_closed: false,
                send_lock: Arc::new(Mutex::new(())),
                path_lease: None,
            },
        );
        Ok(())
    }

    /// Stores the one path lease that belongs to this stream's entire
    /// Open..Close lifetime.
    pub(crate) async fn bind_lease(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        lease: PathLease,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.path_lease.is_some() {
            return Err(StreamError::AlreadyOpen);
        }
        entry.path_lease = Some(lease);
        Ok(())
    }

    async fn take_lease(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<PathLease, StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        entry.path_lease.take().ok_or(StreamError::NotConnected)
    }

    async fn restore_lease(&self, opener: StreamOpener, stream_id: u16, lease: PathLease) -> bool {
        let mut state = self.inner.lock().await;
        let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
            return false;
        };
        if entry.recv_closed || entry.path_lease.is_some() {
            return false;
        }
        entry.path_lease = Some(lease);
        true
    }

    #[cfg(test)]
    async fn has_lease(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .is_some_and(|entry| entry.path_lease.is_some())
    }

    pub(crate) async fn register_quic_send(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        send: SendStream,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        entry.quic_send = Some(send);
        Ok(())
    }

    /// Acquires the per-stream send mutex so a full send operation (generic
    /// frame sequence or QUIC write) is not interleaved with another caller.
    pub(crate) async fn send_guard(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<Arc<Mutex<()>>, StreamError> {
        let state = self.inner.lock().await;
        let entry = state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(Arc::clone(&entry.send_lock))
    }

    pub(crate) async fn next_send_seq(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<u64, StreamError> {
        let state = self.inner.lock().await;
        let entry = state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(entry.next_send_seq)
    }

    pub(crate) async fn bump_send_seq(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        count: u64,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&StreamKey::new(opener, stream_id))
            .ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        entry.next_send_seq += count;
        Ok(())
    }

    /// Writes raw bytes to a QUIC stream send half. The per-stream send guard
    /// must be held by the caller so the `take`/`put-back` cannot race.
    pub(crate) async fn quic_send_bytes(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        data: &[u8],
    ) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&StreamKey::new(opener, stream_id))
                .ok_or(StreamError::NotFound)?;
            if entry.send_closed {
                return Err(StreamError::Closed);
            }
            entry.quic_send.take().ok_or(StreamError::Closed)?
        };
        let result = send.write_all(data).await;
        // The peer closing the stream aborts the write; that resolves to an
        // error and we drop the dead stream half.
        let mut state = self.inner.lock().await;
        if let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) {
            if entry.send_closed {
                return Err(StreamError::Closed);
            }
            if result.is_ok() {
                entry.quic_send = Some(send);
            }
        }
        result.map_err(|_| StreamError::Closed)
    }

    /// Finishes the QUIC send half (graceful close of our write side).
    pub(crate) async fn quic_finish_send(
        &self,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&StreamKey::new(opener, stream_id))
                .ok_or(StreamError::NotFound)?;
            if entry.send_closed {
                return Ok(());
            }
            entry.quic_send.take().ok_or(StreamError::Closed)?
        };
        let _ = send.finish();
        Ok(())
    }

    /// Inbound StreamBytes data. Every consumer mode buffers the bytes in a
    /// per-stream buffer bounded at `MAX_PER_STREAM_BUFFER_CAPACITY` and blocks
    /// the writer (backpressure) while the buffer is full, so a flooding peer
    /// cannot grow memory without bound. Event-mode bytes are drained by the
    /// per-stream emitter task into `SshStreamDataReceived` events; Bridge/Poll
    /// bytes are drained by the reader.
    pub(crate) async fn handle_bytes(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
        seq: u64,
        data: Vec<u8>,
    ) -> Result<(), StreamError> {
        let _ = peer_id; // 事件由 drainer 发出；此处仅缓冲，不直接用 peer_id。
        let data_len = data.len();
        // 阶段一：有界缓冲 + 背压（所有消费者模式一致）。缓冲区满时阻塞 writer。
        let after = loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let entry = state
                    .streams
                    .get_mut(&StreamKey::new(opener, stream_id))
                    .ok_or(StreamError::NotFound)?;
                if entry.recv_closed || entry.send_closed {
                    // Late packet racing the close: drop, not an error.
                    return Ok(());
                }
                if seq != entry.next_recv_seq {
                    if seq < entry.next_recv_seq {
                        return Ok(()); // duplicate retransmission
                    }
                    return Err(StreamError::InvalidFrame); // gap on an ordered carrier
                }
                if entry.recv_bytes + data_len <= MAX_PER_STREAM_BUFFER_CAPACITY {
                    entry.next_recv_seq += 1;
                    entry.recv_bytes += data_len;
                    let after = entry.recv_bytes;
                    entry.recv_chunks.push_back(data);
                    entry.wake();
                    break after;
                }
                Some(entry.wait_rx())
            };
            // 订阅与条件检查同临界区：锁释放后即便生产者已 drain，watch 也
            // 保存了最新代次，`changed()` 立即返回；错误（sender 已丢）则
            // 重查，entry 已被移除时会得到 NotFound。
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        };
        // 阶段二（仅 Event 模式）：等待 drainer 把本块转成事件（缓冲降到
        // appended 之后）。这样事件顺序与帧处理顺序一致，且 drainer 慢/停时
        // writer 立即获得背压，而不是逐帧直接灌入无界事件通道。
        loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
                    return Ok(());
                };
                if entry.consumer != StreamConsumer::Event || entry.recv_bytes < after {
                    return Ok(());
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    /// Event-mode drainer: pops buffered chunks and emits `SshStreamDataReceived`
    /// events, then emits `SshStreamClosed` after the receive side is closed and
    /// the buffer is empty (so data events always precede the close event). This
    /// is the Event-mode consumer — without it the writer would block forever at
    /// `MAX_PER_STREAM_BUFFER_CAPACITY`. 设计 §17：Event 流与 Bridge/Poll 共享
    /// 同一有界缓冲区与背压；本任务把缓冲字节转成事件，而不是逐帧直接灌入
    /// 无界事件通道。
    pub(crate) async fn drain_events(
        self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
        opener_device_id: &str,
    ) {
        loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let Some(entry) = state.streams.get_mut(&StreamKey::new(opener, stream_id)) else {
                    return;
                };
                if let Some(chunk) = entry.recv_chunks.pop_front() {
                    entry.recv_bytes -= chunk.len();
                    emit_stream_data_received(
                        &self.event_tx,
                        peer_id,
                        opener_device_id,
                        stream_id,
                        &chunk,
                    );
                    entry.wake();
                    continue;
                }
                if entry.recv_closed {
                    // 缓冲区已空且对端关闭：最后发出 close 事件，保证 data 先于 close。
                    drop(state);
                    emit_stream_closed(&self.event_tx, peer_id, opener_device_id, stream_id);
                    return;
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    /// Inbound StreamOpen: register the remote-opened stream.
    pub(crate) async fn handle_open(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        service: &str,
        consumer: StreamConsumer,
    ) -> Result<(), StreamError> {
        self.open(opener, stream_id, service, consumer).await
    }

    /// Inbound StreamClose / QUIC EOF: mark the receive side closed and wake
    /// consumers. Bridge/Poll consumers observe EOF through `receive` returning
    /// 0; the Event-mode `SshStreamClosed` event is emitted by the per-stream
    /// drainer after the buffer is emptied, so data events always precede the
    /// close event (设计 §17 顺序保证).
    pub(crate) async fn handle_close(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        {
            let mut state = self.inner.lock().await;
            let key = StreamKey::new(opener, stream_id);
            let Some(entry) = state.streams.get_mut(&key) else {
                return Ok(());
            };
            if entry.recv_closed {
                return Ok(());
            }
            entry.recv_closed = true;
            entry.wake();
            if entry.send_closed {
                state.streams.remove(&key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(key);
                }
            }
        }
        let _ = peer_id;
        Ok(())
    }

    /// Local close: mark the send side closed and remove the entry once both
    /// sides are finished. The local caller initiated the close so no event is
    /// emitted here; the app was already told when the peer closed (Event mode)
    /// or the bridge/API consumer observed EOF.
    pub(crate) async fn close_local(
        &self,
        peer_id: &str,
        opener: StreamOpener,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        let removed = {
            let mut state = self.inner.lock().await;
            let key = StreamKey::new(opener, stream_id);
            let Some(entry) = state.streams.get_mut(&key) else {
                return Ok(());
            };
            if entry.send_closed {
                return Ok(());
            }
            entry.send_closed = true;
            entry.wake();
            let removed = entry.recv_closed;
            if removed {
                state.streams.remove(&key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(key);
                }
            }
            removed
        };
        let _ = removed;
        let _ = peer_id;
        Ok(())
    }

    /// Drains buffered bytes for a Bridge/Poll consumer, spanning chunk
    /// boundaries so the caller receives a contiguous byte run. Returns 0 on
    /// EOF.
    pub(crate) async fn receive(
        &self,
        opener: StreamOpener,
        stream_id: u16,
        buf: &mut [u8],
    ) -> Result<usize, StreamError> {
        loop {
            let wait = {
                let mut state = self.inner.lock().await;
                let entry = state
                    .streams
                    .get_mut(&StreamKey::new(opener, stream_id))
                    .ok_or(StreamError::NotFound)?;
                if entry.consumer == StreamConsumer::Event {
                    return Err(StreamError::InvalidArgument);
                }
                let mut filled = 0usize;
                while filled < buf.len() {
                    let Some(chunk) = entry.recv_chunks.front() else {
                        break;
                    };
                    let take = chunk.len().min(buf.len() - filled);
                    buf[filled..filled + take].copy_from_slice(&chunk[..take]);
                    filled += take;
                    if take == chunk.len() {
                        entry.recv_chunks.pop_front();
                    } else {
                        let remaining = chunk[take..].to_vec();
                        entry.recv_chunks.pop_front();
                        entry.recv_chunks.push_front(remaining);
                    }
                }
                if filled > 0 {
                    entry.recv_bytes -= filled;
                    entry.wake();
                    return Ok(filled);
                }
                if entry.recv_closed {
                    return Ok(0);
                }
                Some(entry.wait_rx())
            };
            if let Some(mut rx) = wait {
                let _ = rx.changed().await;
            }
        }
    }

    #[allow(dead_code)] // test/diagnostic query surface
    pub(crate) async fn is_open(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .contains_key(&StreamKey::new(opener, stream_id))
    }

    #[allow(dead_code)] // test/diagnostic query surface
    pub(crate) async fn is_recv_closed(&self, opener: StreamOpener, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .is_some_and(|e| e.recv_closed)
    }

    /// 诊断/测试查询面：返回该流当前缓冲的字节数，用于断言背压下有界性。
    #[cfg(test)]
    async fn buffered_bytes(&self, opener: StreamOpener, stream_id: u16) -> Option<usize> {
        let state = self.inner.lock().await;
        state
            .streams
            .get(&StreamKey::new(opener, stream_id))
            .map(|entry| entry.recv_bytes)
    }

    /// Session teardown: close every stream for the peer. Returns the ids so
    /// the caller can emit closed events.
    pub(crate) async fn close_all(
        &self,
        peer_id: &str,
        local_opener_device_id: &str,
    ) -> Vec<(StreamOpener, u16)> {
        let ids = {
            let mut state = self.inner.lock().await;
            let ids: Vec<(StreamOpener, u16)> = state
                .streams
                .keys()
                .map(|key| (key.opener, key.stream_id))
                .collect();
            let retired_keys = state.streams.keys().copied().collect::<Vec<_>>();
            state.retired.extend(retired_keys);
            state.streams.clear();
            ids
        };
        for (opener, stream_id) in &ids {
            let opener_device_id = match opener {
                StreamOpener::Local => local_opener_device_id,
                StreamOpener::Remote => peer_id,
            };
            emit_stream_closed(&self.event_tx, peer_id, opener_device_id, *stream_id);
        }
        ids
    }

    /// Revoke streams whose retained path lease has been hard-closed. Normal
    /// retirement leaves the lease active, so existing streams are not
    /// interrupted and new opens are rejected by path selection.
    #[allow(dead_code)]
    pub(crate) async fn close_inactive(
        &self,
        peer_id: &str,
        local_opener_device_id: &str,
    ) -> Vec<(StreamOpener, u16)> {
        let ids = {
            let mut state = self.inner.lock().await;
            let ids = state
                .streams
                .iter()
                .filter_map(|(key, entry)| {
                    entry
                        .path_lease
                        .as_ref()
                        .is_some_and(|lease| !lease.is_active())
                        .then_some(*key)
                })
                .collect::<Vec<_>>();
            for key in &ids {
                state.streams.remove(key);
                if state.retired.len() < MAX_RETIRED_STREAM_KEYS {
                    state.retired.insert(*key);
                }
            }
            ids.into_iter()
                .map(|key| (key.opener, key.stream_id))
                .collect::<Vec<_>>()
        };
        for (opener, stream_id) in &ids {
            let opener_device_id = match opener {
                StreamOpener::Local => local_opener_device_id,
                StreamOpener::Remote => peer_id,
            };
            emit_stream_closed(&self.event_tx, peer_id, opener_device_id, *stream_id);
        }
        ids
    }
}

// ---------------------------------------------------------------------------
// RuntimeState-level byte-stream operations
// ---------------------------------------------------------------------------

fn validate_peer(peer_id: &str) -> bool {
    !peer_id.is_empty() && peer_id.len() <= 128
}

async fn local_stream_opener_peer_id(state: &Arc<RuntimeState>) -> Result<String, StreamError> {
    state
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or(StreamError::NotConnected)
}

async fn stream_opener_peer_id(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
) -> Result<String, StreamError> {
    match opener {
        StreamOpener::Local => local_stream_opener_peer_id(state).await,
        StreamOpener::Remote => Ok(peer_id.to_string()),
    }
}

/// Resolves the opener for an FFI command from its explicit business handle.
/// A command can target either a locally opened stream or a stream opened by the
/// remote peer; the handle, never stream existence order, selects the namespace.
async fn command_stream_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
) -> Result<(StreamOpener, u16), StreamError> {
    if !validate_peer(&handle.opener_device_id) {
        return Err(StreamError::InvalidArgument);
    }
    let stream_id = u16::try_from(handle.stream_id).map_err(|_| StreamError::InvalidArgument)?;
    if stream_id == 0 {
        return Err(StreamError::InvalidArgument);
    }
    let local_peer_id = local_stream_opener_peer_id(state).await?;
    let opener = if handle.opener_device_id == local_peer_id {
        StreamOpener::Local
    } else if handle.opener_device_id == peer_id {
        StreamOpener::Remote
    } else {
        return Err(StreamError::InvalidArgument);
    };
    let manager = state.stream_manager(peer_id).await;
    if manager.is_open(opener, stream_id).await {
        Ok((opener, stream_id))
    } else {
        Err(StreamError::NotFound)
    }
}

async fn inbound_stream_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener_peer_id: &str,
) -> Result<StreamOpener, StreamError> {
    let local_peer_id = local_stream_opener_peer_id(state).await?;
    if opener_peer_id == local_peer_id {
        Ok(StreamOpener::Local)
    } else if opener_peer_id == peer_id {
        Ok(StreamOpener::Remote)
    } else {
        Err(StreamError::InvalidFrame)
    }
}

async fn close_stream_after_path_loss(
    manager: &ReliableStreamManager,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) -> StreamError {
    // SSH/ReliableStream has no transparent recovery. Mark both halves closed
    // and wake the consumer so the application can explicitly open a new
    // logical stream after it has decided to reconnect.
    let _ = manager.handle_close(peer_id, opener, stream_id).await;
    let _ = manager.close_local(peer_id, opener, stream_id).await;
    StreamError::Closed
}

async fn bind_inbound_attempt(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    manager: &ReliableStreamManager,
    opener: StreamOpener,
    stream_id: u16,
) -> Result<(), StreamError> {
    let lease = match select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_STREAM).await {
        Ok(lease) => lease,
        Err(_) => {
            return Err(close_stream_after_path_loss(manager, peer_id, opener, stream_id).await)
        }
    };
    if !lease.is_active() {
        return Err(StreamError::NotConnected);
    }
    manager.bind_lease(opener, stream_id, lease).await
}

/// Opens a byte stream to a peer. `consumer` selects how inbound bytes are
/// delivered (events / bridge / poll).
pub(crate) async fn open_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    service: &str,
    consumer: StreamConsumer,
) -> Result<(), StreamError> {
    crate::transfer::ensure_business_path(
        state,
        peer_id,
        &format!("stream-{stream_id}"),
        CommunicationClass::ReliableStream,
        CAPABILITY_RELIABLE_STREAM,
    )
    .await
    .map_err(|_| StreamError::NotConnected)?;
    let lease = select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_STREAM)
        .await
        .map_err(|_| StreamError::NotConnected)?;
    let opener_peer_id = local_stream_opener_peer_id(state).await?;
    let manager = state.stream_manager(peer_id).await;
    // Reserve the lease before emitting any wire bytes.  This prevents a
    // stale handle from sending StreamOpen on a new Session before the
    // manager rejects its retired identity.
    manager
        .open(StreamOpener::Local, stream_id, service, consumer)
        .await?;
    manager
        .bind_lease(StreamOpener::Local, stream_id, lease)
        .await?;
    // Keep the lease in the entry between operations; temporarily borrow it
    // only while the opening frame is written.
    let lease = manager.take_lease(StreamOpener::Local, stream_id).await?;
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            async {
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                let connection = state
                    .path_connection_for_lease(&lease)
                    .await
                    .ok_or(StreamError::NotConnected)?;
                let (mut send, recv) = connection
                    .open_bi()
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                let preamble = encode_quic_stream_preamble(stream_id, service)?;
                send.write_all(&preamble)
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                send.flush()
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                if !lease.is_active() {
                    return Err(StreamError::Closed);
                }
                manager
                    .register_quic_send(StreamOpener::Local, stream_id, send)
                    .await?;
                spawn_quic_stream_reader(state, peer_id, StreamOpener::Local, stream_id, recv)
                    .await;
                Ok(())
            }
            .await
        }
        _ => {
            async {
                let payload = encode_stream_open_frame(&opener_peer_id, stream_id, service)?;
                send_business_frame(
                    state,
                    peer_id,
                    &lease,
                    &stream_relay_token(&opener_peer_id, stream_id),
                    GenericFrameKind::StreamOpen,
                    &payload,
                )
                .await
                .map_err(|error| StreamError::Send(error.to_string()))
            }
            .await
        }
    };
    if let Err(error) = result {
        let _ =
            close_stream_after_path_loss(&manager, peer_id, StreamOpener::Local, stream_id).await;
        drop(lease);
        return Err(error);
    }
    if !manager
        .restore_lease(StreamOpener::Local, stream_id, lease)
        .await
    {
        let _ =
            close_stream_after_path_loss(&manager, peer_id, StreamOpener::Local, stream_id).await;
        return Err(StreamError::Closed);
    }
    if consumer == StreamConsumer::Event {
        spawn_stream_event_emitter(state, peer_id, StreamOpener::Local, stream_id).await;
    }
    Ok(())
}

/// Sends bytes on a byte stream. The generic route splits into bounded
/// StreamBytes frames and awaits the bounded route send (never drops); the
/// QUIC route writes raw bytes on the real QUIC stream.
pub(crate) async fn send_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
    data: &[u8],
) -> Result<(), StreamError> {
    let (opener, stream_id) = command_stream_opener(state, peer_id, handle).await?;
    send_stream_with_opener(state, peer_id, opener, stream_id, data).await
}

async fn send_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    data: &[u8],
) -> Result<(), StreamError> {
    if data.is_empty() {
        return Ok(());
    }
    let manager = state.stream_manager(peer_id).await;
    let opener_peer_id = stream_opener_peer_id(state, peer_id, opener).await?;
    let send_guard = manager.send_guard(opener, stream_id).await?;
    let _guard = send_guard.lock().await;
    let lease = match manager.take_lease(opener, stream_id).await {
        Ok(lease) => lease,
        Err(error) => {
            let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
            return Err(error);
        }
    };
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            if !lease.is_active() {
                Err(StreamError::Closed)
            } else {
                manager.quic_send_bytes(opener, stream_id, data).await
            }
        }
        _ => {
            async {
                let seq = manager.next_send_seq(opener, stream_id).await?;
                let mut chunks = 0u64;
                for chunk in data.chunks(MAX_STREAM_FRAME_BYTES) {
                    let payload =
                        encode_stream_bytes_frame(&opener_peer_id, stream_id, seq + chunks, chunk)?;
                    send_business_frame(
                        state,
                        peer_id,
                        &lease,
                        &stream_relay_token(&opener_peer_id, stream_id),
                        GenericFrameKind::StreamBytes,
                        &payload,
                    )
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                    chunks += 1;
                }
                manager.bump_send_seq(opener, stream_id, chunks).await?;
                Ok(())
            }
            .await
        }
    };
    if !lease.is_active() {
        drop(lease);
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(StreamError::Closed);
    }
    if let Err(error) = result {
        drop(lease);
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(error);
    }
    if !manager.restore_lease(opener, stream_id, lease).await {
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(StreamError::Closed);
    }
    Ok(())
}

/// Drains buffered bytes for a Bridge/Poll consumer.
#[allow(dead_code)]
pub(crate) async fn receive_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    receive_stream_with_opener(state, peer_id, StreamOpener::Local, stream_id, buf).await
}

async fn receive_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    let manager = state.stream_manager(peer_id).await;
    manager.receive(opener, stream_id, buf).await
}

/// Closes a byte stream locally and tells the peer.
pub(crate) async fn close_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    handle: &StreamHandle,
) -> Result<(), StreamError> {
    let (opener, stream_id) = command_stream_opener(state, peer_id, handle).await?;
    close_stream_with_opener(state, peer_id, opener, stream_id).await
}

async fn close_stream_with_opener(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) -> Result<(), StreamError> {
    let manager = state.stream_manager(peer_id).await;
    let opener_peer_id = stream_opener_peer_id(state, peer_id, opener).await?;
    let lease = match manager.take_lease(opener, stream_id).await {
        Ok(lease) => lease,
        Err(error) => {
            let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
            return Err(error);
        }
    };
    let result = match lease.profile().transport() {
        RouteTransport::Quic => {
            if !lease.is_active() {
                Err(StreamError::Closed)
            } else {
                manager.quic_finish_send(opener, stream_id).await
            }
        }
        _ => {
            async {
                let payload = encode_stream_close_frame(&opener_peer_id, stream_id)?;
                send_business_frame(
                    state,
                    peer_id,
                    &lease,
                    &stream_relay_token(&opener_peer_id, stream_id),
                    GenericFrameKind::StreamClose,
                    &payload,
                )
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
                Ok(())
            }
            .await
        }
    };
    if !lease.is_active() || result.is_err() {
        drop(lease);
        return Err(close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await);
    }
    // A graceful local close keeps the reservation if the receive half is
    // still draining; the final remote close drops it.
    manager.close_local(peer_id, opener, stream_id).await?;
    let _ = manager.restore_lease(opener, stream_id, lease).await;
    Ok(())
}

/// Routes an inbound generic stream frame (from the generic-route receiver or
/// the relay channel receiver) to the per-stream reassembly buffer. A malformed
/// stream frame fails that stream only; it never tears down the route.
pub(crate) async fn handle_inbound_stream_frame(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(), StreamError> {
    match kind {
        GenericFrameKind::StreamOpen => {
            let (opener_peer_id, stream_id, service) = decode_stream_open_frame(payload)?;
            if inbound_stream_opener(state, peer_id, &opener_peer_id).await? != StreamOpener::Remote
            {
                return Err(StreamError::InvalidFrame);
            }
            handle_inbound_open(state, peer_id, StreamOpener::Remote, stream_id, &service).await
        }
        GenericFrameKind::StreamBytes => {
            let (opener_peer_id, stream_id, seq, data) = decode_stream_bytes_frame(payload)?;
            let opener = inbound_stream_opener(state, peer_id, &opener_peer_id).await?;
            let manager = state.stream_manager(peer_id).await;
            manager
                .handle_bytes(peer_id, opener, stream_id, seq, data.to_vec())
                .await
        }
        GenericFrameKind::StreamClose => {
            let (opener_peer_id, stream_id) = decode_stream_close_frame(payload)?;
            let opener = inbound_stream_opener(state, peer_id, &opener_peer_id).await?;
            let manager = state.stream_manager(peer_id).await;
            manager.handle_close(peer_id, opener, stream_id).await
        }
        _ => Err(StreamError::InvalidFrame),
    }
}

/// Handles an inbound stream open. A stream whose service hint is `ssh`
/// activates the native gateway-to-sshd bridge on this peer; any other service
/// is delivered to the app as events.
async fn handle_inbound_open(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    service: &str,
) -> Result<(), StreamError> {
    let consumer = if service == STREAM_SERVICE_SSH {
        StreamConsumer::Bridge
    } else {
        StreamConsumer::Event
    };
    let manager = state.stream_manager(peer_id).await;
    match manager
        .handle_open(opener, stream_id, service, consumer)
        .await
    {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 同一 stream_id 的重复 open：丢弃这个重复的 open，已存在的活动流
            // 保持原样。绝不能调用 handle_close——那会把现有活动流的接收侧
            // 标记关闭，拆掉一条活着的 SSH 会话（修复 #5）。
            return Ok(());
        }
        Err(error) => return Err(error),
    }
    if let Err(error) = bind_inbound_attempt(state, peer_id, &manager, opener, stream_id).await {
        let _ = close_stream_after_path_loss(&manager, peer_id, opener, stream_id).await;
        return Err(error);
    }
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(Arc::clone(state), peer_id.to_string(), opener, stream_id);
    } else {
        spawn_stream_event_emitter(state, peer_id, opener, stream_id).await;
    }
    Ok(())
}

/// Handles an inbound QUIC bidi reliable stream (preamble already read by the
/// shared `accept_bi` loop). Registers the stream, pumps the peer's write half
/// into the reassembly buffer, and activates the SSH gateway when the service
/// hint is `ssh`.
pub(crate) async fn handle_incoming_quic_stream(
    state: Arc<RuntimeState>,
    peer_id: String,
    stream_id: u16,
    service: String,
    send: quinn::SendStream,
    receive: quinn::RecvStream,
) {
    let consumer = if service == STREAM_SERVICE_SSH {
        StreamConsumer::Bridge
    } else {
        StreamConsumer::Event
    };
    let manager = state.stream_manager(&peer_id).await;
    match manager
        .handle_open(StreamOpener::Remote, stream_id, &service, consumer)
        .await
    {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 重复 open：丢弃这个重复的 QUIC 流，已存在的活动流保持原样，
            // 绝不能 handle_close 掉现有流（修复 #5）。
            return;
        }
        Err(_) => return,
    }
    if bind_inbound_attempt(&state, &peer_id, &manager, StreamOpener::Remote, stream_id)
        .await
        .is_err()
    {
        let _ =
            close_stream_after_path_loss(&manager, &peer_id, StreamOpener::Remote, stream_id).await;
        return;
    }
    if manager
        .register_quic_send(StreamOpener::Remote, stream_id, send)
        .await
        .is_err()
    {
        let _ = manager
            .handle_close(&peer_id, StreamOpener::Remote, stream_id)
            .await;
        return;
    }
    spawn_quic_stream_reader(&state, &peer_id, StreamOpener::Remote, stream_id, receive).await;
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(state, peer_id, StreamOpener::Remote, stream_id);
    } else {
        spawn_stream_event_emitter(&state, &peer_id, StreamOpener::Remote, stream_id).await;
    }
}

// ---------------------------------------------------------------------------
// QUIC stream reader pump, Event-mode drainer and the SSH gateway bridge
// ---------------------------------------------------------------------------

/// 启动 Event-mode 流的 per-stream drainer 任务（设计 §17）：把有界缓冲区里
/// 的入站字节转成 `SshStreamDataReceived` 事件。Event 流因此与 Bridge/Poll
/// 共享同一有界缓冲区与背压——writer 在 `MAX_PER_STREAM_BUFFER_CAPACITY`
/// 处阻塞，而不是逐帧直接灌入无界事件通道。
async fn spawn_stream_event_emitter(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
) {
    let opener_device_id = match opener {
        StreamOpener::Local => match local_stream_opener_peer_id(state).await {
            Ok(device_id) => device_id,
            Err(_) => return,
        },
        StreamOpener::Remote => peer_id.to_string(),
    };
    let manager = state.stream_manager(peer_id).await;
    let peer_id = peer_id.to_string();
    let task_key = format!("stream:{peer_id}:{stream_id}");
    let _ = state
        .task_supervisor
        .spawn_session(task_key, "stream-event-emitter", async move {
            manager
                .drain_events(&peer_id, opener, stream_id, &opener_device_id)
                .await
        });
}

/// Pumps a QUIC `RecvStream` (the peer's write half of a logical byte stream)
/// into the per-stream reassembly buffer.
pub(crate) async fn spawn_quic_stream_reader(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    opener: StreamOpener,
    stream_id: u16,
    mut recv: quinn::RecvStream,
) {
    let state = Arc::clone(state);
    let peer_id = peer_id.to_string();
    let task_key = format!("stream:{peer_id}:{stream_id}");
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_session(task_key, "reliable-stream-reader", async move {
        let manager = state.stream_manager(&peer_id).await;
        let mut buf = vec![0u8; MAX_STREAM_FRAME_BYTES];
        let mut seq = 0u64;
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) => {
                    let data = buf[..n].to_vec();
                    let _ = manager
                        .handle_bytes(&peer_id, opener, stream_id, seq, data)
                        .await;
                    seq += 1;
                }
                Ok(None) | Err(_) => {
                    let _ = manager.handle_close(&peer_id, opener, stream_id).await;
                    return;
                }
            }
        }
    });
}

/// The SSH Server Service (design §21 option B): bridges a native byte stream
/// whose service hint is `ssh` to a local TCP sshd socket. Zero SSH protocol
/// code; the bridge just pumps bytes both ways.
pub(crate) fn spawn_ssh_gateway(
    state: Arc<RuntimeState>,
    peer_id: String,
    opener: StreamOpener,
    stream_id: u16,
) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_runtime("ssh-gateway", async move {
        let gateway_port = state
            .stream_gateway_port
            .load(std::sync::atomic::Ordering::Acquire);
        let address = format!("{STREAM_LOCAL_HOST}:{gateway_port}");
        let socket = match TcpStream::connect(address.as_str()).await {
            Ok(socket) => socket,
            Err(error) => {
                tracing::warn!(
                    peer_id = %peer_id,
                    stream_id,
                    %error,
                    "SSH gateway could not connect to local sshd"
                );
                let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
                return;
            }
        };
        let (mut read_half, mut write_half) = socket.into_split();

        // socket -> native stream
        let socket_to_stream = tokio::spawn({
            let state = Arc::clone(&state);
            let peer_id = peer_id.clone();
            async move {
                let mut buf = vec![0u8; STREAM_SOCKET_CHUNK_BYTES];
                loop {
                    match read_half.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if send_stream_with_opener(
                                &state,
                                &peer_id,
                                opener,
                                stream_id,
                                &buf[..n],
                            )
                            .await
                            .is_err()
                            {
                                break;
                            }
                        }
                    }
                }
                let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
            }
        });

        // native stream -> socket
        let stream_to_socket = tokio::spawn({
            let state = Arc::clone(&state);
            let peer_id = peer_id.clone();
            async move {
                let mut buf = vec![0u8; STREAM_SOCKET_CHUNK_BYTES];
                loop {
                    match receive_stream_with_opener(&state, &peer_id, opener, stream_id, &mut buf)
                        .await
                    {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if write_half.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = write_half.shutdown().await;
            }
        });

        let _ = tokio::join!(socket_to_stream, stream_to_socket);
        let _ = close_stream_with_opener(&state, &peer_id, opener, stream_id).await;
    });
}

// ---------------------------------------------------------------------------
// FFI command handlers
// ---------------------------------------------------------------------------

fn parse_stream_handle(
    handle: Option<StreamHandle>,
    peer_id: &str,
    operation: &str,
) -> Result<(StreamHandle, u16), ProtocolError> {
    let handle = handle.ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "handle is required",
            operation,
            peer_id,
        )
    })?;
    if !validate_peer(&handle.opener_device_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "handle.opener_device_id must contain 1-128 characters",
            operation,
            peer_id,
        ));
    }
    let stream_id = u16::try_from(handle.stream_id).map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "handle.stream_id must be in 1..=65535",
            operation,
            peer_id,
        )
    })?;
    if stream_id == 0 {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "handle.stream_id must be non-zero",
            operation,
            peer_id,
        ));
    }
    Ok((handle, stream_id))
}

pub(crate) async fn handle_ssh_stream_open(
    state: Arc<RuntimeState>,
    command: SshStreamOpenCommand,
) -> Result<(), ProtocolError> {
    if !validate_peer(&command.peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
            "ssh_stream_open",
            &command.peer_id,
        ));
    }
    if command.service.is_empty() || command.service.len() > MAX_SERVICE_BYTES {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "service must contain 1-128 characters",
            "ssh_stream_open",
            &command.peer_id,
        ));
    }
    let (handle, stream_id) =
        parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_open")?;
    let local_opener_device_id = local_stream_opener_peer_id(&state)
        .await
        .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_open"))?;
    if handle.opener_device_id != local_opener_device_id {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "ssh stream open handle must identify the local opener",
            "ssh_stream_open",
            &command.peer_id,
        ));
    }
    open_stream(
        &state,
        &command.peer_id,
        stream_id,
        &command.service,
        StreamConsumer::Event,
    )
    .await
    .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_open"))
}

pub(crate) async fn handle_ssh_stream_data(
    state: Arc<RuntimeState>,
    command: SshStreamDataCommand,
) -> Result<(), ProtocolError> {
    if !validate_peer(&command.peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
            "ssh_stream_data",
            &command.peer_id,
        ));
    }
    let (handle, _) = parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_data")?;
    send_stream(&state, &command.peer_id, &handle, &command.data)
        .await
        .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_data"))
}

pub(crate) async fn handle_ssh_stream_close(
    state: Arc<RuntimeState>,
    command: SshStreamCloseCommand,
) -> Result<(), ProtocolError> {
    if !validate_peer(&command.peer_id) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
            "ssh_stream_close",
            &command.peer_id,
        ));
    }
    let (handle, _) = parse_stream_handle(command.handle, &command.peer_id, "ssh_stream_close")?;
    close_stream(&state, &command.peer_id, &handle)
        .await
        .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_close"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::{PathRegistry, PeerId, PeerPathManager};
    use crate::connection::{ConnectionProfile, Route, RouteTransport};
    use std::sync::Mutex as StdMutex;
    use tokio::sync::mpsc;

    fn ready_stream_path() -> (
        Arc<PathRegistry>,
        PeerPathManager,
        crate::connect::PathHandle,
    ) {
        let registry = Arc::new(PathRegistry::new());
        let mut paths =
            PeerPathManager::new(PeerId::new("peer-a").expect("peer"), Arc::clone(&registry));
        let handle = paths
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
            .expect("ready path");
        (registry, paths, handle)
    }

    #[tokio::test]
    async fn stream_auto_ensures_reliable_stream() {
        let (event_tx, _event_rx) = mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let registry = Arc::new(PathRegistry::new());
        let mut paths =
            PeerPathManager::new(PeerId::new("peer-a").expect("peer"), Arc::clone(&registry));
        paths
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
            .expect("ready path");
        state
            .peer_path_managers
            .write()
            .await
            .insert("peer-a".to_string(), Arc::new(StdMutex::new(paths)));
        crate::transfer::ensure_business_path(
            &state,
            "peer-a",
            "stream-7",
            CommunicationClass::ReliableStream,
            CAPABILITY_RELIABLE_STREAM,
        )
        .await
        .expect("stream should ensure a reliable stream path");
    }

    #[test]
    fn stream_identity_isolated_by_peer_and_opener() {
        let first = ReliableStreamIdentity::new("peer-a", "device-a", 7).expect("identity");
        let second = ReliableStreamIdentity::new("peer-b", "device-a", 7).expect("identity");
        let third = ReliableStreamIdentity::new("peer-a", "device-b", 7).expect("identity");
        assert_ne!(first, second);
        assert_ne!(first, third);
        assert!(ReliableStreamIdentity::new("peer-a", "device-a", 0).is_err());
    }

    #[tokio::test]
    async fn path_loss_closes_stream_instead_of_rebinding_it() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 9, "ssh", StreamConsumer::Poll)
            .await
            .expect("open");
        assert!(matches!(
            close_stream_after_path_loss(&manager, "peer-a", StreamOpener::Local, 9).await,
            StreamError::Closed
        ));
        assert!(!manager.is_open(StreamOpener::Local, 9).await);
        assert!(matches!(
            manager
                .open(StreamOpener::Local, 9, "ssh", StreamConsumer::Poll)
                .await,
            Err(StreamError::Closed)
        ));
    }

    #[tokio::test]
    async fn stream_holds_lease_until_close() {
        let (registry, _paths, handle) = ready_stream_path();
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 10, "ssh", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .bind_lease(
                StreamOpener::Local,
                10,
                registry.acquire(&handle).expect("stream lease"),
            )
            .await
            .expect("bind lease");
        assert!(manager.has_lease(StreamOpener::Local, 10).await);
        manager
            .handle_close("peer-a", StreamOpener::Local, 10)
            .await
            .expect("peer close");
        manager
            .close_local("peer-a", StreamOpener::Local, 10)
            .await
            .expect("local close");
        assert!(!manager.has_lease(StreamOpener::Local, 10).await);
    }

    #[tokio::test]
    async fn normal_retire_waits_for_stream() {
        let (registry, mut paths, handle) = ready_stream_path();
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 11, "ssh", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .bind_lease(
                StreamOpener::Local,
                11,
                registry.acquire(&handle).expect("stream lease"),
            )
            .await
            .expect("bind lease");
        paths.normal_drain();
        assert!(manager.has_lease(StreamOpener::Local, 11).await);
        assert!(
            registry.acquire(&handle).is_err(),
            "new streams are rejected"
        );
        manager.close_all("peer-a", "local-a").await;
        assert!(!manager.is_open(StreamOpener::Local, 11).await);
    }

    #[tokio::test]
    async fn hard_close_closes_stream() {
        let (registry, mut paths, handle) = ready_stream_path();
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 12, "ssh", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .bind_lease(
                StreamOpener::Local,
                12,
                registry.acquire(&handle).expect("stream lease"),
            )
            .await
            .expect("bind lease");
        paths.hard_close();
        let closed = manager.close_inactive("peer-a", "local-a").await;
        assert_eq!(closed, vec![(StreamOpener::Local, 12)]);
        assert!(!manager.is_open(StreamOpener::Local, 12).await);
    }

    #[tokio::test]
    async fn stream_does_not_transparently_migrate() {
        let (registry, mut paths, old_handle) = ready_stream_path();
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 13, "ssh", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .bind_lease(
                StreamOpener::Local,
                13,
                registry.acquire(&old_handle).expect("old lease"),
            )
            .await
            .expect("bind old lease");
        registry.drain(&old_handle);
        let new_handle = paths
            .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
            .expect("new path");
        assert_ne!(old_handle, new_handle);
        assert!(manager.has_lease(StreamOpener::Local, 13).await);
        assert!(registry.acquire(&new_handle).is_ok());
        // The existing stream retained the old lease; it was not rebound to the
        // newly published path.
        assert!(manager.has_lease(StreamOpener::Local, 13).await);
    }

    fn test_manager() -> (ReliableStreamManager, mpsc::UnboundedReceiver<NetworkEvent>) {
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        (ReliableStreamManager::new(event_tx), event_rx)
    }

    #[test]
    fn stream_wire_frames_round_trip() {
        let data = encode_stream_bytes_frame("peer-a", 7, 3, b"hello").expect("encode bytes");
        let (opener, stream_id, seq, payload) =
            decode_stream_bytes_frame(&data).expect("decode bytes");
        assert_eq!((opener.as_str(), stream_id, seq), ("peer-a", 7, 3));
        assert_eq!(payload, b"hello");

        let open = encode_stream_open_frame("peer-a", 7, "ssh").expect("encode open");
        let (opener, stream_id, service) = decode_stream_open_frame(&open).expect("decode open");
        assert_eq!(
            (opener.as_str(), stream_id, service.as_str()),
            ("peer-a", 7, "ssh")
        );

        let close = encode_stream_close_frame("peer-a", 7).expect("encode close");
        assert_eq!(
            decode_stream_close_frame(&close).expect("decode close"),
            ("peer-a".to_string(), 7)
        );
        assert_eq!(stream_relay_token("peer-a", 7), "stream:peer-a:7");
        assert!(decode_stream_open_frame(b"\x00\x01\xff").is_err());
        assert!(decode_stream_bytes_frame(&[0u8; 8]).is_err());
    }

    #[tokio::test]
    async fn same_stream_id_isolated_by_opener_direction() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 1, "local", StreamConsumer::Poll)
            .await
            .expect("local open");
        manager
            .open(StreamOpener::Remote, 1, "remote", StreamConsumer::Poll)
            .await
            .expect("remote open");

        manager
            .handle_bytes("peer-a", StreamOpener::Local, 1, 0, b"from-local".to_vec())
            .await
            .expect("local bytes");
        manager
            .handle_bytes(
                "peer-a",
                StreamOpener::Remote,
                1,
                0,
                b"from-remote".to_vec(),
            )
            .await
            .expect("remote bytes");

        let mut buf = [0u8; 32];
        let n = manager
            .receive(StreamOpener::Local, 1, &mut buf)
            .await
            .expect("local receive");
        assert_eq!(&buf[..n], b"from-local");
        let n = manager
            .receive(StreamOpener::Remote, 1, &mut buf)
            .await
            .expect("remote receive");
        assert_eq!(&buf[..n], b"from-remote");
        assert!(manager.is_open(StreamOpener::Local, 1).await);
        assert!(manager.is_open(StreamOpener::Remote, 1).await);
    }

    #[tokio::test]
    async fn session_teardown_retires_stream_identity_across_reconnect() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 7, "ssh", StreamConsumer::Poll)
            .await
            .expect("initial stream open");
        let closed = manager.close_all("peer-a", "local-a").await;
        assert_eq!(closed, vec![(StreamOpener::Local, 7)]);

        // The same logical handle cannot silently attach to a new Session.
        // A fresh stream id remains available, so reconnect is not globally
        // blocked while the old stream lease is retired.
        assert!(matches!(
            manager
                .open(StreamOpener::Local, 7, "ssh", StreamConsumer::Poll)
                .await,
            Err(StreamError::Closed)
        ));
        manager
            .open(StreamOpener::Local, 8, "ssh", StreamConsumer::Poll)
            .await
            .expect("new stream identity remains available");
    }

    #[tokio::test]
    async fn inbound_frames_route_same_id_by_wire_opener() {
        let (event_tx, _event_rx) = mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        *state.identity.write().await = Some(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "local-a".into(),
                [1u8; 32],
                [2u8; 32],
            ),
        ));
        let peer_id = "peer-b";
        let manager = state.stream_manager(peer_id).await;
        manager
            .open(StreamOpener::Local, 1, "local", StreamConsumer::Poll)
            .await
            .expect("local open");
        manager
            .open(StreamOpener::Remote, 1, "remote", StreamConsumer::Poll)
            .await
            .expect("remote open");

        let local_frame =
            encode_stream_bytes_frame("local-a", 1, 0, b"local-bytes").expect("encode local frame");
        handle_inbound_stream_frame(&state, peer_id, GenericFrameKind::StreamBytes, &local_frame)
            .await
            .expect("route local opener");
        let remote_frame = encode_stream_bytes_frame("peer-b", 1, 0, b"remote-bytes")
            .expect("encode remote frame");
        handle_inbound_stream_frame(
            &state,
            peer_id,
            GenericFrameKind::StreamBytes,
            &remote_frame,
        )
        .await
        .expect("route remote opener");

        let mut buf = [0u8; 32];
        let n = manager
            .receive(StreamOpener::Local, 1, &mut buf)
            .await
            .expect("receive local opener");
        assert_eq!(&buf[..n], b"local-bytes");
        let n = manager
            .receive(StreamOpener::Remote, 1, &mut buf)
            .await
            .expect("receive remote opener");
        assert_eq!(&buf[..n], b"remote-bytes");
    }

    #[test]
    fn quic_preamble_round_trip_and_dispatch_magic() {
        let preamble = encode_quic_stream_preamble(9, "ssh").expect("encode preamble");
        assert_eq!(&preamble[..4], &STREAM_QUIC_PREAMBLE_MAGIC);
        assert_ne!(&preamble[..4], &FILE_OFFER_MAGIC);
    }

    #[tokio::test]
    async fn event_consumer_emits_data_and_close() {
        let (manager, mut event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 1, "custom", StreamConsumer::Event)
            .await
            .expect("open");
        // Event-mode bytes are buffered and delivered by the drainer task.
        let drainer = {
            let manager = manager.clone();
            tokio::spawn(async move {
                manager
                    .drain_events("peer-a", StreamOpener::Local, 1, "local-device")
                    .await
            })
        };
        manager
            .handle_bytes("peer-a", StreamOpener::Local, 1, 0, b"ping".to_vec())
            .await
            .expect("bytes");
        let event = event_rx.recv().await.expect("data event");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "peer-a" && recv.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 1) && recv.data == b"ping"
        ));
        manager
            .handle_close("peer-a", StreamOpener::Local, 1)
            .await
            .expect("close");
        let event = event_rx.recv().await.expect("close event");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamClosed(closed)) if closed.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 1)
        ));
        // The drainer exits after it emits the close event.
        tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
            .await
            .expect("drainer did not exit after close")
            .expect("drainer panicked");
    }

    #[tokio::test]
    async fn poll_consumer_buffers_until_read_and_reports_eof() {
        let (manager, mut event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 2, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .handle_bytes("peer-a", StreamOpener::Local, 2, 0, b"abc".to_vec())
            .await
            .expect("bytes");
        manager
            .handle_bytes("peer-a", StreamOpener::Local, 2, 1, b"de".to_vec())
            .await
            .expect("bytes");

        let mut buf = [0u8; 2];
        let n = manager
            .receive(StreamOpener::Local, 2, &mut buf)
            .await
            .expect("receive");
        assert_eq!((n, &buf[..n]), (2, &b"ab"[..]));
        let n = manager
            .receive(StreamOpener::Local, 2, &mut buf)
            .await
            .expect("receive");
        assert_eq!((n, &buf[..n]), (2, &b"cd"[..]));
        let n = manager
            .receive(StreamOpener::Local, 2, &mut buf)
            .await
            .expect("receive");
        assert_eq!((n, &buf[..n]), (1, &b"e"[..]));

        manager
            .handle_close("peer-a", StreamOpener::Local, 2)
            .await
            .expect("close");
        let n = manager
            .receive(StreamOpener::Local, 2, &mut buf)
            .await
            .expect("receive after close");
        assert_eq!(n, 0);
        // close_local removes the entry once both sides closed.
        manager
            .close_local("peer-a", StreamOpener::Local, 2)
            .await
            .expect("close local");
        assert!(!manager.is_open(StreamOpener::Local, 2).await);
        // Event channel was unused for the poll consumer.
        assert!(event_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn data_after_close_is_dropped_not_an_error() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 3, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .handle_close("peer-a", StreamOpener::Local, 3)
            .await
            .expect("close");
        // A late packet racing the close must not be treated as a fatal error.
        assert!(manager
            .handle_bytes("peer-a", StreamOpener::Local, 3, 0, b"late".to_vec())
            .await
            .is_ok());
    }

    #[tokio::test]
    async fn duplicate_and_gap_sequence_handling() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 4, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .handle_bytes("peer-a", StreamOpener::Local, 4, 0, b"a".to_vec())
            .await
            .expect("first");
        // Duplicate seq 0 is dropped silently.
        assert!(manager
            .handle_bytes("peer-a", StreamOpener::Local, 4, 0, b"dup".to_vec())
            .await
            .is_ok());
        // Gap (seq 2 after seq 0) is a protocol error for that stream only.
        assert!(matches!(
            manager
                .handle_bytes("peer-a", StreamOpener::Local, 4, 2, b"gap".to_vec())
                .await,
            Err(StreamError::InvalidFrame)
        ));
    }

    #[tokio::test]
    async fn duplicate_inbound_open_ignored_keeps_existing_stream_live() {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let peer_id = "peer-a";
        let session_id = crate::session::SessionId::new();
        state
            .connection_sessions
            .register_pending_session(peer_id, session_id)
            .await
            .expect("register stream test session");
        let route = crate::connection::test_blocking_generic_route();
        state
            .attach_test_generic_route(peer_id, session_id, route.handle)
            .await
            .expect("attach stream test path");
        route.worker.abort();
        // 首次 open 注册一条活动流（Event 消费者，数据以事件形式交付）。
        handle_inbound_open(&state, peer_id, StreamOpener::Remote, 42, "custom")
            .await
            .expect("first open");
        let manager = state.stream_manager(peer_id).await;
        assert!(
            manager.is_open(StreamOpener::Remote, 42).await,
            "first stream must be open"
        );

        // 同一 stream_id 的重复 open：必须被忽略，绝不能把现有活动流当作
        // 关闭处理（修复 #5：原先会 handle_close 关掉现有流的接收侧）。
        handle_inbound_open(&state, peer_id, StreamOpener::Remote, 42, "custom")
            .await
            .expect("duplicate open is ignored");
        assert!(
            manager.is_open(StreamOpener::Remote, 42).await,
            "existing stream must stay open"
        );
        assert!(
            !manager.is_recv_closed(StreamOpener::Remote, 42).await,
            "existing stream receive side must stay open"
        );

        // 现有流在重复 open 之后仍然接收字节（以事件交付）。
        manager
            .handle_bytes(peer_id, StreamOpener::Remote, 42, 0, b"still-live".to_vec())
            .await
            .expect("bytes after duplicate open");
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("timed out waiting for data event after duplicate open")
            .expect("event channel closed");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "peer-a" && handle.stream_id == 42) && recv.data == b"still-live"
        ));
    }

    #[tokio::test]
    async fn backpressure_blocks_until_consumer_drains() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 5, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        let big = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
        // Fill the buffer to the cap.
        let mut pushed = 0;
        loop {
            if manager
                .handle_bytes("peer-a", StreamOpener::Local, 5, pushed, big.clone())
                .await
                .is_err()
            {
                break;
            }
            pushed += 1;
            if (pushed as usize) * big.len() >= MAX_PER_STREAM_BUFFER_CAPACITY {
                break;
            }
        }
        // The next push must block (bounded buffer), not drop or error.
        let blocked = {
            let manager = manager.clone();
            tokio::spawn(async move {
                manager
                    .handle_bytes("peer-a", StreamOpener::Local, 5, pushed, vec![0x01; 1])
                    .await
            })
        };
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(
            !blocked.is_finished(),
            "send should be blocked on a full buffer"
        );
        // Drain one chunk: the blocked writer completes.
        let mut buf = [0u8; MAX_STREAM_FRAME_BYTES];
        let n = manager
            .receive(StreamOpener::Local, 5, &mut buf)
            .await
            .expect("drain");
        assert_eq!(n, MAX_STREAM_FRAME_BYTES);
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), blocked)
            .await
            .expect("blocked writer did not complete after drain")
            .expect("blocked writer task panicked");
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn backpressure_wakeup_is_never_lost_under_repeated_races() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 9, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        // 回归修复 #4：填满-阻塞-腾空-唤醒循环反复执行，暴露「检查条件后释放
        // 锁、再注册等待」间隙里的 lost-wakeup。修复前用 `Notify`，该间隙中
        // 生产者 drain 后 `notify_waiters()` 不带许可，writer 会永久阻塞。
        let chunk = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
        let mut pushed = 0u64;
        let mut sink = [0u8; MAX_STREAM_FRAME_BYTES];
        for _ in 0..50 {
            // 填满有界缓冲，使下一次写入必然阻塞（背压前提）。
            while manager
                .buffered_bytes(StreamOpener::Local, 9)
                .await
                .unwrap()
                + chunk.len()
                <= MAX_PER_STREAM_BUFFER_CAPACITY
            {
                manager
                    .handle_bytes("peer-a", StreamOpener::Local, 9, pushed, chunk.clone())
                    .await
                    .expect("fill");
                pushed += 1;
            }
            // 阻塞的 writer：缓冲已满，等待消费者腾出空间。
            let blocked = {
                let manager = manager.clone();
                tokio::spawn(async move {
                    manager
                        .handle_bytes("peer-a", StreamOpener::Local, 9, pushed, vec![0x01; 1])
                        .await
                })
            };
            // 给 writer 机会进入等待点并注册，放大检查-等待竞态窗口。
            tokio::task::yield_now().await;
            // 从另一任务 drain 一块：阻塞的 writer 必须完成，唤醒绝不丢失。
            let n = manager
                .receive(StreamOpener::Local, 9, &mut sink)
                .await
                .expect("drain");
            assert_eq!(n, MAX_STREAM_FRAME_BYTES);
            let result = tokio::time::timeout(std::time::Duration::from_secs(1), blocked)
                .await
                .expect("blocked writer deadlocked: backpressure wakeup was lost")
                .expect("blocked writer task panicked");
            assert!(result.is_ok());
            pushed += 1;
            // 清空残留，使下一轮从空缓冲开始（保持「缓冲满才阻塞」前提成立）。
            while manager
                .buffered_bytes(StreamOpener::Local, 9)
                .await
                .unwrap()
                > 0
            {
                let _ = manager.receive(StreamOpener::Local, 9, &mut sink).await;
            }
        }
    }

    #[tokio::test]
    async fn event_consumer_flood_stays_bounded_and_drains_in_order() {
        let (manager, mut event_rx) = test_manager();
        manager
            .open(StreamOpener::Local, 6, "custom", StreamConsumer::Event)
            .await
            .expect("open");

        // 洪水超过有界缓冲区：Event 流也必须把 writer 阻塞在
        // MAX_PER_STREAM_BUFFER_CAPACITY，而不是把每一帧直接灌入事件通道。
        let chunk = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
        let total_chunks = MAX_PER_STREAM_BUFFER_CAPACITY / MAX_STREAM_FRAME_BYTES + 8;
        let flood = {
            let manager = manager.clone();
            tokio::spawn(async move {
                let mut pushed = 0u64;
                while pushed < total_chunks as u64 {
                    manager
                        .handle_bytes("peer-a", StreamOpener::Local, 6, pushed, chunk.clone())
                        .await
                        .expect("handle_bytes");
                    pushed += 1;
                }
                pushed
            })
        };
        // drainer 未启动时，writer 必须被阻塞（背压），不得逐帧灌入事件通道。
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(
            !flood.is_finished(),
            "flood must be blocked waiting for the Event drainer"
        );
        // 缓冲字节数不越过 cap，且尚未发出任何事件（事件只由 drainer 从缓冲吐出）。
        let buffered = manager
            .buffered_bytes(StreamOpener::Local, 6)
            .await
            .expect("stream");
        assert!(
            buffered <= MAX_PER_STREAM_BUFFER_CAPACITY,
            "buffered bytes must stay bounded: {buffered} > {MAX_PER_STREAM_BUFFER_CAPACITY}"
        );
        assert!(
            event_rx.try_recv().is_err(),
            "no event may be emitted while the drainer is paused"
        );

        // 启动 drainer：阻塞的 writer 随 drain 推进，全部字节最终按序以事件发出。
        let drainer = {
            let manager = manager.clone();
            tokio::spawn(async move {
                manager
                    .drain_events("peer-a", StreamOpener::Local, 6, "local-device")
                    .await
            })
        };
        let pushed = tokio::time::timeout(std::time::Duration::from_secs(5), flood)
            .await
            .expect("flood did not complete after the drainer started")
            .expect("flood panicked");
        assert_eq!(pushed, total_chunks as u64);

        let mut received = 0usize;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while received < pushed as usize * MAX_STREAM_FRAME_BYTES {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                panic!("not all flooded bytes were delivered; received {received} bytes");
            }
            let event = tokio::time::timeout(remaining, event_rx.recv())
                .await
                .expect("timed out waiting for stream data events")
                .expect("event channel closed");
            if let Some(network_event::Payload::SshStreamDataReceived(recv)) = event.payload {
                assert!(recv
                    .handle
                    .as_ref()
                    .is_some_and(
                        |handle| handle.opener_device_id == "local-device" && handle.stream_id == 6
                    ));
                received += recv.data.len();
            }
        }
        assert_eq!(received, pushed as usize * MAX_STREAM_FRAME_BYTES);

        // 关闭后 drainer 发出 close 事件并退出。
        manager
            .handle_close("peer-a", StreamOpener::Local, 6)
            .await
            .expect("close");
        let closed = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("close event missing")
            .expect("event channel closed");
        assert!(matches!(
            closed.payload,
            Some(network_event::Payload::SshStreamClosed(c)) if c.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 6)
        ));
        tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
            .await
            .expect("drainer did not exit after close")
            .expect("drainer panicked");
    }

    #[tokio::test]
    async fn stream_capacity_is_enforced() {
        let (manager, _event_rx) = test_manager();
        for id in 1..=MAX_CONCURRENT_STREAMS {
            manager
                .open(
                    StreamOpener::Local,
                    id as u16,
                    "custom",
                    StreamConsumer::Poll,
                )
                .await
                .expect("open");
        }
        assert!(matches!(
            manager
                .open(
                    StreamOpener::Local,
                    (MAX_CONCURRENT_STREAMS + 1) as u16,
                    "custom",
                    StreamConsumer::Poll
                )
                .await,
            Err(StreamError::CapacityExceeded)
        ));
    }
}
