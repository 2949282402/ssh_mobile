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
use network_protocol::network_event;
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, NetworkEvent, SshStreamCloseCommand,
    SshStreamDataCommand, SshStreamOpenCommand,
};
use quinn::SendStream;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc::UnboundedSender, watch, Mutex};

use crate::connection::GenericFrameKind;
use crate::events::{emit_stream_closed, emit_stream_data_received, protocol_error_with_peer};
use crate::runtime::RuntimeState;
use crate::session::StreamCarrier;

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
pub(crate) const MAX_STREAM_FRAME_BYTES: usize = 16 * 1024;
/// Per-stream receive buffer cap; the reader blocks while a consumer drains.
pub(crate) const MAX_PER_STREAM_BUFFER_CAPACITY: usize = 256 * 1024;
/// Maximum concurrent byte streams per peer.
pub(crate) const MAX_CONCURRENT_STREAMS: usize = 256;
/// Maximum service-hint length in bytes.
pub(crate) const MAX_SERVICE_BYTES: usize = 128;
/// Chunk size for the gateway socket pump.
pub(crate) const STREAM_SOCKET_CHUNK_BYTES: usize = 16 * 1024;
/// QUIC bidi preamble magic; distinguishes reliable streams from file offers
/// (file offers use `SMFT`) on the shared `accept_bi` loop.
pub(crate) const STREAM_QUIC_PREAMBLE_MAGIC: [u8; 4] = *b"SMSS";
/// File offer magic mirrored from `network_quic::file_stream` for dispatch.
pub(crate) const FILE_OFFER_MAGIC: [u8; 4] = *b"SMFT";
/// Generic StreamBytes inner header: stream_id(u16) + seq(u64) + len(u32).
const STREAM_GENERIC_HEADER_BYTES: usize = 2 + 8 + 4;

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
    UnsupportedTransport,
    #[error("route send failed: {0}")]
    Send(String),
}

impl StreamError {
    fn into_protocol(self, peer_id: &str, operation: &str) -> ProtocolError {
        protocol_error_with_peer(
            NetworkErrorCode::IoError,
            self.to_string(),
            operation,
            peer_id,
        )
    }
}

// ---------------------------------------------------------------------------
// Wire encoders / decoders (generic-route frames and QUIC preamble)
// ---------------------------------------------------------------------------

pub(crate) fn encode_stream_bytes_frame(stream_id: u16, seq: u64, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(STREAM_GENERIC_HEADER_BYTES + data.len());
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
    out
}

pub(crate) fn decode_stream_bytes_frame(payload: &[u8]) -> Result<(u16, u64, &[u8]), StreamError> {
    if payload.len() < STREAM_GENERIC_HEADER_BYTES {
        return Err(StreamError::InvalidFrame);
    }
    let stream_id = u16::from_be_bytes(payload[0..2].try_into().expect("stream_id bytes"));
    let seq = u64::from_be_bytes(payload[2..10].try_into().expect("seq bytes"));
    let len = u32::from_be_bytes(payload[10..14].try_into().expect("len bytes")) as usize;
    if len == 0 || STREAM_GENERIC_HEADER_BYTES + len != payload.len() {
        return Err(StreamError::InvalidFrame);
    }
    Ok((
        stream_id,
        seq,
        &payload[STREAM_GENERIC_HEADER_BYTES..STREAM_GENERIC_HEADER_BYTES + len],
    ))
}

pub(crate) fn encode_stream_open_frame(
    stream_id: u16,
    service: &str,
) -> Result<Vec<u8>, StreamError> {
    if service.is_empty() || service.len() > MAX_SERVICE_BYTES {
        return Err(StreamError::InvalidArgument);
    }
    let mut out = Vec::with_capacity(4 + service.len());
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&(service.len() as u16).to_be_bytes());
    out.extend_from_slice(service.as_bytes());
    Ok(out)
}

pub(crate) fn decode_stream_open_frame(payload: &[u8]) -> Result<(u16, String), StreamError> {
    if payload.len() < 4 {
        return Err(StreamError::InvalidFrame);
    }
    let stream_id = u16::from_be_bytes(payload[0..2].try_into().expect("stream_id bytes"));
    let service_len =
        u16::from_be_bytes(payload[2..4].try_into().expect("service_len bytes")) as usize;
    if service_len == 0 || service_len > MAX_SERVICE_BYTES || 4 + service_len != payload.len() {
        return Err(StreamError::InvalidFrame);
    }
    let service = std::str::from_utf8(&payload[4..4 + service_len])
        .map_err(|_| StreamError::InvalidFrame)?
        .to_string();
    Ok((stream_id, service))
}

pub(crate) fn encode_stream_close_frame(stream_id: u16) -> Vec<u8> {
    stream_id.to_be_bytes().to_vec()
}

pub(crate) fn decode_stream_close_frame(payload: &[u8]) -> Result<u16, StreamError> {
    if payload.len() != 2 {
        return Err(StreamError::InvalidFrame);
    }
    Ok(u16::from_be_bytes(
        payload[0..2].try_into().expect("close stream_id bytes"),
    ))
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

/// Relay 路由的流令牌：仅含 stream_id，与发起方向无关（无 opener 维度）。
///
/// 已知局限（记录，不在本轮修复）：若两个对端各自用同一 stream_id 在 relay
/// 上独立 open，令牌会碰撞导致字节交叉串扰。根治需要 opener 作用域的令牌 +
/// 方向作用域的本地流键；当前保持现状，仅在此记录该设计债。
fn stream_relay_token(stream_id: u16) -> String {
    format!("stream:{stream_id}")
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
    streams: HashMap<u16, StreamEntry>,
}

/// Cloneable per-peer owner of every byte-stream receive buffer and QUIC send
/// half. The generic route receiver, QUIC bidi receivers, FFI commands and the
/// gateway bridge all share one manager per peer.
#[derive(Clone)]
pub(crate) struct ReliableStreamManager {
    inner: Arc<Mutex<StreamState>>,
    event_tx: UnboundedSender<NetworkEvent>,
}

impl ReliableStreamManager {
    pub(crate) fn new(event_tx: UnboundedSender<NetworkEvent>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(StreamState::default())),
            event_tx,
        }
    }

    pub(crate) async fn open(
        &self,
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
        if state.streams.contains_key(&stream_id) {
            return Err(StreamError::AlreadyOpen);
        }
        let (wake_tx, _) = watch::channel(0u64);
        state.streams.insert(
            stream_id,
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
            },
        );
        Ok(())
    }

    pub(crate) async fn register_quic_send(
        &self,
        stream_id: u16,
        send: SendStream,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&stream_id)
            .ok_or(StreamError::NotFound)?;
        entry.quic_send = Some(send);
        Ok(())
    }

    /// Acquires the per-stream send mutex so a full send operation (generic
    /// frame sequence or QUIC write) is not interleaved with another caller.
    pub(crate) async fn send_guard(&self, stream_id: u16) -> Result<Arc<Mutex<()>>, StreamError> {
        let state = self.inner.lock().await;
        let entry = state.streams.get(&stream_id).ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(Arc::clone(&entry.send_lock))
    }

    pub(crate) async fn next_send_seq(&self, stream_id: u16) -> Result<u64, StreamError> {
        let state = self.inner.lock().await;
        let entry = state.streams.get(&stream_id).ok_or(StreamError::NotFound)?;
        if entry.send_closed {
            return Err(StreamError::Closed);
        }
        Ok(entry.next_send_seq)
    }

    pub(crate) async fn bump_send_seq(
        &self,
        stream_id: u16,
        count: u64,
    ) -> Result<(), StreamError> {
        let mut state = self.inner.lock().await;
        let entry = state
            .streams
            .get_mut(&stream_id)
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
        stream_id: u16,
        data: &[u8],
    ) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&stream_id)
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
        if let Some(entry) = state.streams.get_mut(&stream_id) {
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
    pub(crate) async fn quic_finish_send(&self, stream_id: u16) -> Result<(), StreamError> {
        let mut send = {
            let mut state = self.inner.lock().await;
            let entry = state
                .streams
                .get_mut(&stream_id)
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
                    .get_mut(&stream_id)
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
                let Some(entry) = state.streams.get_mut(&stream_id) else {
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
    pub(crate) async fn drain_events(self, peer_id: &str, stream_id: u16) {
        loop {
            let wait: Option<watch::Receiver<u64>> = {
                let mut state = self.inner.lock().await;
                let Some(entry) = state.streams.get_mut(&stream_id) else {
                    return;
                };
                if let Some(chunk) = entry.recv_chunks.pop_front() {
                    entry.recv_bytes -= chunk.len();
                    emit_stream_data_received(&self.event_tx, peer_id, stream_id, &chunk);
                    entry.wake();
                    continue;
                }
                if entry.recv_closed {
                    // 缓冲区已空且对端关闭：最后发出 close 事件，保证 data 先于 close。
                    drop(state);
                    emit_stream_closed(&self.event_tx, peer_id, stream_id);
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
        stream_id: u16,
        service: &str,
        consumer: StreamConsumer,
    ) -> Result<(), StreamError> {
        self.open(stream_id, service, consumer).await
    }

    /// Inbound StreamClose / QUIC EOF: mark the receive side closed and wake
    /// consumers. Bridge/Poll consumers observe EOF through `receive` returning
    /// 0; the Event-mode `SshStreamClosed` event is emitted by the per-stream
    /// drainer after the buffer is emptied, so data events always precede the
    /// close event (设计 §17 顺序保证).
    pub(crate) async fn handle_close(
        &self,
        peer_id: &str,
        stream_id: u16,
    ) -> Result<(), StreamError> {
        {
            let mut state = self.inner.lock().await;
            let Some(entry) = state.streams.get_mut(&stream_id) else {
                return Ok(());
            };
            if entry.recv_closed {
                return Ok(());
            }
            entry.recv_closed = true;
            entry.wake();
            if entry.send_closed {
                state.streams.remove(&stream_id);
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
        stream_id: u16,
    ) -> Result<(), StreamError> {
        let removed = {
            let mut state = self.inner.lock().await;
            let Some(entry) = state.streams.get_mut(&stream_id) else {
                return Ok(());
            };
            if entry.send_closed {
                return Ok(());
            }
            entry.send_closed = true;
            entry.wake();
            let removed = entry.recv_closed;
            if removed {
                state.streams.remove(&stream_id);
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
        stream_id: u16,
        buf: &mut [u8],
    ) -> Result<usize, StreamError> {
        loop {
            let wait = {
                let mut state = self.inner.lock().await;
                let entry = state
                    .streams
                    .get_mut(&stream_id)
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
    pub(crate) async fn is_open(&self, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state.streams.contains_key(&stream_id)
    }

    #[allow(dead_code)] // test/diagnostic query surface
    pub(crate) async fn is_recv_closed(&self, stream_id: u16) -> bool {
        let state = self.inner.lock().await;
        state.streams.get(&stream_id).is_some_and(|e| e.recv_closed)
    }

    /// 诊断/测试查询面：返回该流当前缓冲的字节数，用于断言背压下有界性。
    #[cfg(test)]
    async fn buffered_bytes(&self, stream_id: u16) -> Option<usize> {
        let state = self.inner.lock().await;
        state.streams.get(&stream_id).map(|entry| entry.recv_bytes)
    }

    /// Session teardown: close every stream for the peer. Returns the ids so
    /// the caller can emit closed events.
    pub(crate) async fn close_all(&self, peer_id: &str) -> Vec<u16> {
        let ids = {
            let mut state = self.inner.lock().await;
            let ids: Vec<u16> = state.streams.keys().copied().collect();
            state.streams.clear();
            ids
        };
        for stream_id in &ids {
            emit_stream_closed(&self.event_tx, peer_id, *stream_id);
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

/// Opens a byte stream to a peer. `consumer` selects how inbound bytes are
/// delivered (events / bridge / poll).
pub(crate) async fn open_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    service: &str,
    consumer: StreamConsumer,
) -> Result<(), StreamError> {
    // §17: the ConnectionSession's CommunicationClass gates the carrier shape.
    // ReliableStream / BulkTransfer / Unspecified (default) allow byte streams;
    // a session explicitly typed ReliableMessage is not a byte-stream carrier.
    match state.sessions.current_communication_class(peer_id).await {
        Some(
            network_protocol::CommunicationClass::ReliableStream
            | network_protocol::CommunicationClass::BulkTransfer
            | network_protocol::CommunicationClass::Unspecified,
        )
        | None => {}
        Some(_) => return Err(StreamError::UnsupportedTransport),
    }
    let profile = state
        .sessions
        .current_profile(peer_id)
        .await
        .ok_or(StreamError::NotConnected)?;
    if !profile.supports(crate::connection::ConnectionCapability::ReliableStream) {
        return Err(StreamError::UnsupportedTransport);
    }
    let carrier = state
        .sessions
        .current_stream_carrier(peer_id)
        .await
        .ok_or(StreamError::NotConnected)?;
    let manager = state.stream_manager(peer_id).await;
    match carrier {
        StreamCarrier::Generic(handle) => {
            let payload = encode_stream_open_frame(stream_id, service)?;
            handle
                .send(GenericFrameKind::StreamOpen, &payload)
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            manager.open(stream_id, service, consumer).await?;
            Ok(())
        }
        StreamCarrier::Quic(connection) => {
            let (mut send, recv) = connection
                .open_bi()
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            let preamble = encode_quic_stream_preamble(stream_id, service)?;
            send.write_all(&preamble)
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            send.flush()
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            manager.open(stream_id, service, consumer).await?;
            manager.register_quic_send(stream_id, send).await?;
            spawn_quic_stream_reader(state, peer_id, stream_id, recv).await;
            Ok(())
        }
        StreamCarrier::Relay(Some(relay)) => {
            let payload = encode_stream_open_frame(stream_id, service)?;
            crate::relay::send_relay_stream_frame(&relay, &stream_relay_token(stream_id), &payload)
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            manager.open(stream_id, service, consumer).await?;
            Ok(())
        }
        StreamCarrier::Relay(None) => Err(StreamError::NotConnected),
    }?;
    if consumer == StreamConsumer::Event {
        spawn_stream_event_emitter(state, peer_id, stream_id).await;
    }
    Ok(())
}

/// Sends bytes on a byte stream. The generic route splits into bounded
/// StreamBytes frames and awaits the bounded route send (never drops); the
/// QUIC route writes raw bytes on the real QUIC stream.
pub(crate) async fn send_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    data: &[u8],
) -> Result<(), StreamError> {
    if data.is_empty() {
        return Ok(());
    }
    let manager = state.stream_manager(peer_id).await;
    let send_guard = manager.send_guard(stream_id).await?;
    let _guard = send_guard.lock().await;
    let carrier = state
        .sessions
        .current_stream_carrier(peer_id)
        .await
        .ok_or(StreamError::NotConnected)?;
    match carrier {
        StreamCarrier::Generic(handle) => {
            let seq = manager.next_send_seq(stream_id).await?;
            let mut chunks = 0u64;
            for chunk in data.chunks(MAX_STREAM_FRAME_BYTES) {
                let payload = encode_stream_bytes_frame(stream_id, seq + chunks, chunk);
                handle
                    .send(GenericFrameKind::StreamBytes, &payload)
                    .await
                    .map_err(|error| StreamError::Send(error.to_string()))?;
                chunks += 1;
            }
            manager.bump_send_seq(stream_id, chunks).await?;
            Ok(())
        }
        StreamCarrier::Quic(_) => manager.quic_send_bytes(stream_id, data).await,
        StreamCarrier::Relay(Some(relay)) => {
            let seq = manager.next_send_seq(stream_id).await?;
            let mut chunks = 0u64;
            for chunk in data.chunks(MAX_STREAM_FRAME_BYTES) {
                let payload = encode_stream_bytes_frame(stream_id, seq + chunks, chunk);
                crate::relay::send_relay_stream_frame(
                    &relay,
                    &stream_relay_token(stream_id),
                    &payload,
                )
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
                chunks += 1;
            }
            manager.bump_send_seq(stream_id, chunks).await?;
            Ok(())
        }
        StreamCarrier::Relay(None) => Err(StreamError::NotConnected),
    }
}

/// Drains buffered bytes for a Bridge/Poll consumer.
pub(crate) async fn receive_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    let manager = state.stream_manager(peer_id).await;
    manager.receive(stream_id, buf).await
}

/// Closes a byte stream locally and tells the peer.
pub(crate) async fn close_stream(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
) -> Result<(), StreamError> {
    let manager = state.stream_manager(peer_id).await;
    let carrier = state
        .sessions
        .current_stream_carrier(peer_id)
        .await
        .ok_or(StreamError::NotConnected)?;
    match carrier {
        StreamCarrier::Generic(handle) => {
            let payload = encode_stream_close_frame(stream_id);
            handle
                .send(GenericFrameKind::StreamClose, &payload)
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            manager.close_local(peer_id, stream_id).await?;
            Ok(())
        }
        StreamCarrier::Quic(_) => {
            manager.quic_finish_send(stream_id).await?;
            manager.close_local(peer_id, stream_id).await?;
            Ok(())
        }
        StreamCarrier::Relay(Some(relay)) => {
            let payload = encode_stream_close_frame(stream_id);
            crate::relay::send_relay_stream_frame(&relay, &stream_relay_token(stream_id), &payload)
                .await
                .map_err(|error| StreamError::Send(error.to_string()))?;
            manager.close_local(peer_id, stream_id).await?;
            Ok(())
        }
        StreamCarrier::Relay(None) => Err(StreamError::NotConnected),
    }
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
            let (stream_id, service) = decode_stream_open_frame(payload)?;
            handle_inbound_open(state, peer_id, stream_id, &service).await
        }
        GenericFrameKind::StreamBytes => {
            let (stream_id, seq, data) = decode_stream_bytes_frame(payload)?;
            let manager = state.stream_manager(peer_id).await;
            manager
                .handle_bytes(peer_id, stream_id, seq, data.to_vec())
                .await
        }
        GenericFrameKind::StreamClose => {
            let stream_id = decode_stream_close_frame(payload)?;
            let manager = state.stream_manager(peer_id).await;
            manager.handle_close(peer_id, stream_id).await
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
    stream_id: u16,
    service: &str,
) -> Result<(), StreamError> {
    let consumer = if service == STREAM_SERVICE_SSH {
        StreamConsumer::Bridge
    } else {
        StreamConsumer::Event
    };
    let manager = state.stream_manager(peer_id).await;
    match manager.handle_open(stream_id, service, consumer).await {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 同一 stream_id 的重复 open：丢弃这个重复的 open，已存在的活动流
            // 保持原样。绝不能调用 handle_close——那会把现有活动流的接收侧
            // 标记关闭，拆掉一条活着的 SSH 会话（修复 #5）。
            return Ok(());
        }
        Err(error) => return Err(error),
    }
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(Arc::clone(state), peer_id.to_string(), stream_id);
    } else {
        spawn_stream_event_emitter(state, peer_id, stream_id).await;
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
    match manager.handle_open(stream_id, &service, consumer).await {
        Ok(()) => {}
        Err(StreamError::AlreadyOpen) => {
            // 重复 open：丢弃这个重复的 QUIC 流，已存在的活动流保持原样，
            // 绝不能 handle_close 掉现有流（修复 #5）。
            return;
        }
        Err(_) => return,
    }
    if manager.register_quic_send(stream_id, send).await.is_err() {
        let _ = manager.handle_close(&peer_id, stream_id).await;
        return;
    }
    spawn_quic_stream_reader(&state, &peer_id, stream_id, receive).await;
    if consumer == StreamConsumer::Bridge {
        spawn_ssh_gateway(state, peer_id, stream_id);
    } else {
        spawn_stream_event_emitter(&state, &peer_id, stream_id).await;
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
    stream_id: u16,
) {
    let manager = state.stream_manager(peer_id).await;
    let peer_id = peer_id.to_string();
    let session_key = state
        .sessions
        .current_session_id(&peer_id)
        .await
        .map(|id| id.wire_key())
        .unwrap_or_default();
    let _ = state.task_supervisor.spawn_session(
        session_key,
        "stream-event-emitter",
        async move { manager.drain_events(&peer_id, stream_id).await },
    );
}

/// Pumps a QUIC `RecvStream` (the peer's write half of a logical byte stream)
/// into the per-stream reassembly buffer.
pub(crate) async fn spawn_quic_stream_reader(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    stream_id: u16,
    mut recv: quinn::RecvStream,
) {
    let state = Arc::clone(state);
    let peer_id = peer_id.to_string();
    let session_key = state
        .sessions
        .current_session_id(&peer_id)
        .await
        .map(|id| id.wire_key())
        .unwrap_or_default();
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_session(session_key, "reliable-stream-reader", async move {
        let manager = state.stream_manager(&peer_id).await;
        let mut buf = vec![0u8; MAX_STREAM_FRAME_BYTES];
        let mut seq = 0u64;
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) => {
                    let data = buf[..n].to_vec();
                    let _ = manager.handle_bytes(&peer_id, stream_id, seq, data).await;
                    seq += 1;
                }
                Ok(None) | Err(_) => {
                    let _ = manager.handle_close(&peer_id, stream_id).await;
                    return;
                }
            }
        }
    });
}

/// The SSH Server Service (design §21 option B): bridges a native byte stream
/// whose service hint is `ssh` to a local TCP sshd socket. Zero SSH protocol
/// code; the bridge just pumps bytes both ways.
pub(crate) fn spawn_ssh_gateway(state: Arc<RuntimeState>, peer_id: String, stream_id: u16) {
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
                let _ = close_stream(&state, &peer_id, stream_id).await;
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
                            if send_stream(&state, &peer_id, stream_id, &buf[..n])
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                    }
                }
                let _ = close_stream(&state, &peer_id, stream_id).await;
            }
        });

        // native stream -> socket
        let stream_to_socket = tokio::spawn({
            let state = Arc::clone(&state);
            let peer_id = peer_id.clone();
            async move {
                let mut buf = vec![0u8; STREAM_SOCKET_CHUNK_BYTES];
                loop {
                    match receive_stream(&state, &peer_id, stream_id, &mut buf).await {
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
        let _ = close_stream(&state, &peer_id, stream_id).await;
    });
}

// ---------------------------------------------------------------------------
// FFI command handlers
// ---------------------------------------------------------------------------

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
    let stream_id = u16::try_from(command.stream_id).map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "stream_id must be in 1..=65535",
            "ssh_stream_open",
            &command.peer_id,
        )
    })?;
    if stream_id == 0 {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "stream_id must be non-zero",
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
    let stream_id = u16::try_from(command.stream_id).map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "stream_id must be in 1..=65535",
            "ssh_stream_data",
            &command.peer_id,
        )
    })?;
    send_stream(&state, &command.peer_id, stream_id, &command.data)
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
    let stream_id = u16::try_from(command.stream_id).map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "stream_id must be in 1..=65535",
            "ssh_stream_close",
            &command.peer_id,
        )
    })?;
    close_stream(&state, &command.peer_id, stream_id)
        .await
        .map_err(|error| error.into_protocol(&command.peer_id, "ssh_stream_close"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    fn test_manager() -> (ReliableStreamManager, mpsc::UnboundedReceiver<NetworkEvent>) {
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        (ReliableStreamManager::new(event_tx), event_rx)
    }

    #[test]
    fn stream_wire_frames_round_trip() {
        let data = encode_stream_bytes_frame(7, 3, b"hello");
        let (stream_id, seq, payload) = decode_stream_bytes_frame(&data).expect("decode bytes");
        assert_eq!((stream_id, seq), (7, 3));
        assert_eq!(payload, b"hello");

        let open = encode_stream_open_frame(7, "ssh").expect("encode open");
        let (stream_id, service) = decode_stream_open_frame(&open).expect("decode open");
        assert_eq!((stream_id, service.as_str()), (7, "ssh"));

        let close = encode_stream_close_frame(7);
        assert_eq!(decode_stream_close_frame(&close).expect("decode close"), 7);
        assert!(decode_stream_open_frame(b"\x00\x01\xff").is_err());
        assert!(decode_stream_bytes_frame(&[0u8; 8]).is_err());
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
            .open(1, "custom", StreamConsumer::Event)
            .await
            .expect("open");
        // Event-mode bytes are buffered and delivered by the drainer task.
        let drainer = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.drain_events("peer-a", 1).await })
        };
        manager
            .handle_bytes("peer-a", 1, 0, b"ping".to_vec())
            .await
            .expect("bytes");
        let event = event_rx.recv().await.expect("data event");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "peer-a" && recv.stream_id == 1 && recv.data == b"ping"
        ));
        manager.handle_close("peer-a", 1).await.expect("close");
        let event = event_rx.recv().await.expect("close event");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamClosed(closed)) if closed.stream_id == 1
        ));
        // The drainer exits after it emits the close event.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
            .await
            .expect("drainer did not exit after close")
            .expect("drainer panicked");
    }

    #[tokio::test]
    async fn poll_consumer_buffers_until_read_and_reports_eof() {
        let (manager, mut event_rx) = test_manager();
        manager
            .open(2, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .handle_bytes("peer-a", 2, 0, b"abc".to_vec())
            .await
            .expect("bytes");
        manager
            .handle_bytes("peer-a", 2, 1, b"de".to_vec())
            .await
            .expect("bytes");

        let mut buf = [0u8; 2];
        let n = manager.receive(2, &mut buf).await.expect("receive");
        assert_eq!((n, &buf[..n]), (2, &b"ab"[..]));
        let n = manager.receive(2, &mut buf).await.expect("receive");
        assert_eq!((n, &buf[..n]), (2, &b"cd"[..]));
        let n = manager.receive(2, &mut buf).await.expect("receive");
        assert_eq!((n, &buf[..n]), (1, &b"e"[..]));

        manager.handle_close("peer-a", 2).await.expect("close");
        let n = manager
            .receive(2, &mut buf)
            .await
            .expect("receive after close");
        assert_eq!(n, 0);
        // close_local removes the entry once both sides closed.
        manager.close_local("peer-a", 2).await.expect("close local");
        assert!(!manager.is_open(2).await);
        // Event channel was unused for the poll consumer.
        assert!(event_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn data_after_close_is_dropped_not_an_error() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(3, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager.handle_close("peer-a", 3).await.expect("close");
        // A late packet racing the close must not be treated as a fatal error.
        assert!(manager
            .handle_bytes("peer-a", 3, 0, b"late".to_vec())
            .await
            .is_ok());
    }

    #[tokio::test]
    async fn duplicate_and_gap_sequence_handling() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(4, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        manager
            .handle_bytes("peer-a", 4, 0, b"a".to_vec())
            .await
            .expect("first");
        // Duplicate seq 0 is dropped silently.
        assert!(manager
            .handle_bytes("peer-a", 4, 0, b"dup".to_vec())
            .await
            .is_ok());
        // Gap (seq 2 after seq 0) is a protocol error for that stream only.
        assert!(matches!(
            manager.handle_bytes("peer-a", 4, 2, b"gap".to_vec()).await,
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
        // 首次 open 注册一条活动流（Event 消费者，数据以事件形式交付）。
        handle_inbound_open(&state, peer_id, 42, "custom")
            .await
            .expect("first open");
        let manager = state.stream_manager(peer_id).await;
        assert!(manager.is_open(42).await, "first stream must be open");

        // 同一 stream_id 的重复 open：必须被忽略，绝不能把现有活动流当作
        // 关闭处理（修复 #5：原先会 handle_close 关掉现有流的接收侧）。
        handle_inbound_open(&state, peer_id, 42, "custom")
            .await
            .expect("duplicate open is ignored");
        assert!(manager.is_open(42).await, "existing stream must stay open");
        assert!(
            !manager.is_recv_closed(42).await,
            "existing stream receive side must stay open"
        );

        // 现有流在重复 open 之后仍然接收字节（以事件交付）。
        manager
            .handle_bytes(peer_id, 42, 0, b"still-live".to_vec())
            .await
            .expect("bytes after duplicate open");
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("timed out waiting for data event after duplicate open")
            .expect("event channel closed");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.stream_id == 42 && recv.data == b"still-live"
        ));
    }

    #[tokio::test]
    async fn backpressure_blocks_until_consumer_drains() {
        let (manager, _event_rx) = test_manager();
        manager
            .open(5, "custom", StreamConsumer::Poll)
            .await
            .expect("open");
        let big = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
        // Fill the buffer to the cap.
        let mut pushed = 0;
        loop {
            if manager
                .handle_bytes("peer-a", 5, pushed, big.clone())
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
                    .handle_bytes("peer-a", 5, pushed, vec![0x01; 1])
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
        let n = manager.receive(5, &mut buf).await.expect("drain");
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
            .open(9, "custom", StreamConsumer::Poll)
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
            while manager.buffered_bytes(9).await.unwrap() + chunk.len()
                <= MAX_PER_STREAM_BUFFER_CAPACITY
            {
                manager
                    .handle_bytes("peer-a", 9, pushed, chunk.clone())
                    .await
                    .expect("fill");
                pushed += 1;
            }
            // 阻塞的 writer：缓冲已满，等待消费者腾出空间。
            let blocked = {
                let manager = manager.clone();
                tokio::spawn(async move {
                    manager
                        .handle_bytes("peer-a", 9, pushed, vec![0x01; 1])
                        .await
                })
            };
            // 给 writer 机会进入等待点并注册，放大检查-等待竞态窗口。
            tokio::task::yield_now().await;
            // 从另一任务 drain 一块：阻塞的 writer 必须完成，唤醒绝不丢失。
            let n = manager.receive(9, &mut sink).await.expect("drain");
            assert_eq!(n, MAX_STREAM_FRAME_BYTES);
            let result = tokio::time::timeout(std::time::Duration::from_secs(1), blocked)
                .await
                .expect("blocked writer deadlocked: backpressure wakeup was lost")
                .expect("blocked writer task panicked");
            assert!(result.is_ok());
            pushed += 1;
            // 清空残留，使下一轮从空缓冲开始（保持「缓冲满才阻塞」前提成立）。
            while manager.buffered_bytes(9).await.unwrap() > 0 {
                let _ = manager.receive(9, &mut sink).await;
            }
        }
    }

    #[tokio::test]
    async fn event_consumer_flood_stays_bounded_and_drains_in_order() {
        let (manager, mut event_rx) = test_manager();
        manager
            .open(6, "custom", StreamConsumer::Event)
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
                        .handle_bytes("peer-a", 6, pushed, chunk.clone())
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
        let buffered = manager.buffered_bytes(6).await.expect("stream");
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
            tokio::spawn(async move { manager.drain_events("peer-a", 6).await })
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
                assert_eq!(recv.stream_id, 6);
                received += recv.data.len();
            }
        }
        assert_eq!(received, pushed as usize * MAX_STREAM_FRAME_BYTES);

        // 关闭后 drainer 发出 close 事件并退出。
        manager.handle_close("peer-a", 6).await.expect("close");
        let closed = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("close event missing")
            .expect("event channel closed");
        assert!(matches!(
            closed.payload,
            Some(network_event::Payload::SshStreamClosed(c)) if c.stream_id == 6
        ));
        let _ = tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
            .await
            .expect("drainer did not exit after close")
            .expect("drainer panicked");
    }

    #[tokio::test]
    async fn stream_capacity_is_enforced() {
        let (manager, _event_rx) = test_manager();
        for id in 1..=MAX_CONCURRENT_STREAMS {
            manager
                .open(id as u16, "custom", StreamConsumer::Poll)
                .await
                .expect("open");
        }
        assert!(matches!(
            manager
                .open(
                    (MAX_CONCURRENT_STREAMS + 1) as u16,
                    "custom",
                    StreamConsumer::Poll
                )
                .await,
            Err(StreamError::CapacityExceeded)
        ));
    }
}
