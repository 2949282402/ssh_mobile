//! Delivery Manager 与当前 Route 的生产接线。
//!
//! Delivery 只保存可重编码的应用消息；本模块负责在 Connection Ready、
//! ACK、重连和 Route 变化时把同一份 DataMessage 发送到当前 QUIC 或 Relay。
//! 所有发送都以逻辑 SessionId 为边界，不把 MessageId、Sequence 或
//! RecoveryEpoch 存进具体 Connection。

use network_protocol::{
    network_event, AcknowledgeMessageCommand, ChannelMessageEvent, DataMessage, DeliveryAck,
    DeliveryAckedEvent, DeliveryPolicyCode, NetworkError as ProtocolError, NetworkErrorCode,
    NetworkEvent, SendMessageCommand, NETWORK_PROTOCOL_VERSION,
};
use network_quic::MAX_CHANNEL_FRAME_BYTES;
use prost::Message;
use std::sync::Arc;
use std::time::Instant;

use crate::crypto::{self, CryptoMode};
use crate::delivery::{
    AckResult, DedupDecision, DeliveryError, DeliveryPolicy, OrderedInsertResult, OrderedMessage,
    PendingMessage, RecoverySnapshot,
};
use crate::events::{protocol_error, protocol_error_with_peer};
use crate::runtime::{RuntimeState, DELIVERY_RETRY_POLL_INTERVAL};
use crate::session::SessionId;

const MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES: usize = MAX_CHANNEL_FRAME_BYTES - 1024;

/// 将 Dart/Protobuf 命令转换为 Delivery 消息并立即排入当前逻辑 Session。
pub(crate) async fn start_send_message(
    state: Arc<RuntimeState>,
    command: SendMessageCommand,
) -> Result<(), ProtocolError> {
    if command.peer_id.is_empty() || command.channel_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id and channel_id are required",
        ));
    }
    if command.payload.len() > MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "message payload exceeds the channel frame limit",
            "send_message",
            &command.peer_id,
        ));
    }
    let policy = decode_policy(command.policy).ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "unsupported Delivery policy",
            "send_message",
            &command.peer_id,
        )
    })?;
    let crypto_mode = decode_crypto_mode(command.crypto_mode).ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "unsupported application crypto mode",
            "send_message",
            &command.peer_id,
        )
    })?;
    let Some(session_id) = state.sessions.current_session_id(&command.peer_id).await else {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no connected logical Session",
            "send_message",
            &command.peer_id,
        ));
    };
    if !state.sessions.is_connected(&command.peer_id).await {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no connected logical Session",
            "send_message",
            &command.peer_id,
        ));
    }
    let Some(profile) = state.sessions.current_profile(&command.peer_id).await else {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer route has no reliable message capability",
            "send_message",
            &command.peer_id,
        ));
    };
    if !profile.supports(crate::connection::ConnectionCapability::ReliableMessage) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "current route does not support Delivery messages",
            "send_message",
            &command.peer_id,
        ));
    }
    let message = state
        .delivery
        .enqueue_with_crypto(
            &session_id.wire_key(),
            &command.channel_id,
            command.payload,
            policy,
            crypto_mode,
            Default::default(),
        )
        .await
        .map_err(|error| delivery_error(&command.peer_id, error))?;
    ensure_retry_worker(Arc::clone(&state), command.peer_id.clone(), session_id).await;
    let supervisor = Arc::clone(&state.task_supervisor);
    if supervisor
        .spawn_session(
            session_id.wire_key(),
            "delivery-send",
            deliver_pending_message(state, command.peer_id.clone(), session_id, message),
        )
        .is_none()
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "network runtime is stopping",
            "send_message",
            &command.peer_id,
        ));
    }
    Ok(())
}

/// 在当前 Route 上发送一个已由 DeliveryManager 领取的消息。
async fn deliver_pending_message(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    message: PendingMessage,
) {
    if message.policy == DeliveryPolicy::BestEffort {
        if let Err(error) = send_data_message(&state, &peer_id, &message).await {
            tracing::debug!(peer_id = %peer_id, error = %error, "best-effort channel message was not sent");
        }
        return;
    }

    let sendable = match state
        .delivery
        .begin_send(message.message_id, Instant::now())
        .await
    {
        Ok(Some(message)) => message,
        Ok(None) | Err(DeliveryError::NotFound) => return,
        Err(error) => {
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery message was not sendable");
            return;
        }
    };
    let result = send_data_message(&state, &peer_id, &sendable).await;
    match result {
        Ok(()) => {
            let _ = state
                .delivery
                .mark_sent(sendable.message_id, Instant::now())
                .await;
        }
        Err(error) => {
            let _ = state
                .delivery
                .mark_send_failed(sendable.message_id, Instant::now())
                .await;
            tracing::debug!(
                peer_id = %peer_id,
                session_id = %session_id.wire_key(),
                error = %error,
                "delivery message send failed and was returned to retry queue"
            );
        }
    }
}

/// 将一个 RecoverySnapshot 逐条重新编码并发送；Snapshot 不再被静默丢弃。
pub(crate) async fn recover_session(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
) {
    let session_key = session_id.wire_key();
    let snapshot = state.delivery.recover_session(&session_key).await;
    ensure_retry_worker(Arc::clone(&state), peer_id.clone(), session_id).await;
    replay_snapshot(state, peer_id, session_id, snapshot).await;
}

async fn replay_snapshot(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    snapshot: RecoverySnapshot,
) {
    for message in snapshot.messages {
        deliver_pending_message(Arc::clone(&state), peer_id.clone(), session_id, message).await;
    }
}

/// 每个逻辑 Session 只运行一个 ACK 超时扫描器；Connection 替换不会重复
/// 创建扫描任务，Session 关闭或换代时旧任务会自然退出。
async fn ensure_retry_worker(state: Arc<RuntimeState>, peer_id: String, session_id: SessionId) {
    let should_start = {
        let mut tasks = state.delivery_tasks.write().await;
        match tasks.get(&peer_id).copied() {
            Some(existing) if existing == session_id => false,
            _ => {
                tasks.insert(peer_id.clone(), session_id);
                true
            }
        }
    };
    if !should_start {
        return;
    }
    let retry_state = Arc::clone(&state);
    let retry_peer_id = peer_id.clone();
    let task_started =
        state
            .task_supervisor
            .spawn_session(session_id.wire_key(), "delivery-retry", async move {
                let session_key = session_id.wire_key();
                loop {
                    if retry_state
                        .sessions
                        .current_session_id(&retry_peer_id)
                        .await
                        != Some(session_id)
                        || !retry_state.sessions.is_connected(&retry_peer_id).await
                    {
                        break;
                    }
                    let expired = retry_state
                        .delivery
                        .expire_incoming(&session_key, Instant::now())
                        .await;
                    if !expired.is_empty() {
                        let failed_ordered_channels = expired
                            .iter()
                            .filter(|timeout| timeout.ordered_channel_failed)
                            .count();
                        tracing::warn!(
                            session_id = %session_key,
                            expired = expired.len(),
                            failed_ordered_channels,
                            "application delivery ACK timeout released receive state"
                        );
                    }
                    for message in retry_state
                        .delivery
                        .retryable_messages(&session_key, Instant::now())
                        .await
                    {
                        deliver_pending_message(
                            Arc::clone(&retry_state),
                            retry_peer_id.clone(),
                            session_id,
                            message,
                        )
                        .await;
                    }
                    tokio::time::sleep(DELIVERY_RETRY_POLL_INTERVAL).await;
                }
                let mut tasks = retry_state.delivery_tasks.write().await;
                if tasks.get(&retry_peer_id).copied() == Some(session_id) {
                    tasks.remove(&retry_peer_id);
                }
            });
    if task_started.is_none() {
        let mut tasks = state.delivery_tasks.write().await;
        if tasks.get(&peer_id).copied() == Some(session_id) {
            tasks.remove(&peer_id);
        }
    }
}

async fn send_data_message(
    state: &RuntimeState,
    peer_id: &str,
    message: &PendingMessage,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut data = DataMessage {
        session_id: message.session_id.clone(),
        channel_id: message.channel_id.clone(),
        message_id: message.message_id.to_bytes().to_vec(),
        sequence: message.sequence,
        recovery_epoch: message.recovery_epoch,
        policy: policy_code(message.policy),
        payload: Vec::new(),
        crypto_mode: message.crypto_mode.code(),
    };
    let aad = crypto::data_message_aad(
        &data.session_id,
        &data.channel_id,
        &data.message_id,
        data.sequence,
        data.recovery_epoch,
        data.policy,
        message.crypto_mode,
    );
    data.payload = state
        .encrypt_application_payload(
            peer_id,
            &data.session_id,
            message.crypto_mode,
            &aad,
            &message.payload,
        )
        .await?;
    let encoded = data.encode_to_vec();
    if encoded.len() > MAX_CHANNEL_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "encoded channel message exceeds frame limit",
        )
        .into());
    }
    state
        .sessions
        .send_channel_frame(
            peer_id,
            &hex::encode(message.message_id.to_bytes()),
            crate::connection::GenericFrameKind::DataMessage,
            &encoded,
        )
        .await
}

/// 处理 Dart 对已交付消息的 ACK，并把 ACK 发送到当前 Route。
pub(crate) async fn acknowledge_message(
    state: &RuntimeState,
    command: AcknowledgeMessageCommand,
) -> Result<(), ProtocolError> {
    let message_id: [u8; 16] = command.message_id.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "message_id must contain 16 bytes",
        )
    })?;
    if command.peer_id.is_empty() || command.session_id.is_empty() || command.channel_id.is_empty()
    {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id, session_id, and channel_id are required",
        ));
    }
    let Some(completion) = state
        .delivery
        .complete_incoming(
            &command.session_id,
            &command.channel_id,
            crate::delivery::MessageId::from_bytes(message_id),
        )
        .await
    else {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "message is not awaiting acknowledgement",
            "acknowledge_message",
            &command.peer_id,
        ));
    };
    let ack = DeliveryAck {
        session_id: command.session_id,
        message_id: message_id.to_vec(),
        recovery_epoch: completion.recovery_epoch,
    };
    if let Some(next) = completion.next_ordered {
        // The application ACK is the ordering gate. The next buffered message
        // is published even if this transport ACK needs a later retry.
        emit_ordered_message(state, next);
    }
    let result = send_delivery_ack(state, &command.peer_id, &ack).await;
    result.map_err(|error| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            error.to_string(),
            "acknowledge_message",
            &command.peer_id,
        )
    })
}

async fn send_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    ack: &DeliveryAck,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let encoded = ack.encode_to_vec();
    let _message_id: [u8; 16] = ack
        .message_id
        .as_slice()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid ACK ID"))?;
    state
        .sessions
        .send_channel_frame(
            peer_id,
            &hex::encode(_message_id),
            crate::connection::GenericFrameKind::DeliveryAck,
            &encoded,
        )
        .await
}

/// 处理 QUIC/Relay 到达的 DataMessage；只有 New 消息才进入应用事件流。
pub(crate) async fn handle_data_message(
    state: &RuntimeState,
    peer_id: &str,
    encoded: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut message = DataMessage::decode(encoded)?;
    validate_data_message(&message)?;
    let crypto_mode = decode_crypto_mode(message.crypto_mode).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid crypto mode")
    })?;
    let policy = decode_policy(message.policy).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Delivery policy")
    })?;
    let aad = crypto::data_message_aad(
        &message.session_id,
        &message.channel_id,
        &message.message_id,
        message.sequence,
        message.recovery_epoch,
        message.policy,
        crypto_mode,
    );
    message.payload = if policy == DeliveryPolicy::BestEffort {
        state
            .decrypt_application_payload(
                peer_id,
                &message.session_id,
                crypto_mode,
                &aad,
                &message.payload,
            )
            .await?
    } else {
        state
            .decrypt_application_payload_for_delivery(
                peer_id,
                &message.session_id,
                crypto_mode,
                &aad,
                &message.payload,
            )
            .await?
    };
    let message_id: [u8; 16] =
        message.message_id.as_slice().try_into().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid message ID")
        })?;
    let incoming = OrderedMessage {
        peer_id: peer_id.to_string(),
        session_id: message.session_id.clone(),
        channel_id: message.channel_id.clone(),
        message_id: crate::delivery::MessageId::from_bytes(message_id),
        sequence: message.sequence,
        policy,
        payload: message.payload.clone(),
    };
    if message.policy != DeliveryPolicyCode::BestEffort as i32 {
        match state
            .delivery
            .begin_incoming(
                &message.session_id,
                &message.channel_id,
                crate::delivery::MessageId::from_bytes(message_id),
                message.recovery_epoch,
                Instant::now(),
            )
            .await
        {
            DedupDecision::DuplicateInFlight => {
                // 首次事件已经交给本地应用，但应用还没有 ACK；后续重传
                // 只能保持 InFlight，不能再次进入业务 handler 或发送 ACK。
                return Ok(());
            }
            DedupDecision::DuplicateProcessed => {
                // 应用已经完成首次处理；后续重传可以安全地用当前 epoch
                // 重发 ACK，但绝不能再次进入业务 handler。
                let Some(recovery_epoch) = state
                    .delivery
                    .incoming_recovery_epoch(
                        &message.session_id,
                        &message.channel_id,
                        crate::delivery::MessageId::from_bytes(message_id),
                    )
                    .await
                else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "processed message lost its dedup record",
                    )
                    .into());
                };
                let ack = DeliveryAck {
                    session_id: message.session_id.clone(),
                    message_id: message_id.to_vec(),
                    recovery_epoch,
                };
                send_delivery_ack(state, peer_id, &ack).await?;
                return Ok(());
            }
            DedupDecision::StaleEpoch => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "stale DataMessage recovery epoch",
                )
                .into());
            }
            DedupDecision::CapacityExceeded => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "active delivery handler capacity exceeded",
                )
                .into());
            }
            DedupDecision::ChannelFailed => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "ordered delivery channel failed after application ACK timeout",
                )
                .into());
            }
            DedupDecision::New => {
                if policy == DeliveryPolicy::SessionBoundOrdered {
                    match state.delivery.accept_ordered(incoming.clone()).await {
                        OrderedInsertResult::Ready => {}
                        OrderedInsertResult::Buffered => return Ok(()),
                        OrderedInsertResult::Duplicate => {
                            let _ = state
                                .delivery
                                .reject_incoming(
                                    &message.session_id,
                                    &message.channel_id,
                                    crate::delivery::MessageId::from_bytes(message_id),
                                )
                                .await;
                            return Ok(());
                        }
                        OrderedInsertResult::Rejected => {
                            let _ = state
                                .delivery
                                .reject_incoming(
                                    &message.session_id,
                                    &message.channel_id,
                                    crate::delivery::MessageId::from_bytes(message_id),
                                )
                                .await;
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                "ordered message exceeds reorder limits",
                            )
                            .into());
                        }
                    }
                }
            }
        }
    }
    emit_ordered_message(state, incoming);
    Ok(())
}

fn emit_ordered_message(state: &RuntimeState, message: OrderedMessage) {
    let _ = state.event_tx.send(NetworkEvent {
        event_id: format!(
            "{}/channel/{}/{}/{}",
            message.peer_id,
            message.session_id,
            message.channel_id,
            hex::encode(message.message_id.to_bytes())
        ),
        timestamp_ms: crate::events::unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::ChannelMessage(
            ChannelMessageEvent {
                peer_id: message.peer_id,
                session_id: message.session_id,
                channel_id: message.channel_id,
                message_id: message.message_id.to_bytes().to_vec(),
                sequence: message.sequence,
                policy: policy_code(message.policy),
                payload: message.payload,
            },
        )),
    });
}

/// 处理传输层收到的 ACK，并只接受当前 epoch 的 ACK。
pub(crate) async fn handle_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    encoded: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ack = DeliveryAck::decode(encoded)?;
    let message_id: [u8; 16] = ack
        .message_id
        .as_slice()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid ACK ID"))?;
    if !ack.session_id.is_empty()
        && state
            .delivery
            .acknowledge(
                &ack.session_id,
                crate::delivery::MessageId::from_bytes(message_id),
                ack.recovery_epoch,
            )
            .await
            == AckResult::Acknowledged
    {
        let _ = state.event_tx.send(NetworkEvent {
            event_id: format!(
                "{peer_id}/delivery-ack/{}/{}",
                ack.session_id,
                hex::encode(message_id)
            ),
            timestamp_ms: crate::events::unix_timestamp_ms(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id: peer_id.to_string(),
                session_id: ack.session_id,
                message_id: message_id.to_vec(),
                recovery_epoch: ack.recovery_epoch,
            })),
        });
    }
    Ok(())
}

fn validate_data_message(
    message: &DataMessage,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if message.session_id.is_empty()
        || message.session_id.len() > 128
        || message.channel_id.is_empty()
        || message.channel_id.len() > 128
        || message.message_id.len() != 16
        || message.payload.len() > MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES
        || DeliveryPolicyCode::try_from(message.policy).is_err()
        || CryptoMode::from_code(message.crypto_mode).is_none()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid DataMessage envelope",
        )
        .into());
    }
    Ok(())
}

fn decode_policy(value: i32) -> Option<DeliveryPolicy> {
    match DeliveryPolicyCode::try_from(value).ok()? {
        DeliveryPolicyCode::BestEffort => Some(DeliveryPolicy::BestEffort),
        DeliveryPolicyCode::LatestState => Some(DeliveryPolicy::LatestState),
        DeliveryPolicyCode::Acked => Some(DeliveryPolicy::Acked),
        DeliveryPolicyCode::AckedDeduplicated => Some(DeliveryPolicy::AckedDeduplicated),
        DeliveryPolicyCode::SessionBoundOrdered => Some(DeliveryPolicy::SessionBoundOrdered),
        DeliveryPolicyCode::ResumableTransfer => Some(DeliveryPolicy::ResumableTransfer),
    }
}

fn decode_crypto_mode(value: i32) -> Option<CryptoMode> {
    CryptoMode::from_code(value)
}

fn policy_code(policy: DeliveryPolicy) -> i32 {
    match policy {
        DeliveryPolicy::BestEffort => DeliveryPolicyCode::BestEffort as i32,
        DeliveryPolicy::LatestState => DeliveryPolicyCode::LatestState as i32,
        DeliveryPolicy::Acked => DeliveryPolicyCode::Acked as i32,
        DeliveryPolicy::AckedDeduplicated => DeliveryPolicyCode::AckedDeduplicated as i32,
        DeliveryPolicy::SessionBoundOrdered => DeliveryPolicyCode::SessionBoundOrdered as i32,
        DeliveryPolicy::ResumableTransfer => DeliveryPolicyCode::ResumableTransfer as i32,
    }
}

fn delivery_error(peer_id: &str, error: DeliveryError) -> ProtocolError {
    let code = match error {
        DeliveryError::QueueFull | DeliveryError::PayloadTooLarge => {
            NetworkErrorCode::InvalidArgument
        }
        DeliveryError::InvalidScope | DeliveryError::InvalidRetryPolicy => {
            NetworkErrorCode::InvalidArgument
        }
        DeliveryError::NotFound | DeliveryError::Expired | DeliveryError::RetryExhausted => {
            NetworkErrorCode::IoError
        }
    };
    protocol_error_with_peer(code, error.to_string(), "send_message", peer_id)
}

#[cfg(test)]
mod tests {
    use super::acknowledge_message;
    use crate::connection::{test_blocking_generic_route, TestBlockingGenericRoute};
    use crate::delivery::{
        DedupDecision, DeliveryPolicy, MessageId, OrderedInsertResult, OrderedMessage,
    };
    use crate::runtime::RuntimeState;
    use network_protocol::{network_event, AcknowledgeMessageCommand};
    use std::sync::{atomic::AtomicU16, Arc};
    use std::time::{Duration, Instant};
    use tokio::sync::mpsc;

    const TEST_TIMEOUT: Duration = Duration::from_secs(2);

    #[tokio::test]
    async fn ordered_next_is_published_before_transport_ack_completes() {
        let peer_id = "ordered-peer";
        let channel_id = "control";
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));

        let session_id = match state.sessions.begin_connect(peer_id).await {
            crate::session::ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected session decision: {decision:?}"),
        };
        let session_key = session_id.wire_key();

        let TestBlockingGenericRoute {
            handle,
            mut started,
            release,
            mut worker,
        } = test_blocking_generic_route();
        state
            .sessions
            .attach_generic_connection_for_session(peer_id, Some(session_id), handle, false)
            .await
            .expect("attach test route");

        let now = Instant::now();
        for (sequence, message_id, payload, expected_result) in [
            (
                0,
                MessageId::from_bytes([0; 16]),
                b"ordered-zero".to_vec(),
                OrderedInsertResult::Ready,
            ),
            (
                1,
                MessageId::from_bytes([1; 16]),
                b"ordered-one".to_vec(),
                OrderedInsertResult::Buffered,
            ),
        ] {
            assert_eq!(
                state
                    .delivery
                    .begin_incoming(&session_key, channel_id, message_id, 1, now)
                    .await,
                DedupDecision::New
            );
            assert_eq!(
                state
                    .delivery
                    .accept_ordered(OrderedMessage {
                        peer_id: peer_id.to_string(),
                        session_id: session_key.clone(),
                        channel_id: channel_id.to_string(),
                        message_id,
                        sequence,
                        policy: DeliveryPolicy::SessionBoundOrdered,
                        payload,
                    })
                    .await,
                expected_result
            );
        }

        let command = AcknowledgeMessageCommand {
            peer_id: peer_id.to_string(),
            session_id: session_key,
            channel_id: channel_id.to_string(),
            message_id: [0; 16].to_vec(),
        };
        let state_for_ack = Arc::clone(&state);
        let mut acknowledge_task =
            tokio::spawn(async move { acknowledge_message(&state_for_ack, command).await });

        let observation = async {
            let event = tokio::time::timeout(TEST_TIMEOUT, event_rx.recv())
                .await
                .map_err(|_| "#1 was not published while ACK transport was blocked")?
                .ok_or("event channel closed before #1 was published")?;
            let expected = matches!(
                event.payload,
                Some(network_event::Payload::ChannelMessage(message))
                    if message.peer_id == peer_id
                        && message.channel_id == channel_id
                        && message.sequence == 1
                        && message.message_id == [1; 16].to_vec()
                        && message.payload == b"ordered-one".to_vec()
            );
            if !expected {
                return Err("unexpected event received before ordered #1".to_string());
            }

            tokio::time::timeout(TEST_TIMEOUT, &mut started)
                .await
                .map_err(|_| "ACK transport did not start")?
                .map_err(|_| "ACK transport start signal was dropped")?;
            if acknowledge_task.is_finished() {
                return Err("ACK completed before its release barrier".to_string());
            }
            Ok::<(), String>(())
        }
        .await;

        let _ = release.send(());
        let acknowledge_completed =
            match tokio::time::timeout(TEST_TIMEOUT, &mut acknowledge_task).await {
                Ok(Ok(Ok(()))) => true,
                Ok(Ok(Err(error))) => {
                    eprintln!("acknowledge_message returned an error: {error:?}");
                    false
                }
                Ok(Err(error)) => {
                    eprintln!("acknowledge_message task failed: {error}");
                    false
                }
                Err(_) => {
                    acknowledge_task.abort();
                    let _ = acknowledge_task.await;
                    false
                }
            };

        let route_closed = tokio::time::timeout(TEST_TIMEOUT, state.sessions.close(peer_id))
            .await
            .is_ok();
        let worker_completed = match tokio::time::timeout(TEST_TIMEOUT, &mut worker).await {
            Ok(Ok(())) => true,
            Ok(Err(error)) => {
                eprintln!("test transport worker failed: {error}");
                false
            }
            Err(_) => {
                worker.abort();
                let _ = worker.await;
                false
            }
        };

        assert!(observation.is_ok(), "{observation:?}");
        assert!(
            acknowledge_completed,
            "acknowledge_message did not complete successfully"
        );
        assert!(route_closed, "test route did not close during cleanup");
        assert!(worker_completed, "test transport worker did not terminate");
    }
}
