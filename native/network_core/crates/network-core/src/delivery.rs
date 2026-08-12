//! 跨 Connection 的应用层投递状态。
//!
//! 这一层只保存可重新编码的业务 payload 和投递元数据，不持有 Quinn/Relay
//! handle。Connection 恢复后由上层取出 `RecoverySnapshot`，在当前 transport
//! 上重新发送；因此 ACK、去重和重试不会绑定到某一条已失效的 Connection。

use rand::RngCore;
use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::Mutex;

use crate::crypto::CryptoMode;

const MAX_SCOPE_ID_BYTES: usize = 128;
const MESSAGE_ID_BYTES: usize = 16;

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
#[derive(Clone, Debug)]
pub struct PendingMessage {
    pub message_id: MessageId,
    pub session_id: String,
    pub channel_id: String,
    pub sequence: u64,
    pub payload: Vec<u8>,
    /// Logical plaintext mode. The payload itself is never replaced with a
    /// Route-specific ciphertext while it waits for retry/recovery.
    pub(crate) crypto_mode: CryptoMode,
    pub policy: DeliveryPolicy,
    pub state: DeliveryState,
    pub attempts: u32,
    pub created_at: Instant,
    pub expires_at: Option<Instant>,
    pub recovery_epoch: u64,
    retry_policy: RetryPolicy,
    next_retry_at: Instant,
    retry_bytes: u64,
}

/// 一次 Connection Ready 后交给传输层的恢复批次。
#[derive(Clone, Debug)]
pub struct RecoverySnapshot {
    pub recovery_epoch: u64,
    pub messages: Vec<PendingMessage>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AckResult {
    Acknowledged,
    Unknown,
    StaleEpoch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DedupDecision {
    New,
    DuplicateInFlight,
    DuplicateProcessed,
    StaleEpoch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    RetryAt(Instant),
    Failed,
    Expired,
    NotFound,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DeliveryError {
    #[error("session and channel identifiers are required")]
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

/// Delivery 队列和去重窗口的边界。
#[derive(Clone, Copy, Debug)]
pub struct DeliveryConfig {
    pub max_pending_messages: usize,
    pub max_pending_bytes: usize,
    pub max_payload_bytes: usize,
    pub dedup_max_entries: usize,
    pub dedup_ttl: Duration,
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

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct DedupKey {
    session_id: String,
    channel_id: String,
    message_id: MessageId,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DedupState {
    InFlight,
    Processed,
}

#[derive(Clone, Copy, Debug)]
struct DedupRecord {
    expires_at: Instant,
    recovery_epoch: u64,
    state: DedupState,
}

struct DeliveryStore {
    pending: HashMap<MessageId, PendingMessage>,
    pending_bytes: usize,
    next_sequences: HashMap<(String, String), u64>,
    recovery_epochs: HashMap<String, u64>,
    dedup: HashMap<DedupKey, DedupRecord>,
    ordered: HashMap<(String, String), OrderedChannelState>,
}

impl DeliveryStore {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
            pending_bytes: 0,
            next_sequences: HashMap::new(),
            recovery_epochs: HashMap::new(),
            dedup: HashMap::new(),
            ordered: HashMap::new(),
        }
    }
}

/// App Scope 内唯一的应用层投递状态 owner。
pub struct DeliveryManager {
    config: DeliveryConfig,
    store: Mutex<DeliveryStore>,
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
        }
    }

    /// 入队逻辑 payload，并分配永不随 Connection 重置的 Channel Sequence。
    pub async fn enqueue(
        &self,
        session_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_with_crypto(
            session_id,
            channel_id,
            payload,
            policy,
            CryptoMode::E2ee,
            retry_policy,
        )
        .await
    }

    /// Enqueue logical plaintext together with its application crypto mode.
    /// Every later send derives a fresh ciphertext from this stored plaintext.
    pub(crate) async fn enqueue_with_crypto(
        &self,
        session_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        crypto_mode: CryptoMode,
        retry_policy: RetryPolicy,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_with_crypto(
            session_id,
            channel_id,
            payload,
            policy,
            crypto_mode,
            retry_policy,
            Instant::now(),
        )
        .await
    }

    #[cfg(test)]
    async fn enqueue_at(
        &self,
        session_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        self.enqueue_at_with_crypto(
            session_id,
            channel_id,
            payload,
            policy,
            CryptoMode::E2ee,
            retry_policy,
            now,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn enqueue_at_with_crypto(
        &self,
        session_id: &str,
        channel_id: &str,
        payload: Vec<u8>,
        policy: DeliveryPolicy,
        crypto_mode: CryptoMode,
        retry_policy: RetryPolicy,
        now: Instant,
    ) -> Result<PendingMessage, DeliveryError> {
        if session_id.is_empty()
            || channel_id.is_empty()
            || session_id.len() > MAX_SCOPE_ID_BYTES
            || channel_id.len() > MAX_SCOPE_ID_BYTES
        {
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
                    message.session_id == session_id
                        && message.channel_id == channel_id
                        && message.policy == DeliveryPolicy::LatestState
                })
                .map(|(message_id, _)| *message_id)
                .collect::<Vec<_>>();
            for message_id in obsolete {
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

        let sequence_key = (session_id.to_string(), channel_id.to_string());
        let sequence = store.next_sequences.entry(sequence_key).or_insert(0);
        let message_sequence = *sequence;
        *sequence = sequence.saturating_add(1);
        let recovery_epoch = store
            .recovery_epochs
            .get(session_id)
            .copied()
            .unwrap_or_default();
        let message_id = next_message_id(&store.pending);
        let message = PendingMessage {
            message_id,
            session_id: session_id.to_string(),
            channel_id: channel_id.to_string(),
            sequence: message_sequence,
            payload,
            crypto_mode,
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
        let mut store = self.store.lock().await;
        let Some(existing) = store.pending.get(&message_id) else {
            return Err(DeliveryError::NotFound);
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &message_id);
            return Err(DeliveryError::Expired);
        }
        let current_epoch = store
            .recovery_epochs
            .get(&existing.session_id)
            .copied()
            .unwrap_or_default();
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
            message.state = DeliveryState::Failed;
            let _ = remove_pending(&mut store, &message_id);
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
            let _ = remove_pending(&mut store, &message_id);
            return Err(DeliveryError::RetryExhausted);
        }
        message.attempts = next_attempt;
        message.retry_bytes = retry_bytes;
        message.recovery_epoch = current_epoch;
        message.state = DeliveryState::Sending;
        Ok(Some(message.clone()))
    }

    /// 传输层成功写出消息后等待应用 ACK。
    pub async fn mark_sent(&self, message_id: MessageId, now: Instant) -> bool {
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get_mut(&message_id) else {
            return false;
        };
        if message.state != DeliveryState::Sending {
            return false;
        }
        message.state = DeliveryState::SentUnacked;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        true
    }

    /// 传输层写失败后回到 Pending，或耗尽预算进入 Failed。
    pub async fn mark_send_failed(&self, message_id: MessageId, now: Instant) -> RetryDecision {
        let mut store = self.store.lock().await;
        let Some(existing) = store.pending.get(&message_id) else {
            return RetryDecision::NotFound;
        };
        if is_expired(existing, now) {
            remove_pending(&mut store, &message_id);
            return RetryDecision::Expired;
        }
        let Some(message) = store.pending.get_mut(&message_id) else {
            return RetryDecision::NotFound;
        };
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
            remove_pending(&mut store, &message_id);
            return RetryDecision::Failed;
        }
        message.state = DeliveryState::Queued;
        message.next_retry_at = now + message.retry_policy.delay_for_attempt(message.attempts);
        RetryDecision::RetryAt(message.next_retry_at)
    }

    /// 只接受匹配当前 Recovery Epoch 的应用 ACK，随后删除 Pending。
    pub async fn acknowledge(
        &self,
        session_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
    ) -> AckResult {
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get(&message_id) else {
            return AckResult::Unknown;
        };
        if message.session_id != session_id || message.recovery_epoch != recovery_epoch {
            return AckResult::StaleEpoch;
        }
        remove_pending(&mut store, &message_id);
        AckResult::Acknowledged
    }

    /// 新 Connection Ready 后，重置当前 Session 的 in-flight 状态并返回恢复批次。
    pub async fn recover_session(&self, session_id: &str) -> RecoverySnapshot {
        self.recover_session_at(session_id, Instant::now()).await
    }

    async fn recover_session_at(&self, session_id: &str, now: Instant) -> RecoverySnapshot {
        let mut store = self.store.lock().await;
        let epoch = store
            .recovery_epochs
            .entry(session_id.to_string())
            .and_modify(|epoch| *epoch = epoch.saturating_add(1))
            .or_insert(1);
        let recovery_epoch = *epoch;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.session_id == session_id)
            .map(|(message_id, _)| *message_id)
            .collect::<Vec<_>>();
        let mut messages = Vec::new();
        let mut expired = Vec::new();
        for message_id in message_ids {
            let Some(message) = store.pending.get_mut(&message_id) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(message_id);
                continue;
            }
            message.state = DeliveryState::Queued;
            message.next_retry_at = now;
            message.recovery_epoch = recovery_epoch;
            messages.push(message.clone());
        }
        for message_id in expired {
            remove_pending(&mut store, &message_id);
        }
        messages.sort_by_key(|message| message.sequence);
        RecoverySnapshot {
            recovery_epoch,
            messages,
        }
    }

    /// 到达 ACK 超时点的消息重新进入可发送队列。
    pub async fn retryable_messages(&self, session_id: &str, now: Instant) -> Vec<PendingMessage> {
        let mut store = self.store.lock().await;
        let message_ids = store
            .pending
            .iter()
            .filter(|(_, message)| message.session_id == session_id)
            .map(|(message_id, _)| *message_id)
            .collect::<Vec<_>>();
        let mut retryable = Vec::new();
        let mut expired = Vec::new();
        for message_id in message_ids {
            let Some(message) = store.pending.get_mut(&message_id) else {
                continue;
            };
            if is_expired(message, now) {
                expired.push(message_id);
            } else if message.state == DeliveryState::SentUnacked && now >= message.next_retry_at {
                message.state = DeliveryState::Queued;
                message.next_retry_at = now;
                retryable.push(message.clone());
            } else if message.state == DeliveryState::Queued && now >= message.next_retry_at {
                retryable.push(message.clone());
            }
        }
        for message_id in expired {
            remove_pending(&mut store, &message_id);
        }
        retryable.sort_by_key(|message| message.sequence);
        retryable
    }

    pub async fn cancel(&self, message_id: MessageId) -> bool {
        let mut store = self.store.lock().await;
        let Some(message) = store.pending.get_mut(&message_id) else {
            return false;
        };
        message.state = DeliveryState::Cancelled;
        remove_pending(&mut store, &message_id).is_some()
    }

    /// 接收端在业务 handler 前登记 MessageId，重复消息只需再次 ACK。
    pub async fn begin_incoming(
        &self,
        session_id: &str,
        channel_id: &str,
        message_id: MessageId,
        recovery_epoch: u64,
        now: Instant,
    ) -> DedupDecision {
        let mut store = self.store.lock().await;
        prune_dedup(&mut store, now);
        let key = DedupKey {
            session_id: session_id.to_string(),
            channel_id: channel_id.to_string(),
            message_id,
        };
        if let Some(record) = store.dedup.get_mut(&key) {
            if recovery_epoch < record.recovery_epoch {
                return DedupDecision::StaleEpoch;
            }
            if recovery_epoch > record.recovery_epoch {
                // 同一 MessageId 进入更高 RecoveryEpoch 代表 transport 重放。
                // 只更新 ACK 绑定，保留业务处理状态，避免把尚未完成的
                // handler 错误地当成已处理消息而提前 ACK。
                record.recovery_epoch = recovery_epoch;
                record.expires_at = now + self.config.dedup_ttl;
            }
            return match record.state {
                DedupState::InFlight => DedupDecision::DuplicateInFlight,
                DedupState::Processed => DedupDecision::DuplicateProcessed,
            };
        }
        if self.config.dedup_max_entries == 0 {
            return DedupDecision::New;
        }
        while store.dedup.len() >= self.config.dedup_max_entries {
            let oldest = store
                .dedup
                .iter()
                .min_by_key(|(_, record)| record.expires_at)
                .map(|(key, _)| key.clone());
            let Some(oldest) = oldest else {
                break;
            };
            store.dedup.remove(&oldest);
        }
        store.dedup.insert(
            key,
            DedupRecord {
                expires_at: now + self.config.dedup_ttl,
                recovery_epoch,
                state: DedupState::InFlight,
            },
        );
        DedupDecision::New
    }

    /// Insert a newly deduplicated message into its SessionBoundOrdered state.
    ///
    /// Only the message at `expected_sequence` becomes application-visible;
    /// later messages stay in a bounded buffer until the current in-flight
    /// message is acknowledged.
    pub(crate) async fn accept_ordered(&self, message: OrderedMessage) -> OrderedInsertResult {
        let mut store = self.store.lock().await;
        let key = (message.session_id.clone(), message.channel_id.clone());
        store.ordered.entry(key).or_default().insert(
            message,
            self.config.max_reorder_messages,
            self.config.max_reorder_bytes,
            self.config.max_sequence_gap,
        )
    }

    pub(crate) async fn complete_incoming(
        &self,
        session_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<IncomingCompletion> {
        let mut store = self.store.lock().await;
        let key = DedupKey {
            session_id: session_id.to_string(),
            channel_id: channel_id.to_string(),
            message_id,
        };
        let record_state = store.dedup.get(&key)?.state;
        let next_ordered = if let Some(ordered) = store
            .ordered
            .get_mut(&(session_id.to_string(), channel_id.to_string()))
        {
            match ordered.in_flight {
                Some(current) if current == message_id => ordered.acknowledge(message_id),
                Some(_) if record_state == DedupState::Processed => None,
                Some(_) | None => return None,
            }
        } else {
            None
        };
        let record = store.dedup.get_mut(&key)?;
        record.state = DedupState::Processed;
        Some(IncomingCompletion {
            recovery_epoch: record.recovery_epoch,
            next_ordered,
        })
    }

    /// Return the latest transport recovery epoch for a received message.
    ///
    /// The epoch is deliberately kept out of the application ACK command. It
    /// belongs to Delivery recovery state and may change after the application
    /// first observes a message but before it acknowledges that message.
    pub async fn incoming_recovery_epoch(
        &self,
        session_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> Option<u64> {
        let store = self.store.lock().await;
        store
            .dedup
            .get(&DedupKey {
                session_id: session_id.to_string(),
                channel_id: channel_id.to_string(),
                message_id,
            })
            .map(|record| record.recovery_epoch)
    }

    pub async fn abandon_incoming(
        &self,
        session_id: &str,
        channel_id: &str,
        message_id: MessageId,
    ) -> bool {
        let mut store = self.store.lock().await;
        store
            .dedup
            .remove(&DedupKey {
                session_id: session_id.to_string(),
                channel_id: channel_id.to_string(),
                message_id,
            })
            .is_some()
    }

    #[cfg(test)]
    async fn pending_len(&self) -> usize {
        self.store.lock().await.pending.len()
    }
}

fn next_message_id(pending: &HashMap<MessageId, PendingMessage>) -> MessageId {
    loop {
        let mut bytes = [0u8; MESSAGE_ID_BYTES];
        rand::thread_rng().fill_bytes(&mut bytes);
        let candidate = MessageId(bytes);
        if !pending.contains_key(&candidate) {
            return candidate;
        }
    }
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

fn prune_dedup(store: &mut DeliveryStore, now: Instant) {
    store.dedup.retain(|_, record| record.expires_at > now);
}

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
            max_reorder_messages: 2,
            max_reorder_bytes: 8,
            max_sequence_gap: 4,
        }
    }

    fn ordered_message(sequence: u64, message_id: u8) -> OrderedMessage {
        OrderedMessage {
            peer_id: "peer-a".into(),
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
                        &message.session_id,
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
            .complete_incoming("session-a", "control", MessageId([0; MESSAGE_ID_BYTES]))
            .await
            .expect("first ordered message should be ACKable");
        assert_eq!(
            first.next_ordered.as_ref().map(|message| message.sequence),
            Some(1)
        );
        let second = manager
            .complete_incoming("session-a", "control", MessageId([1; MESSAGE_ID_BYTES]))
            .await
            .expect("second ordered message should be ACKable after release");
        assert_eq!(
            second.next_ordered.as_ref().map(|message| message.sequence),
            Some(2)
        );
    }

    #[tokio::test]
    async fn recovery_preserves_sequence_and_rejects_stale_ack() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let first = manager
            .enqueue_at(
                "session-a",
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
                "session-a",
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
        assert_eq!(sent.crypto_mode, CryptoMode::E2ee);
        assert!(manager.mark_sent(first.message_id, now).await);

        let recovery = manager
            .recover_session_at("session-a", now + Duration::from_secs(1))
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
        assert_eq!(
            manager.acknowledge("session-a", first.message_id, 0).await,
            AckResult::StaleEpoch
        );
        let resent = manager
            .begin_send(first.message_id, now + Duration::from_secs(1))
            .await
            .expect("begin resend")
            .expect("resendable");
        assert_eq!(resent.recovery_epoch, recovery.recovery_epoch);
        assert_eq!(resent.attempts, 2);
        assert_eq!(
            manager
                .acknowledge("session-a", first.message_id, recovery.recovery_epoch)
                .await,
            AckResult::Acknowledged
        );
        assert_eq!(manager.pending_len().await, 1);
    }

    #[tokio::test]
    async fn pending_message_keeps_plaintext_and_explicit_crypto_mode() {
        let manager = DeliveryManager::with_config(config());
        let message = manager
            .enqueue_with_crypto(
                "session-a",
                "control",
                b"plaintext".to_vec(),
                DeliveryPolicy::Acked,
                CryptoMode::None,
                retry_policy(),
            )
            .await
            .expect("enqueue message");
        assert_eq!(message.payload, b"plaintext");
        assert_eq!(message.crypto_mode, CryptoMode::None);
        let sent = manager
            .begin_send(message.message_id, Instant::now())
            .await
            .expect("begin send")
            .expect("sendable");
        assert_eq!(sent.payload, b"plaintext");
        assert_eq!(sent.crypto_mode, CryptoMode::None);
    }

    #[tokio::test]
    async fn retry_policy_is_bounded_and_expiry_removes_pending() {
        let manager = DeliveryManager::with_config(config());
        let now = Instant::now();
        let message = manager
            .enqueue_at(
                "session-a",
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
            .retryable_messages("session-a", now + Duration::from_millis(999))
            .await
            .is_empty());
        assert_eq!(
            manager
                .retryable_messages("session-a", now + Duration::from_secs(1))
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
                .recover_session_at("session-a", now + Duration::from_secs(31))
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
                "session-a",
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
                "session-a",
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
                .begin_incoming("session-a", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming("session-a", "control", message_id, 1, now)
                .await,
            DedupDecision::DuplicateInFlight
        );
        assert!(manager
            .complete_incoming("session-a", "control", message_id)
            .await
            .is_some());
        assert_eq!(
            manager
                .begin_incoming("session-a", "control", message_id, 1, now)
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert_eq!(
            manager
                .begin_incoming("session-a", "control", message_id, 2, now)
                .await,
            DedupDecision::DuplicateProcessed
        );
        assert_eq!(
            manager
                .incoming_recovery_epoch("session-a", "control", message_id)
                .await,
            Some(2)
        );
        assert_eq!(
            manager
                .begin_incoming("session-a", "control", message_id, 1, now)
                .await,
            DedupDecision::StaleEpoch
        );
        assert!(manager
            .complete_incoming("session-a", "control", message_id)
            .await
            .is_some());
        assert_eq!(
            manager
                .begin_incoming("session-b", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "session-a",
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
                .begin_incoming("session-a", "control", message_id, 1, now)
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "session-a",
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
                .incoming_recovery_epoch("session-a", "control", message_id)
                .await,
            Some(2)
        );
        assert_eq!(
            manager
                .complete_incoming("session-a", "control", message_id)
                .await,
            Some(IncomingCompletion {
                recovery_epoch: 2,
                next_ordered: None,
            })
        );
        assert_eq!(
            manager
                .begin_incoming(
                    "session-a",
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
            max_reorder_messages: 2,
            max_reorder_bytes: 8,
            max_sequence_gap: 4,
        });
        let now = Instant::now();
        let best_effort = manager
            .enqueue_at(
                "session-a",
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
                "session-a",
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
                    "session-a",
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
}
