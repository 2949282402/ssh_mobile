//! 跨 Connection 的应用层投递状态。
//!
//! 这一层只保存可重新编码的业务 payload 和投递元数据，不持有 Quinn/Relay
//! handle。Connection 恢复后由上层取出 `RecoverySnapshot`，在当前 transport
//! 上重新发送；因此 ACK、去重和重试不会绑定到某一条已失效的 Connection。
//!
//! transport-network v2（§19/§20）：跨连接稳定的是业务身份 **PeerId +
//! MessageId + ChannelId**，**不是** Transport Connection 或
//! ConnectionSession。Step 8 之后 Session 与 connection 一一对应且可销毁：
//! 新连接 = 新 SessionId + 新 Noise root。因此本 manager 的 pending / dedup /
//! ordered 状态全部按 **Peer 业务作用域** 保存，绝不用每个连接的 SessionId
//! 作 key；`DeliveryIdentity`（PeerId + MessageId）是发送端 ACK 的稳定键。
//! 连接丢失时本 manager 不会清空
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
    pending: HashMap<DeliveryIdentity, PendingMessage>,
    pending_bytes: usize,
    terminal_outcomes: HashMap<DeliveryIdentity, DeliveryTerminalOutcome>,
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
                .map(|(identity, _)| identity.clone())
                .collect::<Vec<_>>();
            for identity in obsolete {
                if remove_pending(&mut store, &identity).is_some() {
                    record_terminal(&mut store, identity, DeliveryTerminalOutcome::Cancelled);
                }
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
        let message_id = next_message_id(peer_id, &store.pending, &store.terminal_outcomes);
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
            store.pending.insert(
                DeliveryIdentity {
                    peer_id: peer_id.to_string(),
                    message_id,
                },
                message.clone(),
            );
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
        if let Some(peer_id) = expected_peer_id {
            let scoped_identity = DeliveryIdentity {
                peer_id: peer_id.to_string(),
                message_id,
            };
            if !store.pending.contains_key(&scoped_identity)
                && store
                    .pending
                    .keys()
                    .any(|identity| identity.message_id == message_id)
            {
                return Err(DeliveryError::InvalidScope);
            }
        }
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return Err(DeliveryError::NotFound);
        };
        let Some(existing) = store.pending.get(&identity) else {
            return Err(DeliveryError::NotFound);
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
            return Err(DeliveryError::Expired);
        }
        let Some(message) = store.pending.get_mut(&identity) else {
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
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
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
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
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
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return false;
        };
        let Some(message) = store.pending.get_mut(&identity) else {
            return false;
        };
        if message.state != DeliveryState::Sending
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
        let Some(identity) = resolve_pending_identity(&store, expected_peer_id, message_id) else {
            return RetryDecision::NotFound;
        };
        let Some(existing) = store.pending.get(&identity) else {
            return RetryDecision::NotFound;
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
            return RetryDecision::Expired;
        }
        let Some(message) = store.pending.get_mut(&identity) else {
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
            message.state = DeliveryState::Failed;
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Failed);
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
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        if !store.pending.contains_key(&identity) {
            return AckResult::Unknown;
        }
        remove_pending(&mut store, &identity);
        record_terminal(&mut store, identity, DeliveryTerminalOutcome::Acknowledged);
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
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        store.terminal_outcomes.get(&identity).copied()
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
            .map(|(identity, _)| identity.clone())
            .collect::<Vec<_>>();
        let mut messages = Vec::new();
        let mut expired = Vec::new();
        for identity in message_ids {
            let Some(message) = store.pending.get_mut(&identity) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(identity.clone());
                continue;
            }
            message.state = DeliveryState::Queued;
            message.next_retry_at = now;
            message.recovery_epoch = recovery_epoch;
            messages.push(message.clone());
        }
        for identity in expired {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
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
            .map(|(identity, _)| identity.clone())
            .collect::<Vec<_>>();
        let mut retryable = Vec::new();
        let mut expired = Vec::new();
        for identity in message_ids {
            let Some(message) = store.pending.get_mut(&identity) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(identity.clone());
            } else if message.state == DeliveryState::SentUnacked && now >= message.next_retry_at {
                message.state = DeliveryState::Queued;
                message.next_retry_at = now;
                retryable.push(message.clone());
            } else if message.state == DeliveryState::Queued && now >= message.next_retry_at {
                retryable.push(message.clone());
            }
        }
        for identity in expired {
            remove_pending(&mut store, &identity);
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Expired);
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
        let Some(identity) = resolve_pending_identity(&store, None, message_id) else {
            return false;
        };
        let Some(message) = store.pending.get_mut(&identity) else {
            return false;
        };
        message.state = DeliveryState::Cancelled;
        let removed = remove_pending(&mut store, &identity).is_some();
        if removed {
            record_terminal(&mut store, identity, DeliveryTerminalOutcome::Cancelled);
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
    peer_id: &str,
    pending: &HashMap<DeliveryIdentity, PendingMessage>,
    terminal_outcomes: &HashMap<DeliveryIdentity, DeliveryTerminalOutcome>,
) -> MessageId {
    loop {
        let mut bytes = [0u8; MESSAGE_ID_BYTES];
        rand::thread_rng().fill_bytes(&mut bytes);
        let candidate = MessageId(bytes);
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id: candidate,
        };
        if !pending.contains_key(&identity) && !terminal_outcomes.contains_key(&identity) {
            return candidate;
        }
    }
}

fn resolve_pending_identity(
    store: &DeliveryStore,
    expected_peer_id: Option<&str>,
    message_id: MessageId,
) -> Option<DeliveryIdentity> {
    if let Some(peer_id) = expected_peer_id {
        let identity = DeliveryIdentity {
            peer_id: peer_id.to_string(),
            message_id,
        };
        return store.pending.contains_key(&identity).then_some(identity);
    }

    let mut matches = store
        .pending
        .keys()
        .filter(|identity| identity.message_id == message_id)
        .cloned();
    let identity = matches.next()?;
    matches.next().is_none().then_some(identity)
}

fn record_terminal(
    store: &mut DeliveryStore,
    identity: DeliveryIdentity,
    outcome: DeliveryTerminalOutcome,
) {
    if !store.terminal_outcomes.contains_key(&identity)
        && store.terminal_outcomes.len() >= MAX_TERMINAL_OUTCOMES
    {
        if let Some(oldest) = store.terminal_outcomes.keys().next().cloned() {
            store.terminal_outcomes.remove(&oldest);
        }
    }
    store.terminal_outcomes.entry(identity).or_insert(outcome);
}

fn is_expired(message: &PendingMessage, now: Instant) -> bool {
    message
        .expires_at
        .is_some_and(|expires_at| now >= expires_at)
}

fn remove_pending(
    store: &mut DeliveryStore,
    identity: &DeliveryIdentity,
) -> Option<PendingMessage> {
    let message = store.pending.remove(identity)?;
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
#[path = "tests/delivery.rs"]
mod tests;
