//! 跨 Connection 的应用层投递状态。
//!
//! 这一层只保存可重新编码的业务 payload 和投递元数据，不持有 Quinn/Relay
//! handle。Connection 恢复后由上层取出 `RecoverySnapshot`，在当前 transport
//! 上重新发送；因此 ACK、去重和重试不会绑定到某一条已失效的 Connection。
//!
//! transport-network v2（§19/§20）：跨连接稳定的是业务身份 **MessageId +
//! ChannelId**（以及其所属的 Peer），**不是** Transport Connection 或
//! ConnectionSession。Step 8 之后 Session 与 connection 一一对应且可销毁：
//! 新连接 = 新 SessionId + 新 Noise root。因此本 manager 的 pending / dedup /
//! ordered 状态全部按 **Peer 业务作用域** 保存，绝不用每个连接的 SessionId
//! 作 key；`MessageId` 是 ACK 与去重的稳定键。连接丢失时本 manager 不会清空
//! 这些状态，未 ACK 的消息会在新连接上以**同一个 MessageId** 重新发送，
//! 由接收端按 MessageId 去重（§20）。

use rand::RngCore;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::{Mutex, RwLock};

const MAX_SCOPE_ID_BYTES: usize = 128;
const MESSAGE_ID_BYTES: usize = 16;
const MAX_TERMINAL_OUTCOMES: usize = 4096;

/// Stable business recovery categories shared by Delivery, Transfer, and
/// ReliableStream.  These names deliberately do not depend on a transport or
/// protocol implementation so callers can retain business meaning across a
/// fresh ConnectionSession.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub(crate) enum BusinessRecoveryError {
    #[error("RecoverableTransportLoss")]
    RecoverableTransportLoss,
    #[error("OperationExpired")]
    OperationExpired,
    #[error("ResumeRejected")]
    ResumeRejected,
}

pub(crate) fn is_valid_peer_id(peer_id: &str) -> bool {
    is_valid_scope_id(peer_id)
}

fn is_valid_scope_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_SCOPE_ID_BYTES
}

/// 应用 handler 的 ACK 超时是独立的生命周期策略，不能复用 processed dedup
/// 的 TTL。超时由 Delivery owner 显式扫描；严格有序通道会进入 Failed，不能
/// 通过跳过 Sequence 来伪造顺序恢复。
const MAX_ACTIVE_INCOMING_RECORDS: usize = 4096;

/// 应用层消息的稳定标识；跨 Connection 重试时保持不变。
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct MessageId([u8; MESSAGE_ID_BYTES]);

impl MessageId {
    pub fn from_bytes(bytes: [u8; MESSAGE_ID_BYTES]) -> Self {
        Self(bytes)
    }

    pub fn to_bytes(self) -> [u8; MESSAGE_ID_BYTES] {
        self.0
    }
}

/// Frozen Delivery identity. A transport/session or path is deliberately not
/// part of this key; each send attempt may acquire and release its own path
/// lease while the ACK wait remains peer-scoped.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct DeliveryIdentity {
    pub peer_id: String,
    pub message_id: MessageId,
}

impl DeliveryIdentity {
    pub fn new(peer_id: impl Into<String>, message_id: MessageId) -> Result<Self, DeliveryError> {
        let peer_id = peer_id.into();
        if !is_valid_peer_id(&peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(Self {
            peer_id,
            message_id,
        })
    }
}

/// 业务对消息的可靠性要求。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryPolicy {
    BestEffort,
    LatestState,
    Acked,
    AckedDeduplicated,
    SessionBoundOrdered,
    ResumableTransfer,
}

/// 消息在应用层投递机中的状态。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryState {
    Queued,
    Sending,
    SentUnacked,
    Acked,
    Expired,
    Cancelled,
    Failed,
}

/// 受界的重试预算和退避策略。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    pub max_attempts: u32,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
    pub ttl: Option<Duration>,
    pub max_total_retry_bytes: Option<u64>,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 5,
            initial_backoff: Duration::from_millis(250),
            max_backoff: Duration::from_secs(5),
            ttl: Some(Duration::from_secs(10 * 60)),
            max_total_retry_bytes: Some(64 * 1024 * 1024),
        }
    }
}

impl RetryPolicy {
    fn is_valid(self) -> bool {
        self.max_attempts > 0 && self.initial_backoff <= self.max_backoff
    }

    fn delay_for_attempt(self, attempt: u32) -> Duration {
        let shift = attempt.saturating_sub(1).min(31);
        let multiplier = 1u32.checked_shl(shift).unwrap_or(u32::MAX);
        self.initial_backoff
            .saturating_mul(multiplier)
            .min(self.max_backoff)
    }
}

/// 等待 ACK 的逻辑消息。payload 保持为可在新 Connection 上重新编码的内容。
///
/// 稳定标识是 `message_id`；`peer_id` 是消息所属的**业务作用域**（对端
/// 设备标识），`session_id` 已被移除——每条 Connection 都有新的 SessionId，
/// 因此不在此保存会过期的 per-connection 标识。发送时由传输层传入当前
/// `SessionId` 作为 wire 信封与加密上下文。
#[derive(Clone, Debug)]
pub struct PendingMessage {
    pub message_id: MessageId,
    pub peer_id: String,
    pub channel_id: String,
    pub sequence: u64,
    pub payload: Vec<u8>,
    pub policy: DeliveryPolicy,
    pub state: DeliveryState,
    pub attempts: u32,
    pub created_at: Instant,
    pub expires_at: Option<Instant>,
    /// Peer 作用域的连接代数（每次 Connection Ready 递增一次）。只用于 wire
    /// 信封 / AAD 与诊断，**不再作为 ACK 或去重的门控**。
    pub recovery_epoch: u64,
    retry_policy: RetryPolicy,
    next_retry_at: Instant,
    retry_bytes: u64,
}

/// 一次 Connection Ready 后交给传输层的恢复批次。
///
/// `recovery_epoch` 是该 Peer 作用域当前连接代数，仅用于 wire 信封；
/// 恢复去重完全由 `MessageId` 驱动。
#[derive(Clone, Debug)]
pub struct RecoverySnapshot {
    pub recovery_epoch: u64,
    pub messages: Vec<PendingMessage>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AckResult {
    /// 该 MessageId 正在 pending 中，已从投递队列移除。
    Acknowledged,
    /// 该 MessageId 未知（已完成、未入队或属于其它 Peer）；ACK 是无害的 no-op。
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DedupDecision {
    New,
    DuplicateInFlight,
    DuplicateProcessed,
    /// Active 记录不能为了满足 history 上限而淘汰；调用方必须拒绝新消息，
    /// 等待现有应用 ACK 或显式 timeout。
    CapacityExceeded,
    /// 严格有序通道因显式 abandon 或 ACK timeout 进入失败态。
    ChannelFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    RetryAt(Instant),
    Failed,
    Expired,
    NotFound,
}

impl RetryDecision {
    pub(crate) fn recovery_error(self) -> Option<BusinessRecoveryError> {
        match self {
            Self::RetryAt(_) => Some(BusinessRecoveryError::RecoverableTransportLoss),
            Self::Failed | Self::Expired => Some(BusinessRecoveryError::OperationExpired),
            Self::NotFound => None,
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DeliveryError {
    #[error("peer and channel identifiers are required")]
    InvalidScope,
    #[error("message payload exceeds the delivery limit")]
    PayloadTooLarge,
    #[error("retry policy is invalid")]
    InvalidRetryPolicy,
    #[error("delivery queue is full")]
    QueueFull,
    #[error("message is not pending")]
    NotFound,
    #[error("message expired")]
    Expired,
    #[error("message retry budget exhausted")]
    RetryExhausted,
}

impl DeliveryError {
    pub(crate) fn recovery_error(&self) -> Option<BusinessRecoveryError> {
        match self {
            Self::Expired | Self::RetryExhausted => Some(BusinessRecoveryError::OperationExpired),
            _ => None,
        }
    }
}

/// The single terminal transition an acknowledged reliable message may make.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DeliveryTerminalOutcome {
    Acknowledged,
    Expired,
    Cancelled,
    Failed,
}

/// A peer-scoped lease for one transport send attempt.  The attempt number is
/// checked on completion so a late result from an older attempt cannot settle
/// a newer one.
#[derive(Clone, Debug)]
pub(crate) struct DeliverySendAttempt {
    pub(crate) peer_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) attempt: u32,
    pub(crate) message: PendingMessage,
}

/// Delivery 队列和去重窗口的边界。
#[derive(Clone, Copy, Debug)]
pub struct DeliveryConfig {
    pub max_pending_messages: usize,
    pub max_pending_bytes: usize,
    pub max_payload_bytes: usize,
    /// 仅限制已完成消息的 processed dedup history；InFlight 与
    /// OrderedBuffered 不参与淘汰。
    pub dedup_max_entries: usize,
    /// 仅用于 processed dedup history。Active handler 使用
    /// `application_ack_timeout`，避免两个生命周期语义混用。
    pub dedup_ttl: Duration,
    /// 应用真正收到消息后等待 ACK 的时间。OrderedBuffered 不使用该计时器，
    /// 只有晋升为 InFlight 时才会生成 deadline。
    pub application_ack_timeout: Duration,
    pub max_reorder_messages: usize,
    pub max_reorder_bytes: usize,
    pub max_sequence_gap: u64,
}

impl Default for DeliveryConfig {
    fn default() -> Self {
        Self {
            max_pending_messages: 1024,
            max_pending_bytes: 16 * 1024 * 1024,
            max_payload_bytes: 1024 * 1024,
            dedup_max_entries: 4096,
            dedup_ttl: Duration::from_secs(10 * 60),
            application_ack_timeout: Duration::from_secs(5 * 60),
            max_reorder_messages: 64,
            max_reorder_bytes: 4 * 1024 * 1024,
            max_sequence_gap: 1024,
        }
    }
}

/// A message waiting for an application-ordered channel to release it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct OrderedMessage {
    pub(crate) peer_id: String,
    pub(crate) session_id: String,
    pub(crate) channel_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) sequence: u64,
    pub(crate) policy: DeliveryPolicy,
    pub(crate) payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum OrderedInsertResult {
    Ready,
    Buffered,
    Duplicate,
    Rejected,
}

#[derive(Default)]
struct OrderedChannelState {
    expected_sequence: u64,
    in_flight: Option<MessageId>,
    reorder_buffer: BTreeMap<u64, OrderedMessage>,
    reorder_bytes: usize,
}

impl OrderedChannelState {
    fn insert(
        &mut self,
        message: OrderedMessage,
        max_messages: usize,
        max_bytes: usize,
        max_gap: u64,
    ) -> OrderedInsertResult {
        if message.sequence < self.expected_sequence {
            return OrderedInsertResult::Duplicate;
        }
        if message.sequence == self.expected_sequence {
            return match self.in_flight {
                Some(message_id) if message_id == message.message_id => {
                    OrderedInsertResult::Duplicate
                }
                Some(_) => OrderedInsertResult::Rejected,
                None => {
                    self.in_flight = Some(message.message_id);
                    OrderedInsertResult::Ready
                }
            };
        }
        if message.sequence.saturating_sub(self.expected_sequence) > max_gap
            || self.reorder_buffer.len() >= max_messages
            || self.reorder_bytes.saturating_add(message.payload.len()) > max_bytes
        {
            return OrderedInsertResult::Rejected;
        }
        match self.reorder_buffer.get(&message.sequence) {
            Some(existing) if existing.message_id == message.message_id => {
                OrderedInsertResult::Duplicate
            }
            Some(_) => OrderedInsertResult::Rejected,
            None => {
                self.reorder_bytes = self.reorder_bytes.saturating_add(message.payload.len());
                self.reorder_buffer.insert(message.sequence, message);
                OrderedInsertResult::Buffered
            }
        }
    }

    fn acknowledge(&mut self, message_id: MessageId) -> Option<OrderedMessage> {
        if self.in_flight != Some(message_id) {
            return None;
        }
        self.in_flight = None;
        self.expected_sequence = self.expected_sequence.saturating_add(1);
        let next = self.reorder_buffer.remove(&self.expected_sequence)?;
        self.reorder_bytes = self.reorder_bytes.saturating_sub(next.payload.len());
        self.in_flight = Some(next.message_id);
        Some(next)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct IncomingCompletion {
    pub(crate) recovery_epoch: u64,
    pub(crate) next_ordered: Option<OrderedMessage>,
}

/// 接收端去重 key：Peer 业务作用域 + Channel + MessageId。
///
/// SessionId 被刻意排除——每条 Connection 都有新 SessionId，而 MessageId 在
/// 新连接重放时保持不变，去重必须跨越 Session 换代（§20）。
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct DedupKey {
    peer_id: String,
    channel_id: String,
    message_id: MessageId,
}

/// 接收端仍在等待应用 ACK 的状态；两种状态都不受 processed history 淘汰。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ActiveIncomingState {
    InFlight,
    OrderedBuffered,
}

/// Active receive record。`recovery_epoch` 只记录最后一次观测到的 wire 连接
/// 代数（用于 ACK 回显），deadline 不是 dedup TTL；不存在 epoch 门控。
#[derive(Clone, Copy, Debug)]
struct ActiveIncomingRecord {
    ack_deadline: Option<Instant>,
    recovery_epoch: u64,
    state: ActiveIncomingState,
}

/// 已完成消息的有限历史，只承担重复判断，不承担 ACK gate。
#[derive(Clone, Copy, Debug)]
struct ProcessedDedupRecord {
    expires_at: Instant,
    last_seen_at: Instant,
    recovery_epoch: u64,
}

/// Application ACK 超时后的可观测摘要。
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct IncomingTimeout {
    pub(crate) peer_id: String,
    pub(crate) channel_id: String,
    pub(crate) message_id: MessageId,
    pub(crate) ordered_channel_failed: bool,
}

struct DeliveryStore {
    pending: HashMap<MessageId, PendingMessage>,
    pending_bytes: usize,
    terminal_outcomes: HashMap<MessageId, (String, DeliveryTerminalOutcome)>,
    next_sequences: HashMap<(String, String), u64>,
    /// Peer 作用域连接代数（每次 Connection Ready 递增一次）。只用于 wire。
    recovery_epochs: HashMap<String, u64>,
    /// 未完成的应用处理状态。这里的记录不受 dedup TTL/LRU 影响。
    incoming_active: HashMap<DedupKey, ActiveIncomingRecord>,
    /// 已完成消息的有限去重历史；只有这里允许 TTL 和容量淘汰。
    processed_dedup: HashMap<DedupKey, ProcessedDedupRecord>,
    ordered: HashMap<(String, String), OrderedChannelState>,
    failed_ordered: HashSet<(String, String)>,
}

impl DeliveryStore {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
            pending_bytes: 0,
            terminal_outcomes: HashMap::new(),
            next_sequences: HashMap::new(),
            recovery_epochs: HashMap::new(),
            incoming_active: HashMap::new(),
            processed_dedup: HashMap::new(),
            ordered: HashMap::new(),
            failed_ordered: HashSet::new(),
        }
    }
}

/// App Scope 内唯一的应用层投递状态 owner。
///
/// `retry_workers` 记录每个 Peer 是否已有重试任务在运行。重试任务本身由连接
/// 层注入发送回调后运行（它需要 transport），但**所有权/注册表属于本业务
/// manager**：key 是 Peer 业务作用域，绝不是 ConnectionSession 的 SessionId，
/// 因此能跨越 transport 丢失继续存活（无连接时暂停、新连接到来后恢复）。
pub struct DeliveryManager {
    config: DeliveryConfig,
    store: Mutex<DeliveryStore>,
    retry_workers: RwLock<HashSet<String>>,
}

impl Default for DeliveryManager {
    fn default() -> Self {
        Self::new()
    }
}

impl DeliveryManager {
    pub fn new() -> Self {
        Self::with_config(DeliveryConfig::default())
    }

    pub fn with_config(config: DeliveryConfig) -> Self {
        Self {
            config,
            store: Mutex::new(DeliveryStore::new()),
            retry_workers: RwLock::new(HashSet::new()),
        }
    }

    /// 尝试为 Peer 认领一个重试 worker。返回 `true` 表示调用方应当启动该
    /// Peer 的循环（本调用首次认领）；返回 `false` 表示已有一个 worker 在跑。
    ///
    /// key 是 Peer 业务作用域；worker 在无连接时暂停、在新 ConnectionSession
    /// 出现后恢复，因此一次认领即可覆盖后续所有重连。
    pub async fn try_start_retry_worker(&self, peer_id: &str) -> bool {
        self.retry_workers.write().await.insert(peer_id.to_string())
    }

    /// 释放 Peer 的重试 worker 注册。仅在 worker 启动失败（supervisor 已
    /// stopping）时调用，允许下一次连接重新认领。
    pub async fn stop_retry_worker(&self, peer_id: &str) {
        self.retry_workers.write().await.remove(peer_id);
    }

    /// 入队逻辑 payload，并分配永不随 Connection 重置的 Channel Sequence。
    ///
    /// `peer_id` 是业务作用域（对端设备标识），不是任何 Connection 的
    /// SessionId；它跨 Connection 稳定，保证未 ACK 消息在新连接上恢复。
    pub async fn enqueue(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_inner(
            peer_id,
            channel_id,
            payload,
            policy,
            retry_policy,
            Instant::now(),
        )
        .await
    }

    #[cfg(test)]
    async fn enqueue_at(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_inner(peer_id, channel_id, payload, policy, retry_policy, now)
            .await
    }

    async fn enqueue_at_inner(
        &self,
        peer_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        if !is_valid_scope_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        if payload.len() > self.config.max_payload_bytes {
            return Err(DeliveryError::PayloadTooLarge);
        }
        if !retry_policy.is_valid() {
            return Err(DeliveryError::InvalidRetryPolicy);
        }

        let mut store = self.store.lock().await;
        if policy == DeliveryPolicy::LatestState {
            let obsolete = store
                .pending
                .iter()
                .filter(|(_, message)| {
                    message.peer_id == peer_id
                        && message.channel_id == channel_id
                        && message.policy == DeliveryPolicy::LatestState
                })
                .map(|(message_id, _)| *message_id)
                .collect::<Vec<_>>();
            for message_id in obsolete {
                let peer_id = store
                    .pending
                    .get(&message_id)
                    .map(|message| message.peer_id.clone());
                if let Some(peer_id) = peer_id {
                    record_terminal(
                        &mut store,
                        message_id,
                        peer_id,
                        DeliveryTerminalOutcome::Cancelled,
                    );
                }
                remove_pending(&mut store, &message_id);
            }
        }
        if policy != DeliveryPolicy::BestEffort
            && (store.pending.len() >= self.config.max_pending_messages
                || store.pending_bytes.saturating_add(payload.len())
                    > self.config.max_pending_bytes)
        {
            return Err(DeliveryError::QueueFull);
        }

        let sequence_key = (peer_id.to_string(), channel_id.to_string());
        let sequence = store.next_sequences.entry(sequence_key).or_insert(0);
        let message_sequence = *sequence;
        *sequence = sequence.saturating_add(1);
        let recovery_epoch = store
            .recovery_epochs
            .get(peer_id)
            .copied()
            .unwrap_or_default();
        let message_id = next_message_id(&store.pending, &store.terminal_outcomes);
        let message = PendingMessage {
            message_id,
            peer_id: peer_id.to_string(),
            channel_id: channel_id.to_string(),
            sequence: message_sequence,
            payload,
            policy,
            state: DeliveryState::Queued,
            attempts: 0,
            created_at: now,
            expires_at: retry_policy.ttl.map(|ttl| now + ttl),
            recovery_epoch,
            retry_policy,
            next_retry_at: now,
            retry_bytes: 0,
        };
        if policy != DeliveryPolicy::BestEffort {
            store.pending_bytes += message.payload.len();
            store.pending.insert(message_id, message.clone());
        }
        Ok(message)
    }

    /// 取出一个可发送消息并消耗一次 retry attempt。
    pub async fn begin_send(
        &self,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<PendingMessage>, DeliveryError> {
        self.begin_send_inner(None, message_id, now).await
    }

    /// Peer-scoped form of [`Self::begin_send`].  A caller that owns a
    /// business operation must provide the peer identity explicitly; a
    /// MessageId alone is not sufficient to claim a send lease.
    pub(crate) async fn begin_send_for_peer(
        &self,
        peer_id: &str,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<DeliverySendAttempt>, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        let message = self
            .begin_send_inner(Some(peer_id), message_id, now)
            .await?;
        Ok(message.map(|message| DeliverySendAttempt {
            peer_id: peer_id.to_string(),
            message_id,
            attempt: message.attempts,
            message,
        }))
    }

    async fn begin_send_inner(
        &self,
        expected_peer_id: Option<&str>,
        message_id: MessageId,
        now: Instant,
    ) -> Result<Option<PendingMessage>, DeliveryError> {
        let mut store = self.store.lock().await;
        let Some(existing) = store.pending.get(&message_id) else {
            return Err(DeliveryError::NotFound);
        };
        if expected_peer_id.is_some_and(|peer_id| existing.peer_id != peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        if is_expired(existing, now) {
            let peer_id = existing.peer_id.clone();
            remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Expired,
            );
            return Err(DeliveryError::Expired);
        }
        let Some(message) = store.pending.get_mut(&message_id) else {
            return Err(DeliveryError::NotFound);
        };
        if matches!(message.state, DeliveryState::Sending) {
            return Ok(None);
        }
        if message.state == DeliveryState::SentUnacked && now < message.next_retry_at {
            return Ok(None);
        }
        if message.state != DeliveryState::Queued && message.state != DeliveryState::SentUnacked {
            return Ok(None);
        }
        if now < message.next_retry_at {
            return Ok(None);
        }
        let next_attempt = message.attempts.saturating_add(1);
        if next_attempt > message.retry_policy.max_attempts {
            let peer_id = message.peer_id.clone();
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Failed,
            );
            return Err(DeliveryError::RetryExhausted);
        }
        let retry_bytes = message
            .retry_bytes
            .saturating_add(u64::from(next_attempt > 1) * message.payload.len() as u64);
        if message
            .retry_policy
            .max_total_retry_bytes
            .is_some_and(|limit| retry_bytes > limit)
        {
            let peer_id = message.peer_id.clone();
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Failed,
            );
            return Err(DeliveryError::RetryExhausted);
        }
        message.attempts = next_attempt;
        message.retry_bytes = retry_bytes;
        message.state = DeliveryState::Sending;
        Ok(Some(message.clone()))
    }

    /// 传输层成功写出消息后等待应用 ACK。
    pub async fn mark_sent(&self, message_id: MessageId, now: Instant) -> bool {
        self.mark_sent_inner(None, None, message_id, now).await
    }

    pub(crate) async fn mark_sent_for_attempt(
        &self,
        attempt: &DeliverySendAttempt,
        now: Instant,
    ) -> bool {
        self.mark_sent_inner(
            Some(&attempt.peer_id),
            Some(attempt.attempt),
            attempt.message_id,
            now,
        )
        .await
    }

    async fn mark_sent_inner(
        &self,
        expected_peer_id: Option<&str>,
        expected_attempt: Option<u32>,
        message_id: MessageId,
        now: Instant,
    ) -> bool {
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get_mut(&message_id) else {
            return false;
        };
        if message.state != DeliveryState::Sending
            || expected_peer_id.is_some_and(|peer_id| message.peer_id != peer_id)
            || expected_attempt.is_some_and(|attempt| message.attempts != attempt)
        {
            return false;
        }
        message.state = DeliveryState::SentUnacked;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        true
    }

    /// 传输层写失败后回到 Pending，或耗尽预算进入 Failed。
    pub async fn mark_send_failed(&self, message_id: MessageId, now: Instant) -> RetryDecision {
        self.mark_send_failed_inner(None, None, message_id, now)
            .await
    }

    pub(crate) async fn mark_send_failed_for_attempt(
        &self,
        attempt: &DeliverySendAttempt,
        now: Instant,
    ) -> RetryDecision {
        self.mark_send_failed_inner(
            Some(&attempt.peer_id),
            Some(attempt.attempt),
            attempt.message_id,
            now,
        )
        .await
    }

    async fn mark_send_failed_inner(
        &self,
        expected_peer_id: Option<&str>,
        expected_attempt: Option<u32>,
        message_id: MessageId,
        now: Instant,
    ) -> RetryDecision {
        let mut store = self.store.lock().await;
        let Some(existing) = store.pending.get(&message_id) else {
            return RetryDecision::NotFound;
        };
        if expected_peer_id.is_some_and(|peer_id| existing.peer_id != peer_id) {
            return RetryDecision::NotFound;
        }
        if is_expired(existing, now) {
            let peer_id = existing.peer_id.clone();
            remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Expired,
            );
            return RetryDecision::Expired;
        }
        let Some(message) = store.pending.get_mut(&message_id) else {
            return RetryDecision::NotFound;
        };
        // A result may arrive after recovery invalidated its lease.  Do not let
        // that stale result requeue or fail a newer attempt.
        if expected_attempt.is_some()
            && (message.state != DeliveryState::Sending
                || expected_attempt.is_some_and(|attempt| message.attempts != attempt))
        {
            return RetryDecision::NotFound;
        }
        if message.attempts >= message.retry_policy.max_attempts
            || message
                .retry_policy
                .max_total_retry_bytes
                .is_some_and(|limit| {
                    message
                        .retry_bytes
                        .saturating_add(message.payload.len() as u64)
                        > limit
                })
        {
            let peer_id = message.peer_id.clone();
            message.state = DeliveryState::Failed;
            remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Failed,
            );
            return RetryDecision::Failed;
        }
        message.state = DeliveryState::Queued;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        RetryDecision::RetryAt(message.next_retry_at)
    }

    /// 按 MessageId 关联 ACK（§20）。一个 ACK 只要是当前作用域中已知的
    /// in-flight MessageId 就有效；已完成 / 未知 MessageId 的 ACK 是 no-op。
    ///
    /// 不再携带 recovery_epoch 门控——连接换代后发送端以同一个 MessageId 重发，
    /// ACK 只需按 MessageId 匹配即可完成。
    pub async fn acknowledge(&self, peer_id: &str, message_id: MessageId) -> AckResult {
        if !is_valid_peer_id(peer_id) {
            return AckResult::Unknown;
        }
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get(&message_id) else {
            return AckResult::Unknown;
        };
        if message.peer_id != peer_id {
            return AckResult::Unknown;
        }
        let peer_id = message.peer_id.clone();
        remove_pending(&mut store, &message_id);
        record_terminal(
            &mut store,
            message_id,
            peer_id,
            DeliveryTerminalOutcome::Acknowledged,
        );
        AckResult::Acknowledged
    }

    /// Return the terminal outcome only when the caller supplies the owning
    /// peer.  This keeps a MessageId from becoming a cross-peer capability.
    #[allow(dead_code)]
    pub(crate) async fn terminal_outcome(
        &self,
        peer_id: &str,
        message_id: MessageId,
    ) -> Option<DeliveryTerminalOutcome> {
        if !is_valid_peer_id(peer_id) {
            return None;
        }
        let store = self.store.lock().await;
        store
            .terminal_outcomes
            .get(&message_id)
            .filter(|(owner, _)| owner == peer_id)
            .map(|(_, outcome)| *outcome)
    }

    /// 新 Connection Ready 后，重置 Peer 作用域的 in-flight 状态并返回恢复批次。
    ///
    /// `peer_id` 是业务作用域；所有该 Peer 未 ACK 的 pending 消息（无论它们在
    /// 哪一条旧 Connection 上入队）都会以**同一个 MessageId** 返回，由上层在
    /// 当前 transport 上重发。
    pub async fn recover_peer(&self, peer_id: &str) -> RecoverySnapshot {
        self.recover_peer_at(peer_id, Instant::now()).await
    }

    pub(crate) async fn recover_peer_checked(
        &self,
        peer_id: &str,
    ) -> Result<RecoverySnapshot, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self.recover_peer(peer_id).await)
    }

    async fn recover_peer_at(&self, peer_id: &str, now: Instant) -> RecoverySnapshot {
        let mut store = self.store.lock().await;
        let epoch = store
            .recovery_epochs
            .entry(peer_id.to_string())
            .and_modify(|epoch| *epoch = epoch.saturating_add(1))
            .or_insert(1);
        let recovery_epoch = *epoch;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.peer_id == peer_id)
            .map(|(message_id, _)| *message_id)
            .collect::<Vec<_>>();
        let mut messages = Vec::new();
        let mut expired = Vec::new();
        for message_id in message_ids {
            let Some(message) = store.pending.get_mut(&message_id) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push((message_id, message.peer_id.clone()));
                continue;
            }
            message.state = DeliveryState::Queued;
            message.next_retry_at = now;
            message.recovery_epoch = recovery_epoch;
            messages.push(message.clone());
        }
        for (message_id, peer_id) in expired {
            remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Expired,
            );
        }
        messages.sort_by_key(|message| message.sequence);
        RecoverySnapshot {
            recovery_epoch,
            messages,
        }
    }

    /// 到达 ACK 超时点的消息重新进入可发送队列。
    pub async fn retryable_messages(&self, peer_id: &str, now: Instant) -> Vec<PendingMessage> {
        let mut store = self.store.lock().await;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.peer_id == peer_id)
            .map(|(message_id, _)| *message_id)
            .collect::<Vec<_>>();
        let mut retryable = Vec::new();
        let mut expired = Vec::new();
        for message_id in message_ids {
            let Some(message) = store.pending.get_mut(&message_id) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push((message_id, message.peer_id.clone()));
            } else if message.state == DeliveryState::SentUnacked && now >= message.next_retry_at {
                message.state = DeliveryState::Queued;
                message.next_retry_at = now;
                retryable.push(message.clone());
            } else if message.state == DeliveryState::Queued && now >= message.next_retry_at {
                retryable.push(message.clone());
            }
        }
        for (message_id, peer_id) in expired {
            remove_pending(&mut store, &message_id);
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Expired,
            );
        }
        retryable.sort_by_key(|message| message.sequence);
        retryable
    }

    pub(crate) async fn retryable_messages_checked(
        &self,
        peer_id: &str,
        now: Instant,
    ) -> Result<Vec<PendingMessage>, DeliveryError> {
        if !is_valid_peer_id(peer_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self.retryable_messages(peer_id, now).await)
    }

    pub async fn cancel(&self, message_id: MessageId) -> bool {
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get_mut(&message_id) else {
            return false;
        };
        let peer_id = message.peer_id.clone();
        message.state = DeliveryState::Cancelled;
        let removed = remove_pending(&mut store, &message_id).is_some();
        if removed {
            record_terminal(
                &mut store,
                message_id,
                peer_id,
                DeliveryTerminalOutcome::Cancelled,
            );
        }
        removed
    }

    /// 接收端在业务 handler 前登记 MessageId（§20）。重复消息只需再次 ACK。
    ///
    /// 去重完全由 `DedupKey{ peer_id, channel_id, message_id }` 驱动；SessionId
    /// 被排除——同一 MessageId 在新 Connection（新 SessionId）上重放时必须命中
    /// 同一个记录。`recovery_epoch` 只记录最后一次观测到的 wire 连接代数，
    /// **不做任何门控**。
    pub async fn begin_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
        now: Instant,
    ) -> DedupDecision {
        let mut store = self.store.lock().await;
        // Application timeout 是独立且显式的生命周期决策；它可以清理超时
        // handler，但下面的普通 dedup TTL 只能淘汰已完成的历史。
        let _ = expire_incoming_locked(&mut store, now, Some(peer_id));
        prune_processed_dedup(&mut store, now);
        let key = dedup_key(peer_id, channel_id, message_id);
        let scope = (peer_id.to_string(), channel_id.to_string());
        if store.failed_ordered.contains(&scope) {
            return DedupDecision::ChannelFailed;
        }
        if let Some(record) = store.incoming_active.get_mut(&key) {
            // 同一 MessageId 的重放：只更新 ACK 回显绑定的连接代数，保留业务
            // 处理状态（绝不能把尚未完成 ACK 的 handler 当成已处理消息）。
            record.recovery_epoch = recovery_epoch;
            return DedupDecision::DuplicateInFlight;
        }
        if let Some(record) = store.processed_dedup.get_mut(&key) {
            // 已完成消息的重复帧：更新回显代数并续期 processed history，但不再
            // 重新进入应用 handler。
            record.recovery_epoch = recovery_epoch;
            record.last_seen_at = now;
            record.expires_at = now + self.config.dedup_ttl;
            return DedupDecision::DuplicateProcessed;
        }
        if store.incoming_active.len() >= MAX_ACTIVE_INCOMING_RECORDS {
            // Active records are never removed to satisfy the processed-history
            // bound. Rejecting new work preserves the ACK contract and gives
            // existing handlers a chance to finish or time out explicitly.
            return DedupDecision::CapacityExceeded;
        }
        store.incoming_active.insert(
            key,
            ActiveIncomingRecord {
                ack_deadline: Some(now + self.config.application_ack_timeout),
                recovery_epoch,
                state: ActiveIncomingState::InFlight,
            },
        );
        assert_delivery_invariants(&store);
        DedupDecision::New
    }

    pub(crate) async fn begin_incoming_checked(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
        now: Instant,
    ) -> Result<DedupDecision, DeliveryError> {
        if !is_valid_peer_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self
            .begin_incoming(peer_id, channel_id, message_id, recovery_epoch, now)
            .await)
    }

    /// Insert a newly deduplicated message into its SessionBoundOrdered state.
    ///
    /// Only the message at `expected_sequence` becomes application-visible;
    /// later messages stay in a bounded buffer until the current in-flight
    /// message is acknowledged.
    pub(crate) async fn accept_ordered(&self, message: OrderedMessage) -> OrderedInsertResult {
        self.accept_ordered_at(message, Instant::now()).await
    }

    async fn accept_ordered_at(
        &self,
        message: OrderedMessage,
        now: Instant,
    ) -> OrderedInsertResult {
        if !is_valid_peer_id(&message.peer_id) || !is_valid_scope_id(&message.channel_id) {
            return OrderedInsertResult::Rejected;
        }
        let mut store = self.store.lock().await;
        let key = (message.peer_id.clone(), message.channel_id.clone());
        if store.failed_ordered.contains(&key) {
            return OrderedInsertResult::Rejected;
        }
        let active_key = dedup_key(&message.peer_id, &message.channel_id, message.message_id);
        if !store.incoming_active.contains_key(&active_key) {
            debug_assert!(
                false,
                "ordered message must have an active dedup record before insertion"
            );
            return OrderedInsertResult::Rejected;
        }
        let result = store.ordered.entry(key).or_default().insert(
            message,
            self.config.max_reorder_messages,
            self.config.max_reorder_bytes,
            self.config.max_sequence_gap,
        );
        match result {
            OrderedInsertResult::Ready => {
                if let Some(record) = store.incoming_active.get_mut(&active_key) {
                    record.state = ActiveIncomingState::InFlight;
                    record.ack_deadline = Some(now + self.config.application_ack_timeout);
                }
            }
            OrderedInsertResult::Buffered => {
                if let Some(record) = store.incoming_active.get_mut(&active_key) {
                    record.state = ActiveIncomingState::OrderedBuffered;
                    record.ack_deadline = None;
                }
            }
            OrderedInsertResult::Duplicate | OrderedInsertResult::Rejected => {}
        }
        assert_delivery_invariants(&store);
        result
    }

    pub(crate) async fn complete_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<IncomingCompletion> {
        self.complete_incoming_at(peer_id, channel_id, message_id, Instant::now())
            .await
    }

    pub(crate) async fn complete_incoming_checked(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Result<Option<IncomingCompletion>, DeliveryError> {
        if !is_valid_peer_id(peer_id) || !is_valid_scope_id(channel_id) {
            return Err(DeliveryError::InvalidScope);
        }
        Ok(self
            .complete_incoming(peer_id, channel_id, message_id)
            .await)
    }

    async fn complete_incoming_at(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
        now: Instant,
    ) -> Option<IncomingCompletion> {
        let mut store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        let active = *store.incoming_active.get(&key)?;
        let scope = (peer_id.to_string(), channel_id.to_string());

        if let Some(ordered) = store.ordered.get(&scope) {
            match ordered.in_flight {
                Some(current) if current == message_id => {}
                Some(_) => return None,
                None if active.state == ActiveIncomingState::OrderedBuffered => return None,
                None => {}
            }
        } else if active.state == ActiveIncomingState::OrderedBuffered {
            debug_assert!(false, "buffered ordered record lost its channel state");
            return None;
        }

        // 先检查下一个 buffer 条目再修改 ordering gate，保证 active record
        // 与 reorder_buffer 的 invariant 在同一把 store 锁内保持原子一致。
        let next_key = store.ordered.get(&scope).and_then(|ordered| {
            (ordered.in_flight == Some(message_id))
                .then(|| ordered.expected_sequence.saturating_add(1))
                .and_then(|sequence| ordered.reorder_buffer.get(&sequence))
                .map(|next| dedup_key(&next.peer_id, &next.channel_id, next.message_id))
        });
        if let Some(next_key) = next_key.as_ref() {
            let next_active = store.incoming_active.get(next_key);
            if !matches!(
                next_active,
                Some(record) if record.state == ActiveIncomingState::OrderedBuffered
            ) {
                debug_assert!(false, "ordered buffer entry has no active dedup record");
                return None;
            }
        }

        let next_ordered = if let Some(ordered) = store.ordered.get_mut(&scope) {
            match ordered.in_flight {
                Some(current) if current == message_id => ordered.acknowledge(message_id),
                Some(_) => return None,
                None => None,
            }
        } else {
            None
        };
        store.incoming_active.remove(&key)?;
        if let Some(next) = next_ordered.as_ref() {
            let next_key = dedup_key(&next.peer_id, &next.channel_id, next.message_id);
            if let Some(record) = store.incoming_active.get_mut(&next_key) {
                record.state = ActiveIncomingState::InFlight;
                record.ack_deadline = Some(now + self.config.application_ack_timeout);
            } else {
                debug_assert!(false, "ordered next message lost its active record");
                return None;
            }
        }
        remember_processed(
            &mut store,
            key,
            ProcessedDedupRecord {
                expires_at: now + self.config.dedup_ttl,
                last_seen_at: now,
                recovery_epoch: active.recovery_epoch,
            },
            self.config.dedup_max_entries,
        );
        assert_delivery_invariants(&store);
        Some(IncomingCompletion {
            recovery_epoch: active.recovery_epoch,
            next_ordered,
        })
    }

    /// Return the last observed wire connection generation for a received message.
    ///
    /// Only used to echo the sender's generation inside a DeliveryAck; the
    /// ACK correlation itself is MessageId-based and never gates on it.
    pub async fn incoming_recovery_epoch(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<u64> {
        let store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        store
            .incoming_active
            .get(&key)
            .map(|record| record.recovery_epoch)
            .or_else(|| {
                store
                    .processed_dedup
                    .get(&key)
                    .map(|record| record.recovery_epoch)
            })
    }

    /// 当前 Peer 作用域的连接代数（每次 Connection Ready 递增一次）。
    ///
    /// 集成测试用：观察发送端在重连/显式 recovery 后递增了连接代数。仅测试
    /// 构建暴露；生产代码不使用该只读访问器。
    #[cfg(test)]
    pub(crate) async fn current_peer_recovery_epoch(&self, peer_id: &str) -> u64 {
        let store = self.store.lock().await;
        store
            .recovery_epochs
            .get(peer_id)
            .copied()
            .unwrap_or_default()
    }

    pub async fn abandon_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> bool {
        let mut store = self.store.lock().await;
        let key = dedup_key(peer_id, channel_id, message_id);
        if !store.incoming_active.contains_key(&key) {
            return false;
        }
        let scope = (peer_id.to_string(), channel_id.to_string());
        let ordered = store.ordered.get(&scope).is_some_and(|state| {
            state.in_flight == Some(message_id)
                || state
                    .reorder_buffer
                    .values()
                    .any(|message| message.message_id == message_id)
        });
        if ordered {
            let _ = fail_ordered_channel(&mut store, &scope);
        } else {
            store.incoming_active.remove(&key);
        }
        assert_delivery_invariants(&store);
        true
    }

    /// 拒绝尚未进入 ordered buffer 的消息。它与应用显式 abandon 分开，避免
    /// malformed/超限 packet 意外使健康的 ordered channel 进入 Failed。
    pub(crate) async fn reject_incoming(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> bool {
        let mut store = self.store.lock().await;
        let removed = store
            .incoming_active
            .remove(&dedup_key(peer_id, channel_id, message_id))
            .is_some();
        assert_delivery_invariants(&store);
        removed
    }

    /// Explicitly closes a Peer's receive-side state (用户显式断开/清理)。
    ///
    /// 仅显式断开时调用；transport 丢失（Session 被销毁）**不会**调用它——接收端
    /// 的 dedup/ordered 状态必须跨 Connection 存活，新连接才能按 MessageId 去重、
    /// 并在有序通道上从上次断点继续。Outgoing pending 消息保持独立，不在此清理。
    ///
    /// 显式断开会放弃在途 dedup 记录（incoming_active）、已完成消息历史
    /// （processed_dedup）与 Failed 通道标记（failed_ordered），但**保留**有序通道
    /// 的健康断点（expected_sequence）——与发送端保留 `next_sequences` 计数器对称：
    /// 两端在显式断开并重连后都从各自断点继续，有序投递无缝恢复，不会出现接收端
    /// 从 0 重新计数而发送端继续 5、6、7 造成的永久空洞。仍待重发的 pending 消息会
    /// 在重连后重建 dedup 记录并重新插入保留的 ordered 状态；已 ACK 消息不在发送端
    /// pending 中，不会被重发。
    pub(crate) async fn close_peer(&self, peer_id: &str) {
        let mut store = self.store.lock().await;
        store
            .incoming_active
            .retain(|key, _| key.peer_id != peer_id);
        store
            .processed_dedup
            .retain(|key, _| key.peer_id != peer_id);
        // 保留有序断点：只丢弃尚未释放的 in-flight / reorder 消息（重连后由 pending
        // 重放重建 dedup 记录），绝不重置 expected_sequence。
        for (scope, ordered) in &mut store.ordered {
            if scope.0 == peer_id {
                ordered.in_flight = None;
                ordered.reorder_buffer.clear();
                ordered.reorder_bytes = 0;
            }
        }
        store.failed_ordered.retain(|(peer, _)| peer != peer_id);
        assert_delivery_invariants(&store);
    }

    /// 扫描应用 ACK 超时。非有序消息只释放 active 记录；严格有序通道会
    /// 整体进入 Failed 并清空缓冲，绝不自动跳过缺失的 Sequence。
    pub(crate) async fn expire_incoming(
        &self,
        peer_id: &str,
        now: Instant,
    ) -> Vec<IncomingTimeout> {
        let mut store = self.store.lock().await;
        let expired = expire_incoming_locked(&mut store, now, Some(peer_id));
        assert_delivery_invariants(&store);
        expired
    }

    #[cfg(test)]
    pub(crate) async fn incoming_state_counts(&self) -> (usize, usize, usize) {
        let store = self.store.lock().await;
        let reorder_messages = store
            .ordered
            .values()
            .map(|state| state.reorder_buffer.len())
            .sum();
        (
            store.incoming_active.len(),
            store.processed_dedup.len(),
            reorder_messages,
        )
    }

    #[cfg(test)]
    async fn incoming_record_state(
        &self,
        peer_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<(ActiveIncomingState, Option<Instant>)> {
        let store = self.store.lock().await;
        store
            .incoming_active
            .get(&dedup_key(peer_id, channel_id, message_id))
            .map(|record| (record.state, record.ack_deadline))
    }

    #[cfg(test)]
    async fn pending_len(&self) -> usize {
        self.store.lock().await.pending.len()
    }
}

fn next_message_id(
    pending: &HashMap<MessageId, PendingMessage>,
    terminal_outcomes: &HashMap<MessageId, (String, DeliveryTerminalOutcome)>,
) -> MessageId {
    loop {
        let mut bytes = [0u8; MESSAGE_ID_BYTES];
        rand::thread_rng().fill_bytes(&mut bytes);
        let candidate = MessageId(bytes);
        if !pending.contains_key(&candidate) && !terminal_outcomes.contains_key(&candidate) {
            return candidate;
        }
    }
}

fn record_terminal(
    store: &mut DeliveryStore,
    message_id: MessageId,
    peer_id: String,
    outcome: DeliveryTerminalOutcome,
) {
    if store.terminal_outcomes.len() >= MAX_TERMINAL_OUTCOMES {
        if let Some(oldest) = store.terminal_outcomes.keys().next().copied() {
            store.terminal_outcomes.remove(&oldest);
        }
    }
    store
        .terminal_outcomes
        .entry(message_id)
        .or_insert((peer_id, outcome));
}

fn is_expired(message: &PendingMessage, now: Instant) -> bool {
    message
        .expires_at
        .is_some_and(|expires_at| now >= expires_at)
}

fn remove_pending(store: &mut DeliveryStore, message_id: &MessageId) -> Option<PendingMessage> {
    let message = store.pending.remove(message_id)?;
    store.pending_bytes = store.pending_bytes.saturating_sub(message.payload.len());
    Some(message)
}

fn dedup_key(peer_id: &str, channel_id: &str, message_id: MessageId) -> DedupKey {
    DedupKey {
        peer_id: peer_id.to_string(),
        channel_id: channel_id.to_string(),
        message_id,
    }
}

fn prune_processed_dedup(store: &mut DeliveryStore, now: Instant) {
    store
        .processed_dedup
        .retain(|_, record| record.expires_at > now);
}

fn remember_processed(
    store: &mut DeliveryStore,
    key: DedupKey,
    record: ProcessedDedupRecord,
    max_entries: usize,
) {
    if max_entries == 0 {
        // 零窗口仍会保留 active record 到当前 ACK，只是不保留 ACK 后的
        // duplicate history。
        return;
    }
    store
        .processed_dedup
        .retain(|_, existing| existing.expires_at > record.last_seen_at);
    while store.processed_dedup.len() >= max_entries {
        let oldest = store
            .processed_dedup
            .iter()
            .min_by_key(|(_, existing)| existing.last_seen_at)
            .map(|(key, _)| key.clone());
        let Some(oldest) = oldest else {
            break;
        };
        store.processed_dedup.remove(&oldest);
    }
    store.processed_dedup.insert(key, record);
}

fn fail_ordered_channel(store: &mut DeliveryStore, scope: &(String, String)) -> HashSet<DedupKey> {
    let mut affected = HashSet::new();
    if let Some(ordered) = store.ordered.remove(scope) {
        if let Some(message_id) = ordered.in_flight {
            affected.insert(dedup_key(&scope.0, &scope.1, message_id));
        }
        for message in ordered.reorder_buffer.into_values() {
            affected.insert(dedup_key(
                &message.peer_id,
                &message.channel_id,
                message.message_id,
            ));
        }
    }
    for key in store
        .incoming_active
        .keys()
        .filter(|key| key.peer_id == scope.0 && key.channel_id == scope.1)
        .cloned()
        .collect::<Vec<_>>()
    {
        affected.insert(key);
    }
    for key in &affected {
        store.incoming_active.remove(key);
    }
    store.failed_ordered.insert(scope.clone());
    affected
}

fn expire_incoming_locked(
    store: &mut DeliveryStore,
    now: Instant,
    peer_id: Option<&str>,
) -> Vec<IncomingTimeout> {
    let timed_out = store
        .incoming_active
        .iter()
        .filter_map(|(key, record)| {
            if !peer_id.is_none_or(|peer| key.peer_id == peer) {
                return None;
            }
            match record.state {
                ActiveIncomingState::InFlight => {
                    debug_assert!(
                        record.ack_deadline.is_some(),
                        "in-flight record is missing its application ACK deadline"
                    );
                    record
                        .ack_deadline
                        .filter(|deadline| now >= *deadline)
                        .map(|_| (key.clone(), *record))
                }
                ActiveIncomingState::OrderedBuffered => {
                    debug_assert!(
                        record.ack_deadline.is_none(),
                        "ordered buffered record must not have an application ACK deadline"
                    );
                    None
                }
            }
        })
        .collect::<Vec<_>>();
    let mut ordered_scopes = HashSet::new();
    let mut expired = Vec::new();
    for (key, record) in timed_out {
        let scope = (key.peer_id.clone(), key.channel_id.clone());
        let is_ordered = record.state == ActiveIncomingState::OrderedBuffered
            || store
                .ordered
                .get(&scope)
                .is_some_and(|ordered| ordered.in_flight == Some(key.message_id));
        if is_ordered {
            ordered_scopes.insert(scope);
        } else if store.incoming_active.remove(&key).is_some() {
            expired.push(IncomingTimeout {
                peer_id: key.peer_id,
                channel_id: key.channel_id,
                message_id: key.message_id,
                ordered_channel_failed: false,
            });
        }
    }
    for scope in ordered_scopes {
        let affected = fail_ordered_channel(store, &scope);
        for key in affected {
            expired.push(IncomingTimeout {
                peer_id: key.peer_id,
                channel_id: key.channel_id,
                message_id: key.message_id,
                ordered_channel_failed: true,
            });
        }
    }
    expired
}

#[cfg(debug_assertions)]
fn assert_delivery_invariants(store: &DeliveryStore) {
    for (key, record) in &store.incoming_active {
        assert!(
            !store.processed_dedup.contains_key(key),
            "active incoming record also exists in processed history"
        );
        match record.state {
            ActiveIncomingState::InFlight => {
                assert!(
                    record.ack_deadline.is_some(),
                    "in-flight record is missing its application ACK deadline"
                );
            }
            ActiveIncomingState::OrderedBuffered => {
                assert!(
                    record.ack_deadline.is_none(),
                    "ordered buffered record must not have an application ACK deadline"
                );
                let ordered = store
                    .ordered
                    .get(&(key.peer_id.clone(), key.channel_id.clone()))
                    .expect("ordered buffered record lost its channel state");
                assert!(
                    ordered
                        .reorder_buffer
                        .values()
                        .any(|message| message.message_id == key.message_id),
                    "ordered buffered record is missing from reorder_buffer"
                );
            }
        }
    }
    for (scope, ordered) in &store.ordered {
        if let Some(message_id) = ordered.in_flight {
            let key = dedup_key(&scope.0, &scope.1, message_id);
            assert!(
                store
                    .incoming_active
                    .get(&key)
                    .is_some_and(|record| { record.state == ActiveIncomingState::InFlight }),
                "ordered in-flight message is missing its active record"
            );
        }
        for message in ordered.reorder_buffer.values() {
            let key = dedup_key(&message.peer_id, &message.channel_id, message.message_id);
            assert!(
                store
                    .incoming_active
                    .get(&key)
                    .is_some_and(|record| { record.state == ActiveIncomingState::OrderedBuffered }),
                "reorder_buffer message is missing its active record"
            );
        }
    }
}

#[cfg(not(debug_assertions))]
fn assert_delivery_invariants(_store: &DeliveryStore) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn retry_policy() -> RetryPolicy {
        RetryPolicy {
            max_attempts: 3,
            initial_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(4),
            ttl: Some(Duration::from_secs(30)),
            max_total_retry_bytes: Some(32),
        }
    }

    fn config() -> DeliveryConfig {
        DeliveryConfig {
            max_pending_messages: 4,
            max_pending_bytes: 32,
            max_payload_bytes: 16,
            dedup_max_entries: 4,
            dedup_ttl: Duration::from_secs(10),
            application_ack_timeout: Duration::from_secs(5 * 60),
            max_reorder_messages: 2,
            max_reorder_bytes: 8,
            max_sequence_gap: 4,
        }
    }

    const SHORT_ACK_TIMEOUT: Duration = Duration::from_millis(50);

    fn short_timeout_config() -> DeliveryConfig {
        DeliveryConfig {
            application_ack_timeout: SHORT_ACK_TIMEOUT,
            ..config()
        }
    }

    fn ordered_message(sequence: u64, message_id: u8) -> OrderedMessage {
        OrderedMessage {
            peer_id: "peer-a".into(),
            // wire 信封的 SessionId：单测中仅随 OrderedMessage 传递，不做 key。
            session_id: "session-a".into(),
            channel_id: "control".into(),
            message_id: MessageId([message_id; MESSAGE_ID_BYTES]),
            sequence,
            policy: DeliveryPolicy::SessionBoundOrdered,
            payload: vec![message_id],
        }
    }

    #[test]
    fn ordered_channel_releases_only_the_next_contiguous_message() {
        let mut state = OrderedChannelState::default();
        assert_eq!(
            state.insert(ordered_message(2, 2), 4, 16, 4),
            OrderedInsertResult::Buffered
        );
        assert_eq!(
            state.insert(ordered_message(1, 1), 4, 16, 4),
            OrderedInsertResult::Buffered
        );
        assert_eq!(
            state.insert(ordered_message(0, 0), 4, 16, 4),
            OrderedInsertResult::Ready
        );
        assert_eq!(
            state
                .acknowledge(MessageId([0; MESSAGE_ID_BYTES]))
                .map(|message| message.sequence),
            Some(1)
        );
        assert_eq!(
            state
                .acknowledge(MessageId([1; MESSAGE_ID_BYTES]))
                .map(|message| message.sequence),
            Some(2)
        );
        assert_eq!(state.acknowledge(MessageId([2; MESSAGE_ID_BYTES])), None);
    }

    #[test]
    fn ordered_channel_rejects_sequence_gap_and_reorder_overflow() {
        let mut state = OrderedChannelState::default();
        assert_eq!(
            state.insert(ordered_message(5, 5), 4, 16, 4),
            OrderedInsertResult::Rejected
        );
        assert_eq!(
            state.insert(ordered_message(2, 2), 1, 16, 4),
            OrderedInsertResult::Buffered
        );
        assert_eq!(
            state.insert(ordered_message(3, 3), 1, 16, 4),
            OrderedInsertResult::Rejected
        );
        assert_eq!(
            state.insert(
                OrderedMessage {
                    payload: vec![0; 17],
                    ..ordered_message(1, 1)
                },
                4,
                16,
                4,
            ),
            OrderedInsertResult::Rejected
        );
    }

    #[tokio::test]
    async fn ordered_delivery_waits_for_application_ack_before_releasing_buffer() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        for (sequence, id) in [(0, 0), (2, 2), (1, 1)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            let result = manager.accept_ordered(message).await;
            if sequence == 0 {
                assert_eq!(result, OrderedInsertResult::Ready);
            } else {
                assert_eq!(result, OrderedInsertResult::Buffered);
            }
        }

        let first = manager
            .complete_incoming("peer-a", "control", MessageId([0; MESSAGE_ID_BYTES]))
            .await
            .expect("first ordered message should be ACKable");
        assert_eq!(
            first.next_ordered.as_ref().map(|message| message.sequence),
            Some(1)
        );
        let second = manager
            .complete_incoming("peer-a", "control", MessageId([1; MESSAGE_ID_BYTES]))
            .await
            .expect("second ordered message should be ACKable after release");
        assert_eq!(
            second.next_ordered.as_ref().map(|message| message.sequence),
            Some(2)
        );
    }

    #[tokio::test]
    async fn ordered_buffered_message_does_not_keep_an_ack_deadline() {
        let manager = DeliveryManager::with_config(short_timeout_config());
        let now = Instant::now();
        for (sequence, id) in [(0, 60), (1, 61)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered_at(message, now).await,
                if sequence == 0 {
                    OrderedInsertResult::Ready
                } else {
                    OrderedInsertResult::Buffered
                }
            );
        }
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([61; MESSAGE_ID_BYTES]))
                .await,
            Some((ActiveIncomingState::OrderedBuffered, None))
        );

        let head_ack_at = now + Duration::from_millis(25);
        let completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([60; MESSAGE_ID_BYTES]),
                head_ack_at,
            )
            .await
            .expect("head message should be ACKable");
        assert_eq!(
            completion
                .next_ordered
                .as_ref()
                .map(|message| message.sequence),
            Some(1)
        );
        let promoted_deadline = head_ack_at + SHORT_ACK_TIMEOUT;
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([61; MESSAGE_ID_BYTES]))
                .await,
            Some((ActiveIncomingState::InFlight, Some(promoted_deadline)))
        );

        let old_deadline = now + SHORT_ACK_TIMEOUT;
        assert!(manager
            .expire_incoming("peer-a", old_deadline + Duration::from_millis(1))
            .await
            .is_empty());
        assert!(manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([61; MESSAGE_ID_BYTES]),
                old_deadline + Duration::from_millis(1),
            )
            .await
            .is_some());
    }

    #[tokio::test]
    async fn ordered_buffer_promotion_gets_a_full_ack_timeout_window() {
        let manager = DeliveryManager::with_config(short_timeout_config());
        let now = Instant::now();
        for (sequence, id) in [(0, 62), (1, 63)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered_at(message, now).await,
                if sequence == 0 {
                    OrderedInsertResult::Ready
                } else {
                    OrderedInsertResult::Buffered
                }
            );
        }

        let head_ack_at = now + Duration::from_millis(49);
        let completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([62; MESSAGE_ID_BYTES]),
                head_ack_at,
            )
            .await
            .expect("head message should be ACKable");
        assert_eq!(
            completion
                .next_ordered
                .as_ref()
                .map(|message| message.sequence),
            Some(1)
        );
        let promoted_deadline = head_ack_at + SHORT_ACK_TIMEOUT;
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([63; MESSAGE_ID_BYTES]))
                .await,
            Some((ActiveIncomingState::InFlight, Some(promoted_deadline)))
        );

        assert!(manager
            .expire_incoming("peer-a", promoted_deadline - Duration::from_millis(1),)
            .await
            .is_empty());
        let expired = manager
            .expire_incoming("peer-a", promoted_deadline + Duration::from_millis(1))
            .await;
        assert_eq!(expired.len(), 1);
        assert!(expired[0].ordered_channel_failed);
        assert_eq!(manager.incoming_state_counts().await, (0, 1, 0));
    }

    #[tokio::test]
    async fn ordered_buffered_messages_restart_ack_timeout_in_sequence() {
        let manager = DeliveryManager::with_config(short_timeout_config());
        let now = Instant::now();
        for (sequence, id) in [(0, 64), (1, 65), (2, 66)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered_at(message, now).await,
                if sequence == 0 {
                    OrderedInsertResult::Ready
                } else {
                    OrderedInsertResult::Buffered
                }
            );
        }
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([65; MESSAGE_ID_BYTES]))
                .await,
            Some((ActiveIncomingState::OrderedBuffered, None))
        );
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([66; MESSAGE_ID_BYTES]))
                .await,
            Some((ActiveIncomingState::OrderedBuffered, None))
        );

        let first_ack_at = now + Duration::from_millis(25);
        let first_completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([64; MESSAGE_ID_BYTES]),
                first_ack_at,
            )
            .await
            .expect("first message should be ACKable");
        assert_eq!(
            first_completion
                .next_ordered
                .as_ref()
                .map(|message| message.sequence),
            Some(1)
        );
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([65; MESSAGE_ID_BYTES]))
                .await,
            Some((
                ActiveIncomingState::InFlight,
                Some(first_ack_at + SHORT_ACK_TIMEOUT),
            ))
        );
        assert!(manager
            .expire_incoming("peer-a", now + Duration::from_millis(51))
            .await
            .is_empty());

        let second_ack_at = now + Duration::from_millis(60);
        let second_completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([65; MESSAGE_ID_BYTES]),
                second_ack_at,
            )
            .await
            .expect("second message should be ACKable after release");
        assert_eq!(
            second_completion
                .next_ordered
                .as_ref()
                .map(|message| message.sequence),
            Some(2)
        );
        assert_eq!(
            manager
                .incoming_record_state("peer-a", "control", MessageId([66; MESSAGE_ID_BYTES]))
                .await,
            Some((
                ActiveIncomingState::InFlight,
                Some(second_ack_at + SHORT_ACK_TIMEOUT),
            ))
        );
        assert!(manager
            .expire_incoming("peer-a", now + Duration::from_millis(101))
            .await
            .is_empty());

        let final_completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([66; MESSAGE_ID_BYTES]),
                now + Duration::from_millis(105),
            )
            .await
            .expect("third message should be ACKable after release");
        assert!(final_completion.next_ordered.is_none());
        assert_eq!(manager.incoming_state_counts().await, (0, 3, 0));
    }

    #[tokio::test]
    async fn inflight_survives_processed_dedup_ttl_until_application_ack() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message_id = MessageId([20; MESSAGE_ID_BYTES]);
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );

        // 11 seconds exceeds this test's processed-history TTL, but remains
        // below the independent application ACK timeout.
        for id in [21, 22] {
            assert_eq!(
                manager
                    .begin_incoming(
                        "peer-a",
                        "control",
                        MessageId([id; MESSAGE_ID_BYTES]),
                        1,
                        now + Duration::from_secs(11),
                    )
                    .await,
                DedupDecision::New
            );
        }
        assert_eq!(manager.incoming_state_counts().await.0, 3);
        assert!(manager
            .complete_incoming("peer-a", "control", message_id)
            .await
            .is_some());
    }

    #[tokio::test]
    async fn ordered_buffer_survives_processed_dedup_ttl_and_releases_in_sequence() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        for (sequence, id) in [(2, 2), (1, 1)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered(message).await,
                OrderedInsertResult::Buffered
            );
        }

        let first = ordered_message(0, 0);
        assert_eq!(
            manager
                .begin_incoming(
                    &first.peer_id,
                    &first.channel_id,
                    first.message_id,
                    1,
                    now + Duration::from_secs(11),
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(first).await,
            OrderedInsertResult::Ready
        );

        let mut released = Vec::new();
        for id in [0, 1, 2] {
            let completion = manager
                .complete_incoming_at(
                    "peer-a",
                    "control",
                    MessageId([id; MESSAGE_ID_BYTES]),
                    now + Duration::from_secs(11),
                )
                .await
                .expect("ordered message should be ACKable");
            released.push(id);
            if id < 2 {
                assert_eq!(
                    completion
                        .next_ordered
                        .as_ref()
                        .map(|message| message.sequence),
                    Some(u64::from(id + 1))
                );
            } else {
                assert!(completion.next_ordered.is_none());
            }
        }
        assert_eq!(released, vec![0, 1, 2]);
        assert_eq!(manager.incoming_state_counts().await, (0, 3, 0));
    }

    #[tokio::test]
    async fn processed_history_pressure_never_evicts_active_or_ordered_buffered() {
        let mut limited = config();
        limited.dedup_max_entries = 2;
        let manager = DeliveryManager::with_config(limited);
        let now = Instant::now();

        let first = ordered_message(0, 0);
        assert_eq!(
            manager
                .begin_incoming(&first.peer_id, &first.channel_id, first.message_id, 1, now,)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(first).await,
            OrderedInsertResult::Ready
        );
        let buffered = ordered_message(1, 1);
        assert_eq!(
            manager
                .begin_incoming(
                    &buffered.peer_id,
                    &buffered.channel_id,
                    buffered.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(buffered).await,
            OrderedInsertResult::Buffered
        );

        for (offset, id) in [10u8, 11, 12].into_iter().enumerate() {
            let at = now + Duration::from_secs((offset + 1) as u64);
            let message_id = MessageId([id; MESSAGE_ID_BYTES]);
            assert_eq!(
                manager
                    .begin_incoming("peer-a", "history", message_id, 1, at)
                    .await,
                DedupDecision::New
            );
            assert!(manager
                .complete_incoming_at("peer-a", "history", message_id, at)
                .await
                .is_some());
        }
        assert_eq!(manager.incoming_state_counts().await, (2, 2, 1));

        assert!(manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([0; MESSAGE_ID_BYTES]),
                now + Duration::from_secs(5),
            )
            .await
            .is_some());
        assert!(manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([1; MESSAGE_ID_BYTES]),
                now + Duration::from_secs(5),
            )
            .await
            .is_some());
    }

    #[tokio::test]
    async fn processed_history_is_the_only_state_evicted_by_capacity() {
        let mut limited = config();
        limited.dedup_max_entries = 2;
        let manager = DeliveryManager::with_config(limited);
        let now = Instant::now();
        for (offset, id) in [30u8, 31, 32].into_iter().enumerate() {
            let at = now + Duration::from_secs(offset as u64);
            let message_id = MessageId([id; MESSAGE_ID_BYTES]);
            assert_eq!(
                manager
                    .begin_incoming("peer-a", "control", message_id, 1, at)
                    .await,
                DedupDecision::New
            );
            assert!(manager
                .complete_incoming_at("peer-a", "control", message_id, at)
                .await
                .is_some());
        }
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([30; MESSAGE_ID_BYTES]),
                    1,
                    now + Duration::from_secs(4),
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([31; MESSAGE_ID_BYTES]),
                    1,
                    now + Duration::from_secs(4),
                )
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([32; MESSAGE_ID_BYTES]),
                    1,
                    now + Duration::from_secs(4),
                )
                .await,
            DedupDecision::DuplicateProcessed
        );
    }

    #[tokio::test]
    async fn application_ack_timeout_fails_ordered_channel_without_skipping_sequence() {
        let manager = DeliveryManager::with_config(short_timeout_config());
        let now = Instant::now();
        let timeout_at = now + SHORT_ACK_TIMEOUT + Duration::from_millis(1);
        for (sequence, id) in [(0, 40), (1, 41)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert!(matches!(
                manager.accept_ordered_at(message, now).await,
                OrderedInsertResult::Ready | OrderedInsertResult::Buffered
            ));
        }
        let expired = manager.expire_incoming("peer-a", timeout_at).await;
        assert_eq!(expired.len(), 2);
        assert!(expired.iter().all(|timeout| timeout.ordered_channel_failed));
        assert_eq!(manager.incoming_state_counts().await, (0, 0, 0));
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([42; MESSAGE_ID_BYTES]),
                    1,
                    timeout_at,
                )
                .await,
            DedupDecision::ChannelFailed
        );
        manager.close_peer("peer-a").await;
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([42; MESSAGE_ID_BYTES]),
                    1,
                    timeout_at,
                )
                .await,
            DedupDecision::New
        );
    }

    #[tokio::test]
    async fn closing_session_clears_active_incoming_and_ordered_buffer() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        for (sequence, id) in [(0, 50), (1, 51)] {
            let message = ordered_message(sequence, id);
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            let result = manager.accept_ordered(message).await;
            assert!(matches!(
                result,
                OrderedInsertResult::Ready | OrderedInsertResult::Buffered
            ));
        }
        manager.close_peer("peer-a").await;
        assert_eq!(manager.incoming_state_counts().await, (0, 0, 0));
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([50; MESSAGE_ID_BYTES]),
                    1,
                    now + Duration::from_secs(1),
                )
                .await,
            DedupDecision::New
        );
    }

    /// 把发送端 pending 消息转换为接收端 OrderedMessage（message_id 必须一致，
    /// 才能命中 begin_incoming 创建的 active dedup 记录）。
    fn ordered_from_pending(message: &PendingMessage) -> OrderedMessage {
        OrderedMessage {
            peer_id: message.peer_id.clone(),
            session_id: "session-a".into(),
            channel_id: message.channel_id.clone(),
            message_id: message.message_id,
            sequence: message.sequence,
            policy: message.policy,
            payload: message.payload.clone(),
        }
    }

    #[tokio::test]
    async fn explicit_close_preserves_ordered_anchor_and_resumes_without_wedge() {
        // §40 显式断开：close_peer 保留有序通道的 expected_sequence 断点，与发送端
        // 保留 next_sequences 计数器对称——两端重连后从各自断点继续。修复前 close_peer
        // 清空 ordered 状态，接收端从 expected_sequence=0 重新开始，而发送端继续发
        // 5、6、7：seq5 因间隔超限被 Rejected，通道永久卡死且 expire_incoming 不失败
        // （OrderedBuffered 无 ack_deadline），静默丢消息。
        let manager = DeliveryManager::with_config(DeliveryConfig {
            max_pending_messages: 16,
            max_pending_bytes: 64,
            ..config()
        });
        let now = Instant::now();

        // 发送端入队有序消息 seq 0..5；seq5 是断线时仍 pending（未 ACK）的消息。
        let mut pending = Vec::new();
        for sequence in 0..6u64 {
            pending.push(
                manager
                    .enqueue_at(
                        "peer-a",
                        "control",
                        vec![sequence as u8],
                        DeliveryPolicy::SessionBoundOrdered,
                        retry_policy(),
                        now,
                    )
                    .await
                    .expect("enqueue ordered message"),
            );
        }

        // 接收端投递 seq 0..4 → expected_sequence 推进到 5。
        for message in pending.iter().take(5) {
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        1,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered(ordered_from_pending(message)).await,
                OrderedInsertResult::Ready
            );
            manager
                .complete_incoming(&message.peer_id, &message.channel_id, message.message_id)
                .await
                .expect("delivered ordered message");
        }

        // 断线：seq5 仍 pending，可经 MessageId 重发（发送端 next_sequences 不受
        // close_peer 影响，新的入队继续从 6 编号）。
        assert_eq!(manager.pending_len().await, 6);
        let resent = manager
            .begin_send(pending[5].message_id, now)
            .await
            .expect("begin resend")
            .expect("resendable");
        assert_eq!(resent.message_id, pending[5].message_id);

        // 双方显式断开：close_peer 放弃在途 dedup/历史/失败标记，但保留有序断点；
        // 本单实例中一次调用同时模拟发送端（next_sequences 保留）与接收端
        // （expected_sequence 保留）两侧的清理。
        manager.close_peer("peer-a").await;

        // 重连：发送端新入队 seq 6、7。
        for sequence in 6..8u64 {
            pending.push(
                manager
                    .enqueue_at(
                        "peer-a",
                        "control",
                        vec![sequence as u8],
                        DeliveryPolicy::SessionBoundOrdered,
                        retry_policy(),
                        now,
                    )
                    .await
                    .expect("enqueue new ordered message"),
            );
        }

        // 接收端重建 dedup 记录并把 seq5 重新插入保留的 ordered 状态 → 必须 Ready，
        // 修复前因 expected_sequence 被重置为 0、间隔超限而被 Rejected，通道卡死。
        let surviving = &pending[5];
        assert_eq!(
            manager
                .begin_incoming(
                    &surviving.peer_id,
                    &surviving.channel_id,
                    surviving.message_id,
                    2,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .accept_ordered(ordered_from_pending(surviving))
                .await,
            OrderedInsertResult::Ready
        );

        // seq6、7 缓冲，seq5 ACK 后按序释放 5、6、7，无空洞。
        for message in pending.iter().skip(6) {
            assert_eq!(
                manager
                    .begin_incoming(
                        &message.peer_id,
                        &message.channel_id,
                        message.message_id,
                        2,
                        now,
                    )
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                manager.accept_ordered(ordered_from_pending(message)).await,
                OrderedInsertResult::Buffered
            );
        }
        let mut released = Vec::new();
        for message in pending.iter().skip(5) {
            let completion = manager
                .complete_incoming(&message.peer_id, &message.channel_id, message.message_id)
                .await
                .expect("ordered message must be ACKable after reconnect");
            released.push(message.sequence);
            if let Some(next) = completion.next_ordered {
                assert_eq!(next.sequence, message.sequence.saturating_add(1));
            }
        }
        assert_eq!(released, vec![5, 6, 7]);
    }

    #[tokio::test]
    async fn recovery_preserves_sequence_and_rejects_stale_ack() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let first = manager
            .enqueue_at(
                "peer-a",
                "control",
                b"one".to_vec(),
                DeliveryPolicy::AckedDeduplicated,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue first");
        let second = manager
            .enqueue_at(
                "peer-a",
                "control",
                b"two".to_vec(),
                DeliveryPolicy::SessionBoundOrdered,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue second");
        assert_eq!(first.sequence, 0);
        assert_eq!(second.sequence, 1);

        let sent = manager
            .begin_send(first.message_id, now)
            .await
            .expect("begin send")
            .expect("sendable");
        assert_eq!(sent.attempts, 1);
        assert_eq!(sent.payload, b"one");
        assert!(manager.mark_sent(first.message_id, now).await);

        let recovery = manager
            .recover_peer_at("peer-a", now + Duration::from_secs(1))
            .await;
        assert_eq!(recovery.recovery_epoch, 1);
        assert_eq!(
            recovery
                .messages
                .iter()
                .map(|message| message.sequence)
                .collect::<Vec<_>>(),
            vec![0, 1]
        );
        // §20：ACK 只按 MessageId 关联——即使携带了过时/未对齐的连接代数，
        // 只要该 MessageId 仍在 pending 中就完成；recover 后以同一 MessageId
        // 重发，ACK 不需要等待 epoch 对齐。
        let resent = manager
            .begin_send(first.message_id, now + Duration::from_secs(1))
            .await
            .expect("begin resend")
            .expect("resendable");
        assert_eq!(resent.recovery_epoch, recovery.recovery_epoch);
        assert_eq!(resent.attempts, 2);
        assert_eq!(
            manager.acknowledge("peer-a", first.message_id).await,
            AckResult::Acknowledged
        );
        assert_eq!(manager.pending_len().await, 1);
        // 已完成 MessageId 的重复 ACK 是无害的 no-op（不再报 StaleEpoch）。
        assert_eq!(
            manager.acknowledge("peer-a", first.message_id).await,
            AckResult::Unknown
        );
    }

    #[tokio::test]
    async fn pending_message_keeps_plaintext_for_retry() {
        let manager = DeliveryManager::with_config(config());
        let message = manager
            .enqueue(
                "peer-a",
                "control",
                b"plaintext".to_vec(),
                DeliveryPolicy::Acked,
                retry_policy(),
            )
            .await
            .expect("enqueue message");
        assert_eq!(message.payload, b"plaintext");
        let sent = manager
            .begin_send(message.message_id, Instant::now())
            .await
            .expect("begin send")
            .expect("sendable");
        assert_eq!(sent.payload, b"plaintext");
    }

    #[tokio::test]
    async fn retry_policy_is_bounded_and_expiry_removes_pending() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message = manager
            .enqueue_at(
                "peer-a",
                "control",
                b"payload".to_vec(),
                DeliveryPolicy::Acked,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue");
        manager
            .begin_send(message.message_id, now)
            .await
            .expect("begin")
            .expect("sendable");
        assert!(manager.mark_sent(message.message_id, now).await);
        assert!(manager
            .retryable_messages("peer-a", now + Duration::from_millis(999))
            .await
            .is_empty());
        assert_eq!(
            manager
                .retryable_messages("peer-a", now + Duration::from_secs(1))
                .await
                .len(),
            1
        );
        assert_eq!(
            manager
                .mark_send_failed(message.message_id, now + Duration::from_secs(1))
                .await,
            RetryDecision::RetryAt(now + Duration::from_secs(2))
        );
        assert_eq!(
            manager
                .recover_peer_at("peer-a", now + Duration::from_secs(31))
                .await
                .messages
                .len(),
            0
        );
        assert_eq!(manager.pending_len().await, 0);
    }

    #[tokio::test]
    async fn latest_state_replaces_only_older_latest_state() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let old = manager
            .enqueue_at(
                "peer-a",
                "mouse",
                vec![1],
                DeliveryPolicy::LatestState,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue old");
        let new = manager
            .enqueue_at(
                "peer-a",
                "mouse",
                vec![2],
                DeliveryPolicy::LatestState,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue new");
        assert_eq!(manager.pending_len().await, 1);
        assert!(matches!(
            manager.begin_send(old.message_id, now).await,
            Err(DeliveryError::NotFound)
        ));
        assert_eq!(
            manager
                .begin_send(new.message_id, now)
                .await
                .expect("begin new")
                .expect("new sendable")
                .payload,
            vec![2]
        );
    }

    #[tokio::test]
    async fn dedup_window_is_scoped_and_expires() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message_id = MessageId([7; MESSAGE_ID_BYTES]);
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::DuplicateInFlight
        );
        assert!(manager
            .complete_incoming("peer-a", "control", message_id)
            .await
            .is_some());
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 2, now)
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert_eq!(
            manager
                .incoming_recovery_epoch("peer-a", "control", message_id)
                .await,
            Some(2)
        );
        // §20：连接代数不再门控去重——携带较低代数的重放帧仍是 DuplicateProcessed，
        // 只是不能再次进入应用 handler（对已完成消息的重复 ACK 是无害 no-op）。
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert!(manager
            .complete_incoming("peer-a", "control", message_id)
            .await
            .is_none());
        assert_eq!(
            manager
                .begin_incoming("peer-b", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    message_id,
                    1,
                    now + Duration::from_secs(11),
                )
                .await,
            DedupDecision::New
        );
    }

    #[tokio::test]
    async fn recovery_epoch_updates_do_not_turn_inflight_into_processed() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message_id = MessageId([8; MESSAGE_ID_BYTES]);

        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    message_id,
                    2,
                    now + Duration::from_secs(1),
                )
                .await,
            DedupDecision::DuplicateInFlight
        );
        assert_eq!(
            manager
                .incoming_recovery_epoch("peer-a", "control", message_id)
                .await,
            Some(2)
        );
        assert_eq!(
            manager
                .complete_incoming("peer-a", "control", message_id)
                .await,
            Some(IncomingCompletion {
                recovery_epoch: 2,
                next_ordered: None,
            })
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    message_id,
                    2,
                    now + Duration::from_secs(1),
                )
                .await,
            DedupDecision::DuplicateProcessed
        );
    }

    #[tokio::test]
    async fn best_effort_skips_pending_and_reliable_queue_is_bounded() {
        let manager = DeliveryManager::with_config(DeliveryConfig {
            max_pending_messages: 1,
            max_pending_bytes: 4,
            max_payload_bytes: 4,
            dedup_max_entries: 4,
            dedup_ttl: Duration::from_secs(10),
            application_ack_timeout: Duration::from_secs(5 * 60),
            max_reorder_messages: 2,
            max_reorder_bytes: 8,
            max_sequence_gap: 4,
        });
        let now = Instant::now();
        let best_effort = manager
            .enqueue_at(
                "peer-a",
                "video",
                vec![1, 2, 3, 4],
                DeliveryPolicy::BestEffort,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue best effort");
        assert_eq!(manager.pending_len().await, 0);
        assert!(matches!(
            manager.begin_send(best_effort.message_id, now).await,
            Err(DeliveryError::NotFound)
        ));

        manager
            .enqueue_at(
                "peer-a",
                "control",
                vec![9, 9, 9, 9],
                DeliveryPolicy::Acked,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue reliable");
        assert!(matches!(
            manager
                .enqueue_at(
                    "peer-a",
                    "control",
                    vec![8],
                    DeliveryPolicy::Acked,
                    retry_policy(),
                    now,
                )
                .await,
            Err(DeliveryError::QueueFull)
        ));
    }

    #[tokio::test]
    async fn peer_scoped_send_lease_and_terminal_outcome_are_idempotent() {
        let manager = DeliveryManager::with_config(DeliveryConfig {
            max_pending_messages: 4,
            max_pending_bytes: 32,
            max_payload_bytes: 16,
            ..config()
        });
        let now = Instant::now();
        let message = manager
            .enqueue_at(
                "peer-a",
                "control",
                b"payload".to_vec(),
                DeliveryPolicy::Acked,
                RetryPolicy {
                    max_attempts: 1,
                    ..retry_policy()
                },
                now,
            )
            .await
            .expect("enqueue");

        assert!(matches!(
            manager
                .begin_send_for_peer("peer-b", message.message_id, now)
                .await,
            Err(DeliveryError::InvalidScope)
        ));
        let attempt = manager
            .begin_send_for_peer("peer-a", message.message_id, now)
            .await
            .expect("begin peer-scoped send")
            .expect("first attempt");
        assert!(manager
            .begin_send_for_peer("peer-a", message.message_id, now)
            .await
            .expect("second lease query")
            .is_none());

        assert_eq!(
            manager.mark_send_failed_for_attempt(&attempt, now).await,
            RetryDecision::Failed
        );
        assert_eq!(
            manager.terminal_outcome("peer-a", message.message_id).await,
            Some(DeliveryTerminalOutcome::Failed)
        );
        assert_eq!(
            manager.mark_send_failed_for_attempt(&attempt, now).await,
            RetryDecision::NotFound
        );
        assert_eq!(
            manager.terminal_outcome("peer-b", message.message_id).await,
            None
        );
    }

    #[test]
    fn delivery_identity_requires_peer_scope_and_excludes_session() {
        let message_id = MessageId([7; MESSAGE_ID_BYTES]);
        let identity = DeliveryIdentity::new("peer-a", message_id).expect("identity");
        assert_eq!(identity.peer_id, "peer-a");
        assert_eq!(identity.message_id, message_id);
        assert_eq!(
            DeliveryIdentity::new("", message_id),
            Err(DeliveryError::InvalidScope)
        );
    }

    #[tokio::test]
    async fn late_send_result_cannot_settle_a_newer_attempt() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message = manager
            .enqueue_at(
                "peer-a",
                "control",
                b"payload".to_vec(),
                DeliveryPolicy::Acked,
                retry_policy(),
                now,
            )
            .await
            .expect("enqueue");
        let first = manager
            .begin_send_for_peer("peer-a", message.message_id, now)
            .await
            .expect("first begin")
            .expect("first attempt");
        assert_eq!(
            manager.mark_send_failed_for_attempt(&first, now).await,
            RetryDecision::RetryAt(now + Duration::from_secs(1))
        );
        let second = manager
            .begin_send_for_peer("peer-a", message.message_id, now + Duration::from_secs(1))
            .await
            .expect("second begin")
            .expect("second attempt");
        assert_ne!(first.attempt, second.attempt);
        assert!(!manager.mark_sent_for_attempt(&first, now).await);
        assert_eq!(
            manager.mark_send_failed_for_attempt(&first, now).await,
            RetryDecision::NotFound
        );
        assert!(manager.mark_sent_for_attempt(&second, now).await);
    }

    #[tokio::test]
    async fn same_message_id_is_scoped_to_peer_for_incoming_ack() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message_id = MessageId([200; MESSAGE_ID_BYTES]);
        assert_eq!(
            manager
                .begin_incoming_checked("peer-a", "control", message_id, 1, now)
                .await,
            Ok(DedupDecision::New)
        );
        assert_eq!(
            manager
                .begin_incoming_checked("peer-b", "control", message_id, 1, now)
                .await,
            Ok(DedupDecision::New)
        );
        assert!(manager
            .complete_incoming_checked("peer-a", "control", message_id)
            .await
            .expect("peer-a completion")
            .is_some());
        assert!(manager
            .complete_incoming_checked("peer-b", "control", message_id)
            .await
            .expect("peer-b completion")
            .is_some());
        assert_eq!(
            manager
                .begin_incoming_checked("", "control", message_id, 1, now)
                .await,
            Err(DeliveryError::InvalidScope)
        );
    }

    #[test]
    fn delivery_recovery_errors_have_stable_business_names() {
        assert_eq!(
            BusinessRecoveryError::RecoverableTransportLoss.to_string(),
            "RecoverableTransportLoss"
        );
        assert_eq!(
            DeliveryError::Expired.recovery_error(),
            Some(BusinessRecoveryError::OperationExpired)
        );
        assert_eq!(
            RetryDecision::RetryAt(Instant::now()).recovery_error(),
            Some(BusinessRecoveryError::RecoverableTransportLoss)
        );
    }
}
