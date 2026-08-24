//! Delivery Manager 与当前 Route 的生产接线。
//!
//! Delivery 只保存可重编码的应用消息；本模块负责在 Connection Ready、
//! ACK、重连和 Route 变化时把同一份 DataMessage 发送到当前 QUIC 或 Relay。
//! 所有发送都以逻辑 SessionId 为边界，不把 MessageId、Sequence 或
//! RecoveryEpoch 存进具体 Connection。

use crate::connect::{PathLease, CAPABILITY_RELIABLE_MESSAGE};
use crate::connection::RouteTopology;
use crate::crypto;
use crate::delivery::{
    AckResult, DedupDecision, DeliveryError, DeliveryPolicy, OrderedInsertResult, OrderedMessage,
    PendingMessage, RecoverySnapshot,
};
use crate::errors::CoreNetworkError;
use crate::events::{protocol_error, protocol_error_with_peer};
use crate::runtime::{RuntimeState, DELIVERY_RETRY_POLL_INTERVAL};
use crate::session::SessionId;
use network_protocol::{
    network_event, AcknowledgeMessageCommand, ChannelMessageEvent, DataMessage, DeliveryAck,
    DeliveryAckedEvent, DeliveryPolicyCode, NetworkError as ProtocolError, NetworkErrorCode,
    NetworkEvent, SendMessageCommand, NETWORK_PROTOCOL_VERSION,
};
use network_quic::MAX_CHANNEL_FRAME_BYTES;
use prost::Message;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Instant;

const MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES: usize = MAX_CHANNEL_FRAME_BYTES - 1024;
static NEXT_BUSINESS_ENSURE_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApplicationPayloadMode {
    Encrypted,
    Plaintext,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApplicationPolicyError {
    SecurityPolicyMismatch,
    RelayRequiresE2ee,
}

impl std::fmt::Display for ApplicationPolicyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SecurityPolicyMismatch => formatter.write_str("security policy mismatch"),
            Self::RelayRequiresE2ee => formatter.write_str("Relay paths require E2EE"),
        }
    }
}

impl std::error::Error for ApplicationPolicyError {}

fn application_payload_mode(
    policy: crate::crypto_handshake::path_handshake::E2eePolicy,
    topology: RouteTopology,
    has_crypto_context: bool,
) -> Result<ApplicationPayloadMode, ApplicationPolicyError> {
    if topology == RouteTopology::Relay
        && policy == crate::crypto_handshake::path_handshake::E2eePolicy::Disabled
    {
        return Err(ApplicationPolicyError::RelayRequiresE2ee);
    }
    match policy {
        crate::crypto_handshake::path_handshake::E2eePolicy::Required => {
            if has_crypto_context {
                Ok(ApplicationPayloadMode::Encrypted)
            } else {
                Err(ApplicationPolicyError::SecurityPolicyMismatch)
            }
        }
        crate::crypto_handshake::path_handshake::E2eePolicy::Disabled => {
            if has_crypto_context {
                Err(ApplicationPolicyError::SecurityPolicyMismatch)
            } else {
                Ok(ApplicationPayloadMode::Plaintext)
            }
        }
    }
}

fn next_business_ensure_id(peer_id: &str) -> String {
    let sequence = NEXT_BUSINESS_ENSURE_ID.fetch_add(1, Ordering::Relaxed);
    format!("delivery/{peer_id}/{sequence}")
}

/// Ensure a Ready ReliableMessage path for one business operation.
///
/// `RuntimeState::ensure_business_path` starts the supervisor mailbox worker
/// while keeping maintenance disabled; the peer supervisor remains the sole
/// owner of the establishment attempt.
async fn ensure_reliable_message_path(
    state: Arc<RuntimeState>,
    peer_id: &str,
    command_id: &str,
) -> Result<SessionId, CoreNetworkError> {
    RuntimeState::ensure_business_path(
        state,
        peer_id,
        command_id,
        network_protocol::CommunicationClass::ReliableMessage,
        CAPABILITY_RELIABLE_MESSAGE,
    )
    .await
}

async fn validate_business_application_policy(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
) -> Result<(), ProtocolError> {
    let profile = state.path_profile(peer_id).await.ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no compatible ready path",
            "send_message",
            peer_id,
        )
    })?;
    let policy = state.e2ee_policy(peer_id).await;
    let has_context = state
        .crypto_context(peer_id, &session_id.wire_key())
        .await
        .is_ok();
    application_payload_mode(policy, profile.topology(), has_context).map_err(|error| {
        let code = match error {
            ApplicationPolicyError::SecurityPolicyMismatch => {
                NetworkErrorCode::SecurityPolicyMismatch
            }
            ApplicationPolicyError::RelayRequiresE2ee => NetworkErrorCode::RelayRequiresE2ee,
        };
        protocol_error_with_peer(code, error.to_string(), "send_message", peer_id)
    })?;
    Ok(())
}

/// Select one peer-owned ready path for one business attempt.
///
/// The runtime lookup is only for the peer's `PeerPathManager`; selection and
/// lease acquisition remain under that manager's lock. This adapter returns
/// the owning `PathLease`, never a copied route or carrier. A caller must drop
/// the lease after its single send.
pub(crate) async fn select_business_path_lease(
    state: &RuntimeState,
    peer_id: &str,
    required_capabilities: u8,
) -> Result<PathLease, CoreNetworkError> {
    state
        .acquire_path_lease(peer_id, required_capabilities)
        .await
}

/// Send one already-encoded business frame while its path lease is active.
///
/// The runtime path adapter is used only after the lease has validated the
/// peer, capability, and path lifetime. Business code does not inspect a
/// SessionStore route, relay data slot, or stream carrier projection.
pub(crate) async fn send_business_frame(
    state: &RuntimeState,
    peer_id: &str,
    lease: &PathLease,
    relay_token: &str,
    kind: crate::connection::GenericFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let required_capability = match kind {
        crate::connection::GenericFrameKind::DataMessage
        | crate::connection::GenericFrameKind::DeliveryAck => {
            crate::connection::ConnectionCapability::ReliableMessage
        }
        crate::connection::GenericFrameKind::StreamOpen
        | crate::connection::GenericFrameKind::StreamBytes
        | crate::connection::GenericFrameKind::StreamClose => {
            crate::connection::ConnectionCapability::ReliableStream
        }
    };
    if lease.handle().peer_id().as_str() != peer_id
        || !lease.profile().supports(required_capability)
        || !lease.is_active()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "business path lease is no longer active",
        )
        .into());
    }
    let result = state
        .path_send_channel_frame_for_lease(lease, relay_token, kind, payload)
        .await;
    if result.is_ok() && !lease.is_active() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "business path was lost during send",
        )
        .into());
    }
    result
}

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
    let session_id = ensure_reliable_message_path(
        Arc::clone(&state),
        &command.peer_id,
        &next_business_ensure_id(&command.peer_id),
    )
    .await
    .map_err(|error| {
        let code = match error {
            CoreNetworkError::NoRoute => NetworkErrorCode::NoRoute,
            CoreNetworkError::Cancelled | CoreNetworkError::SupervisorStopping => {
                NetworkErrorCode::Cancelled
            }
            _ => NetworkErrorCode::Lifecycle,
        };
        protocol_error_with_peer(code, error.to_string(), "send_message", &command.peer_id)
    })?;
    validate_business_application_policy(&state, &command.peer_id, session_id).await?;
    // §20：投递状态按 Peer 业务作用域保存，绝不使用每连接的 SessionId。
    let message = state
        .delivery
        .enqueue(
            &command.peer_id,
            &command.channel_id,
            command.payload,
            policy,
            Default::default(),
        )
        .await
        .map_err(|error| delivery_error(&command.peer_id, error))?;
    ensure_retry_worker(Arc::clone(&state), command.peer_id.clone()).await;
    let supervisor = Arc::clone(&state.task_supervisor);
    if supervisor
        .spawn_runtime(
            "delivery-send",
            deliver_pending_message(state, command.peer_id.clone(), message),
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
///
/// 发送时解析**当前** ConnectionSession（wire 信封与加密上下文必须属于当前
/// connection；pending 消息在旧连接入队后，可能在新连接上以同一 MessageId
/// 重发）。
async fn deliver_pending_message(
    state: Arc<RuntimeState>,
    peer_id: String,
    message: PendingMessage,
) {
    if message.policy == DeliveryPolicy::BestEffort {
        let session_id = match ensure_reliable_message_path(
            Arc::clone(&state),
            &peer_id,
            &format!(
                "delivery-best-effort/{}",
                hex::encode(message.message_id.to_bytes())
            ),
        )
        .await
        {
            Ok(session_id) => session_id,
            Err(error) => {
                tracing::debug!(peer_id = %peer_id, error = %error, "best-effort ensure failed");
                return;
            }
        };
        /*
         * The lease is intentionally acquired below and dropped after this
         * single send. Waiting for an application ACK never owns a lease.
         */
        let lease = match select_business_path_lease(&state, &peer_id, CAPABILITY_RELIABLE_MESSAGE)
            .await
        {
            Ok(lease) => lease,
            Err(error) => {
                tracing::debug!(peer_id = %peer_id, error = %error, "best-effort path lease unavailable");
                return;
            }
        };
        if let Err(error) = send_data_message(&state, &peer_id, session_id, &lease, &message).await
        {
            tracing::debug!(peer_id = %peer_id, error = %error, "best-effort channel message was not sent");
        }
        return;
    }

    let sendable = match state
        .delivery
        .begin_send_for_peer(&peer_id, message.message_id, Instant::now())
        .await
    {
        Ok(Some(attempt)) => attempt,
        Ok(None) | Err(DeliveryError::NotFound) => return,
        Err(error) => {
            if let Some(recovery) = error.recovery_error() {
                tracing::debug!(
                    peer_id = %peer_id,
                    ?recovery,
                    error = %error,
                    "delivery send attempt rejected"
                );
            }
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery message was not sendable");
            return;
        }
    };
    let message = &sendable.message;
    let session_id = match ensure_reliable_message_path(
        Arc::clone(&state),
        &peer_id,
        &format!("delivery/{}", hex::encode(message.message_id.to_bytes())),
    )
    .await
    {
        Ok(session_id) => session_id,
        Err(error) => {
            // 连接在领取与发送之间丢失：退回重试队列，等待下一次 ConnectionSession。
            let _ = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery ensure failed");
            return;
        }
    };
    let lease = match select_business_path_lease(&state, &peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
    {
        Ok(lease) => lease,
        Err(error) => {
            let _ = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery path lease unavailable");
            return;
        }
    };
    let result = send_data_message(&state, &peer_id, session_id, &lease, message).await;
    match result {
        Ok(()) => {
            let _ = state
                .delivery
                .mark_sent_for_attempt(&sendable, Instant::now())
                .await;
        }
        Err(error) => {
            let decision = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            if let Some(recovery) = decision.recovery_error() {
                tracing::debug!(
                    peer_id = %peer_id,
                    ?recovery,
                    "delivery send failure classified"
                );
            }
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
///
/// 恢复按 Peer 业务作用域进行（§20）：新 Connection Ready 后，该 Peer 所有未
/// ACK 的 pending 消息都会以**同一个 MessageId** 在**当前** transport 上重发，
/// 由对端按 MessageId 去重。
pub(crate) async fn recover_session(state: Arc<RuntimeState>, peer_id: String) {
    let snapshot = match state.delivery.recover_peer_checked(&peer_id).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery recovery rejected");
            return;
        }
    };
    ensure_retry_worker(Arc::clone(&state), peer_id.clone()).await;
    replay_snapshot(state, peer_id, snapshot).await;
}

async fn replay_snapshot(state: Arc<RuntimeState>, peer_id: String, snapshot: RecoverySnapshot) {
    for message in snapshot.messages {
        deliver_pending_message(Arc::clone(&state), peer_id.clone(), message).await;
    }
}

/// 每个 Peer 只运行一个重试循环；所有权（注册表）在 DeliveryManager 业务层，
/// key 是 Peer 业务作用域——**不是** ConnectionSession 的 SessionId。
///
/// worker 无连接时暂停（只是休眠轮询），新 ConnectionSession 出现后自动恢复，
/// 因此一次认领即可覆盖后续所有重连；transport 丢失不会取消它。
async fn ensure_retry_worker(state: Arc<RuntimeState>, peer_id: String) {
    if !state.delivery.try_start_retry_worker(&peer_id).await {
        return;
    }
    let retry_state = Arc::clone(&state);
    let retry_peer_id = peer_id.clone();
    let task_started = state
        .task_supervisor
        .spawn_runtime("delivery-retry", async move {
            loop {
                if retry_state
                    .connection_sessions
                    .current_session_id(&retry_peer_id)
                    .await
                    .is_some()
                {
                    let expired = retry_state
                        .delivery
                        .expire_incoming(&retry_peer_id, Instant::now())
                        .await;
                    if !expired.is_empty() {
                        let failed_ordered_channels = expired
                            .iter()
                            .filter(|timeout| timeout.ordered_channel_failed)
                            .count();
                        tracing::warn!(
                            peer_id = %retry_peer_id,
                            expired = expired.len(),
                            failed_ordered_channels,
                            "application delivery ACK timeout released receive state"
                        );
                    }
                    let retryable = match retry_state
                        .delivery
                        .retryable_messages_checked(&retry_peer_id, Instant::now())
                        .await
                    {
                        Ok(messages) => messages,
                        Err(error) => {
                            tracing::debug!(
                                peer_id = %retry_peer_id,
                                error = %error,
                                "delivery retry scan rejected"
                            );
                            Vec::new()
                        }
                    };
                    for message in retryable {
                        deliver_pending_message(
                            Arc::clone(&retry_state),
                            retry_peer_id.clone(),
                            message,
                        )
                        .await;
                    }
                }
                tokio::time::sleep(DELIVERY_RETRY_POLL_INTERVAL).await;
            }
        });
    if task_started.is_none() {
        state.delivery.stop_retry_worker(&peer_id).await;
    }
}

async fn send_data_message(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
    lease: &PathLease,
    message: &PendingMessage,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // wire 信封与加密上下文必须使用当前 ConnectionSession（重放时 MessageId
    // 不变，但 SessionId / Noise root 已经换代）。
    if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "connection session changed before delivery send",
        )
        .into());
    }
    let session_key = session_id.wire_key();
    let mut data = DataMessage {
        session_id: session_key.clone(),
        channel_id: message.channel_id.clone(),
        message_id: message.message_id.to_bytes().to_vec(),
        sequence: message.sequence,
        recovery_epoch: message.recovery_epoch,
        policy: policy_code(message.policy),
        payload: Vec::new(),
    };
    let aad = crypto::data_message_aad(
        &data.session_id,
        &data.channel_id,
        &data.message_id,
        data.sequence,
        data.recovery_epoch,
        data.policy,
    );
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    let has_crypto_context = state.crypto_context(peer_id, &session_key).await.is_ok();
    let mode =
        application_payload_mode(e2ee_policy, lease.profile().topology(), has_crypto_context)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::PermissionDenied, error))?;
    data.payload = match mode {
        ApplicationPayloadMode::Encrypted => {
            state
                .encrypt_application_payload(peer_id, &session_key, &aad, &message.payload)
                .await?
        }
        ApplicationPayloadMode::Plaintext => message.payload.clone(),
    };
    let encoded = data.encode_to_vec();
    if encoded.len() > MAX_CHANNEL_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "encoded channel message exceeds frame limit",
        )
        .into());
    }
    if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "connection session changed during delivery encoding",
        )
        .into());
    }
    send_business_frame(
        state,
        peer_id,
        lease,
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
    // 应用 ACK 的关联 key 是 Peer + Channel + MessageId（§20）。`command.session_id`
    // 只是事件里携带的 wire SessionId，仅用于回显，不参与关联。
    let completion = match state
        .delivery
        .complete_incoming_checked(
            &command.peer_id,
            &command.channel_id,
            crate::delivery::MessageId::from_bytes(message_id),
        )
        .await
    {
        Ok(Some(completion)) => completion,
        Ok(None) => {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "message is not awaiting acknowledgement",
                "acknowledge_message",
                &command.peer_id,
            ));
        }
        Err(error) => return Err(delivery_error(&command.peer_id, error)),
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
    let lease = select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::NotConnected, error.to_string())
        })?;
    send_business_frame(
        state,
        peer_id,
        &lease,
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
    );
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    let has_crypto_context = state
        .crypto_context(peer_id, &message.session_id)
        .await
        .is_ok();
    let mode = application_payload_mode(
        e2ee_policy,
        state
            .path_profile(peer_id)
            .await
            .map(|profile| profile.topology())
            .unwrap_or(RouteTopology::Direct),
        has_crypto_context,
    )
    .map_err(|error| std::io::Error::new(std::io::ErrorKind::PermissionDenied, error))?;
    message.payload = match mode {
        ApplicationPayloadMode::Encrypted => {
            if !crypto::is_application_envelope(&message.payload) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "required application E2EE payload is missing",
                )
                .into());
            }
            if policy == DeliveryPolicy::BestEffort {
                state
                    .decrypt_application_payload(
                        peer_id,
                        &message.session_id,
                        &aad,
                        &message.payload,
                    )
                    .await?
            } else {
                state
                    .decrypt_application_payload_for_delivery(
                        peer_id,
                        &message.session_id,
                        &aad,
                        &message.payload,
                    )
                    .await?
            }
        }
        ApplicationPayloadMode::Plaintext => {
            if crypto::is_application_envelope(&message.payload) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "disabled application E2EE policy received ciphertext",
                )
                .into());
            }
            message.payload
        }
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
            .begin_incoming_checked(
                peer_id,
                &message.channel_id,
                crate::delivery::MessageId::from_bytes(message_id),
                message.recovery_epoch,
                Instant::now(),
            )
            .await?
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
                        peer_id,
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
                                    peer_id,
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
                                    peer_id,
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

/// 处理传输层收到的 ACK。ACK 按 **MessageId** 关联（§20）：
/// 只要该 MessageId 仍在 pending 中即完成；已完成消息的重复 ACK 是 no-op。
/// `ack.session_id` / `ack.recovery_epoch` 只用于事件回显，不参与关联门控。
pub(crate) async fn handle_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    encoded: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ack = DeliveryAck::decode(encoded)?;
    if ack.session_id.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "DeliveryAck session_id is required",
        )
        .into());
    }
    let message_id: [u8; 16] = ack
        .message_id
        .as_slice()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid ACK ID"))?;
    if state
        .delivery
        .acknowledge(peer_id, crate::delivery::MessageId::from_bytes(message_id))
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
#[path = "tests/channel.rs"]
mod tests;
