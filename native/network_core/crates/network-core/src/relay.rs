//! Relay v1 enrollment 运行时、透明传输路由与 E2E 处理。

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_nat::{Candidate, CandidateSignal, CandidateSignalKind, DEFAULT_CONNECT_WINDOW_MS};
use network_protocol::{
    ConfigureRelayCommand, DataMessage, DeliveryAck, NetworkError as ProtocolError,
    NetworkErrorCode, RouteType,
};
use network_relay::{RelayClient, RelayError, RelayEvent};
use network_transfer::{
    build_file_manifest, existing_completed_file, existing_partial_offset, FileManifest,
    ResumableTransfer, TransferFailureReason, DEFAULT_TRANSFER_BUFFER,
};
use prost::Message;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio::sync::{mpsc, oneshot};

use crate::crypto::{self, CryptoMode, APPLICATION_CRYPTO_SUITE};
use crate::events::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error, emit_transfer_progress,
    protocol_error, protocol_error_with_context,
};
use crate::runtime::{
    PeerConfig, RuntimeState, INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS,
    MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
};

/// Relay 配置只存在 native runtime 内存中，用于 socket 意外断开后的指数退避重连。
#[derive(Clone)]
pub(crate) struct RelayReconnectConfig {
    pub(crate) relay_url: String,
    pub(crate) credential: String,
    pub(crate) signing_seed: [u8; 32],
}

/// 发送方等待接收方返回的恢复确认。
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub(crate) struct RelayAcceptance {
    pub(crate) v: u32,
    pub(crate) transfer_id: String,
    pub(crate) manifest_hash: String,
    pub(crate) file_hash: String,
    pub(crate) offset: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct RelayAcceptancePayload {
    v: u32,
    transfer_id: String,
    manifest_hash: String,
    file_hash: String,
    offset: u64,
}

/// Relay 文件每个分块固定边界，确保断线时的 offset 能无歧义映射到 nonce 序号。
const RELAY_FILE_CHUNK_BYTES: u64 = DEFAULT_TRANSFER_BUFFER as u64;

/// 等待 UI 审批的待处理 Relay 申请。
#[derive(Clone)]
pub(crate) struct PendingRelayIncoming {
    pub(crate) transfer_id: String,
    pub(crate) session_id: String,
    pub(crate) sender_id: String,
    pub(crate) manifest: FileManifest,
    pub(crate) manifest_hash: String,
    /// The sender's logical Session key. The Relay attempt token is separate
    /// and must never select the application crypto context.
    pub(crate) crypto_session_id: String,
}

/// 在校验文件提交前使用的活跃 Relay 接收状态。
pub(crate) struct ActiveRelayIncoming {
    pub(crate) offer: PendingRelayIncoming,
    pub(crate) file: Option<tokio::fs::File>,
    pub(crate) temporary_path: PathBuf,
    pub(crate) final_path: PathBuf,
    pub(crate) next_sequence: u64,
    pub(crate) received_bytes: u64,
    pub(crate) hasher: Sha256,
    pub(crate) already_completed: bool,
}

/// 连接原生 Relay 数据面并启动事件消费者。
pub(crate) async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(&state).await;
    state.relay_config.write().await.take();
    let previous = state.relay.write().await.take();
    if let Some(previous) = previous {
        previous.request_disconnect().await;
        cleanup_relay_state(&state).await;
    }
    let device_id = state
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or_else(|| {
            protocol_error(
                NetworkErrorCode::InvalidArgument,
                "runtime must be configured before Relay",
            )
        })?;
    let signing_seed: [u8; 32] = command.relay_signing_seed.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay signing seed must contain 32 bytes",
        )
    })?;
    let config = RelayReconnectConfig {
        relay_url: command.relay_url,
        credential: command.relay_credential,
        signing_seed,
    };
    let (relay, events) = connect_relay_client(&device_id, &config)
        .await
        .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))?;
    *state.relay_config.write().await = Some(config);
    *state.relay.write().await = Some(Arc::clone(&relay));
    state
        .task_supervisor
        .spawn_runtime(
            "relay-events",
            handle_relay_events(events, Arc::clone(&state), Arc::clone(&relay)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    crate::transfer::resume_relay_transfers(state).await;
    Ok(())
}

/// 断开原生 Relay 客户端，并发布类型化最终状态。
pub(crate) async fn disconnect_relay(state: &RuntimeState) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(state).await;
    state.relay_config.write().await.take();
    let relay = state.relay.write().await.take();
    if let Some(relay) = relay {
        relay.request_disconnect().await;
    }
    cleanup_relay_state(state).await;
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        None,
    );
    Ok(())
}

async fn connect_relay_client(
    device_id: &str,
    config: &RelayReconnectConfig,
) -> Result<(Arc<RelayClient>, mpsc::Receiver<RelayEvent>), RelayError> {
    let mut relay = RelayClient::new(
        config.relay_url.clone(),
        device_id.to_string(),
        config.credential.clone(),
        config.signing_seed,
    )?;
    relay.connect().await?;
    let events = relay.take_events()?;
    Ok((Arc::new(relay), events))
}

/// 只在 socket 意外结束时启动一个共享重连任务；显式 DisconnectRelay 会先清除配置，
/// 因此不会被这个后台任务重新拉起。
fn schedule_relay_reconnect(state: Arc<RuntimeState>) {
    if state
        .relay_reconnect_active
        .swap(true, std::sync::atomic::Ordering::AcqRel)
    {
        return;
    }
    let reconnect_state = Arc::clone(&state);
    let task_id = state
        .task_supervisor
        .spawn_runtime("relay-reconnect", async move {
            let mut backoff = crate::runtime::RECONNECT_INITIAL_BACKOFF;
            loop {
                tokio::time::sleep(backoff).await;
                let Some(config) = reconnect_state.relay_config.read().await.clone() else {
                    break;
                };
                let Some(device_id) = reconnect_state
                    .identity
                    .read()
                    .await
                    .as_ref()
                    .map(|identity| identity.device_id.clone())
                else {
                    break;
                };
                match connect_relay_client(&device_id, &config).await {
                    Ok((relay, events)) => {
                        *reconnect_state.relay.write().await = Some(Arc::clone(&relay));
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Connected,
                            None,
                        );
                        let _ = reconnect_state.task_supervisor.spawn_runtime(
                            "relay-events",
                            handle_relay_events(
                                events,
                                Arc::clone(&reconnect_state),
                                Arc::clone(&relay),
                            ),
                        );
                        crate::transfer::resume_relay_transfers(Arc::clone(&reconnect_state)).await;
                        break;
                    }
                    Err(error) => {
                        tracing::debug!(error = %error, "Relay reconnect attempt failed");
                        backoff = std::cmp::min(
                            backoff.saturating_mul(2),
                            crate::runtime::RECONNECT_MAX_BACKOFF,
                        );
                    }
                }
            }
            reconnect_state
                .relay_reconnect_active
                .store(false, std::sync::atomic::Ordering::Release);
            if let Ok(mut task) = reconnect_state.relay_reconnect_task.lock() {
                task.take();
            }
        });
    if let Some(task_id) = task_id {
        if let Ok(mut task) = state.relay_reconnect_task.lock() {
            *task = Some(task_id);
        }
    } else {
        state
            .relay_reconnect_active
            .store(false, std::sync::atomic::Ordering::Release);
    }
}

async fn stop_relay_reconnect_task(state: &RuntimeState) {
    state
        .relay_reconnect_active
        .store(false, std::sync::atomic::Ordering::Release);
    let task_id = state
        .relay_reconnect_task
        .lock()
        .ok()
        .and_then(|mut task| task.take());
    if let Some(task_id) = task_id {
        state.task_supervisor.cancel_task(task_id).await;
    }
}

/// 消费 Relay 控制帧和二进制帧，不将其暴露给 Dart。
pub(crate) async fn handle_relay_events(
    mut events: mpsc::Receiver<RelayEvent>,
    state: Arc<RuntimeState>,
    relay: Arc<RelayClient>,
) {
    while let Some(event) = events.recv().await {
        match event {
            RelayEvent::Lookup { peer_id, online } => {
                if let Some(sender) = state.relay_lookups.write().await.remove(&peer_id) {
                    let _ = sender.send(online);
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
            } if kind == "offer" => {
                if let (Some(sender_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) =
                        receive_relay_offer(&state, session_id.clone(), sender_id.clone(), payload)
                            .await
                    {
                        emit_transfer_error(
                            &state.event_tx,
                            &session_id,
                            NetworkErrorCode::RelayError,
                            "Relay incoming offer was rejected".to_string(),
                            "receive",
                            Some(&sender_id),
                        );
                        if let Some(relay) = state.relay.read().await.as_ref() {
                            let _ = relay.send_session_control("cancel", &session_id).await;
                        }
                        tracing::warn!("Rejected inbound Relay offer: {}", error);
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
            } if kind == "crypto_handshake" => {
                if let (Some(peer_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) = handle_relay_crypto_handshake(
                        &state,
                        &relay,
                        &session_id,
                        &peer_id,
                        &payload,
                    )
                    .await
                    {
                        tracing::debug!(
                            peer_id = %peer_id,
                            error = %error,
                            "rejected Relay Session E2EE handshake"
                        );
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
            } if matches!(
                kind.as_str(),
                "webrtc_offer"
                    | "webrtc_answer"
                    | "webrtc_ice_candidate"
                    | "webrtc_ice_restart"
                    | "webrtc_close"
            ) =>
            {
                if let (Some(peer_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) = crate::realtime::handle_relay_signal(
                        &state,
                        &relay,
                        &kind,
                        &session_id,
                        &peer_id,
                        &payload,
                    )
                    .await
                    {
                        tracing::debug!(
                            peer_id = %peer_id,
                            error = %error,
                            "rejected WebRTC signaling control"
                        );
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                ..
            } if kind == "complete" => {
                if let Err(error) =
                    complete_relay_incoming(&state, &session_id, peer_id.as_deref()).await
                {
                    emit_transfer_error(
                        &state.event_tx,
                        &session_id,
                        NetworkErrorCode::RelayError,
                        "Relay incoming transfer failed validation".to_string(),
                        "receive",
                        peer_id.as_deref(),
                    );
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    tracing::warn!("Failed inbound Relay completion: {}", error);
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                payload,
                ..
            } if kind == "accept" => {
                if let Some(sender) = state.relay_acceptances.write().await.remove(&session_id) {
                    let acceptance = payload
                        .and_then(|payload| serde_json::from_str::<RelayAcceptance>(&payload).ok());
                    let _ = sender.send(acceptance);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "complete_ack" => {
                if let Some(sender) = state.relay_completions.write().await.remove(&session_id) {
                    let _ = sender.send(true);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "cancel" => {
                if let Some(sender) = state.relay_acceptances.write().await.remove(&session_id) {
                    let _ = sender.send(None);
                }
                if let Some(sender) = state.relay_completions.write().await.remove(&session_id) {
                    let _ = sender.send(false);
                }
                cancel_relay_incoming(&state, &session_id).await;
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
                ..
            } if kind == "channel_message" => {
                if let (Some(peer_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) =
                        receive_relay_channel_message(&state, &peer_id, &session_id, &payload).await
                    {
                        tracing::debug!(peer_id = %peer_id, error = %error, "rejected Relay DataMessage");
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
                ..
            } if kind == "channel_ack" => {
                if let (Some(peer_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) =
                        receive_relay_delivery_ack(&state, &peer_id, &session_id, &payload).await
                    {
                        tracing::debug!(peer_id = %peer_id, error = %error, "rejected Relay DeliveryAck");
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
            } if kind == "candidate_offer" || kind == "candidate_answer" => {
                if let (Some(peer_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) = handle_candidate_signal(
                        &state,
                        &relay,
                        &kind,
                        &session_id,
                        &peer_id,
                        &payload,
                    )
                    .await
                    {
                        tracing::debug!(peer_id = %peer_id, error = %error, "rejected Relay candidate signal");
                    }
                }
            }
            RelayEvent::Binary {
                session_id,
                sequence,
                payload,
                ..
            } => {
                if let Err(error) =
                    receive_relay_chunk(&state, &session_id, sequence, &payload).await
                {
                    emit_transfer_error(
                        &state.event_tx,
                        &session_id,
                        NetworkErrorCode::RelayError,
                        "Relay incoming chunk failed validation".to_string(),
                        "receive",
                        None,
                    );
                    cancel_relay_incoming(&state, &session_id).await;
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    tracing::warn!("Rejected inbound Relay chunk: {}", error);
                }
            }
            RelayEvent::Disconnected { reason } => {
                handle_relay_disconnect(Arc::clone(&state), relay.clone(), reason).await;
                break;
            }
            RelayEvent::Control { .. } => {}
        }
    }
    handle_relay_disconnect(state, relay, "Relay event stream ended".to_string()).await;
}

fn relay_crypto_key(peer_id: &str, session_token: &str) -> String {
    format!("{peer_id}/{session_token}")
}

async fn handle_relay_crypto_handshake(
    state: &Arc<RuntimeState>,
    relay: &Arc<RelayClient>,
    session_token: &str,
    peer_id: &str,
    encoded_payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if session_token.len() != 32
        || !session_token
            .bytes()
            .all(|value| value.is_ascii_hexdigit() && !value.is_ascii_uppercase())
        || peer_id.is_empty()
        || !state.peers.read().await.contains_key(peer_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay E2EE handshake is not bound to a registered peer",
        )
        .into());
    }
    let frame = URL_SAFE_NO_PAD.decode(encoded_payload)?;
    let (step, payload) = crate::crypto_handshake::decode_relay_frame(&frame)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    let key = relay_crypto_key(peer_id, session_token);
    match step {
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE => {
            let sender = state
                .relay_crypto_waiters
                .write()
                .await
                .remove(&key)
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE response has no active initiator",
                    )
                })?;
            sender.send(payload.to_vec()).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "Relay E2EE initiator is no longer waiting",
                )
            })?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_HELLO => {
            let identity = state
                .identity
                .read()
                .await
                .clone()
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
            let (responder, response) =
                crate::crypto_handshake::RelayResponderHandshake::accept_hello(identity, payload)
                    .map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
                })?;
            let mut responders = state.relay_crypto_responders.lock().await;
            if responders.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES
                && !responders.contains_key(&key)
            {
                return Err(std::io::Error::other("Relay E2EE responder queue is full").into());
            }
            responders.insert(key, responder);
            drop(responders);
            let response = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
                &response,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            relay
                .send_crypto_handshake(session_token, peer_id, &response)
                .await?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_FINAL => {
            let responder = state
                .relay_crypto_responders
                .lock()
                .await
                .remove(&key)
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE final message has no active responder",
                    )
                })?;
            let (authenticated_peer_id, material) = responder
                .accept_final(payload, &state.trusted_peer_keys)
                .await
                .map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, error.to_string())
                })?;
            if authenticated_peer_id != peer_id {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay E2EE identity does not match the routed peer",
                )
                .into());
            }
            let decision = state.sessions.begin_connect(peer_id).await;
            let session_id = match decision {
                crate::session::ConnectDecision::Started(session_id)
                | crate::session::ConnectDecision::InProgress(session_id) => session_id,
                crate::session::ConnectDecision::AlreadyConnected(session_id) => {
                    if state.sessions.current_route(peer_id).await != Some(RouteType::Relay) {
                        return Ok(());
                    }
                    session_id
                }
            };
            state
                .install_crypto_material(peer_id, &session_id.wire_key(), &material)
                .map_err(|error| std::io::Error::other(error.to_string()))?;
            if !state
                .sessions
                .mark_relay_route_connected(
                    peer_id,
                    session_id,
                    RouteType::Relay,
                    Some(Arc::clone(relay)),
                )
                .await
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "Relay Session was closed before E2EE completion",
                )
                .into());
            }
            crate::events::emit_peer_state(
                &state.event_tx,
                peer_id,
                network_protocol::PeerConnectionState::Connected,
                RouteType::Relay,
                None,
            );
            crate::channel::recover_session(Arc::clone(state), peer_id.to_string(), session_id)
                .await;
            crate::transfer::resume_transfers_for_peer(Arc::clone(state), peer_id.to_string())
                .await;
            crate::peer::schedule_direct_upgrade(
                Arc::clone(state),
                peer_id.to_string(),
                session_id,
            );
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "unsupported Relay E2EE handshake step",
            )
            .into());
        }
    }
    Ok(())
}

async fn handle_candidate_signal(
    state: &Arc<RuntimeState>,
    relay: &RelayClient,
    kind: &str,
    session_id: &str,
    peer_id: &str,
    payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "candidate sender is not a registered peer",
        )
        .into());
    }
    let encoded = URL_SAFE_NO_PAD.decode(payload)?;
    let signal: CandidateSignal = serde_json::from_slice(&encoded)?;
    signal.validate().map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid candidate signal: {error}"),
        )
    })?;
    let expected_kind = match kind {
        "candidate_offer" => CandidateSignalKind::Offer,
        "candidate_answer" => CandidateSignalKind::Answer,
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "unsupported candidate signal kind",
            )
            .into())
        }
    };
    if signal.kind != expected_kind {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "candidate signal kind does not match Relay control type",
        )
        .into());
    }
    if signal.kind == CandidateSignalKind::Answer {
        let attempt = state
            .candidate_attempts
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "candidate answer has no active local attempt",
                )
            })?;
        if attempt.attempt_id != signal.attempt_id || attempt.expires_at <= Instant::now() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "candidate answer does not match the active attempt",
            )
            .into());
        }
    }
    let candidates = signal
        .candidates
        .iter()
        .cloned()
        .map(Candidate::from_advertisement)
        .collect::<Result<Vec<_>, _>>()?;
    let manager = if let Some(manager) = state.path_managers.read().await.get(peer_id).cloned() {
        manager
    } else {
        let mut managers = state.path_managers.write().await;
        managers
            .entry(peer_id.to_string())
            .or_insert_with(|| Arc::new(network_nat::PathManager::new()))
            .clone()
    };
    if !manager
        .apply_remote_candidates(
            signal.kind,
            &signal.attempt_id,
            signal.connect_window_ms,
            signal.generation,
            candidates,
        )
        .await
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "candidate signal is stale for the current attempt",
        )
        .into());
    }
    state.candidate_signal_notify.notify_waiters();

    if signal.kind == CandidateSignalKind::Offer {
        let local_manager = state
            .local_path_manager
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("local candidate manager is unavailable"))?;
        let local_candidates = local_manager.ranked_candidates().await;
        let local_generation = local_manager.generation().await.max(1);
        let answer = CandidateSignal::answer(
            local_generation,
            signal.attempt_id.clone(),
            signal.connect_window_ms.min(DEFAULT_CONNECT_WINDOW_MS),
            local_candidates
                .iter()
                .map(network_nat::Candidate::advertisement)
                .collect(),
        );
        let answer_payload = serde_json::to_vec(&answer)?;
        relay
            .send_candidate_answer(session_id, peer_id, &answer_payload)
            .await?;
        crate::peer::spawn_candidate_punch(
            Arc::clone(state),
            peer_id.to_string(),
            signal.attempt_id,
            std::time::Duration::from_millis(u64::from(signal.connect_window_ms)),
        );
    }
    Ok(())
}

async fn handle_relay_disconnect(
    state: Arc<RuntimeState>,
    relay: Arc<RelayClient>,
    reason: String,
) {
    let mut current = state.relay.write().await;
    let is_current = current
        .as_ref()
        .is_some_and(|current| Arc::ptr_eq(current, &relay));
    if !is_current {
        return;
    }
    current.take();
    drop(current);
    cleanup_relay_state(&state).await;
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        Some(protocol_error_with_context(
            NetworkErrorCode::RelayError,
            format!("Relay socket disconnected: {reason}"),
            "relay",
            None,
        )),
    );
    if state.relay_config.read().await.is_some() {
        crate::events::emit_relay_state(
            &state.event_tx,
            network_protocol::RelayConnectionState::Connecting,
            None,
        );
        schedule_relay_reconnect(state);
    }
}

/// Relay 只转发 Base64 包装的 opaque DataMessage，业务解码仍在 native core。
async fn receive_relay_channel_message(
    state: &RuntimeState,
    peer_id: &str,
    session_token: &str,
    payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let encoded = URL_SAFE_NO_PAD.decode(payload)?;
    let message = DataMessage::decode(encoded.as_slice())?;
    if hex::encode(&message.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay channel token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_data_message(state, peer_id, &encoded).await
}

async fn receive_relay_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    session_token: &str,
    payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let encoded = URL_SAFE_NO_PAD.decode(payload)?;
    let ack = DeliveryAck::decode(encoded.as_slice())?;
    if hex::encode(&ack.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay ACK token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_delivery_ack(state, peer_id, &encoded).await
}

/// 清理一次 Relay socket 尝试，但保留可由新 socket 继续使用的业务状态。
///
/// `TransferManager` 和稳定 `.part` 属于 TransferSession，不属于 Relay socket；这里
/// 只丢弃当前 attempt token、等待中的 oneshot 和打开的文件句柄，绝不取消传输或删除
/// checkpoint。
async fn cleanup_relay_state(state: &RuntimeState) {
    let outgoing = state
        .relay_sessions
        .write()
        .await
        .drain()
        .map(|(transfer_id, _)| transfer_id)
        .collect::<Vec<_>>();
    let active = {
        let mut active = state.relay_active_incoming.lock().await;
        std::mem::take(&mut *active)
    };
    state.relay_acceptances.write().await.clear();
    state.relay_completions.write().await.clear();
    state.relay_lookups.write().await.clear();
    state.relay_crypto_waiters.write().await.clear();
    state.relay_crypto_responders.lock().await.clear();

    for transfer_id in outgoing {
        if state.transfers.pause_for_network(&transfer_id).await {
            tracing::debug!(transfer_id = %transfer_id, "Relay transfer paused after socket disconnect");
        }
    }
    for (transfer_id, incoming) in active {
        drop(incoming.file);
        if state.transfers.pause_for_network(&transfer_id).await {
            tracing::debug!(
                transfer_id = %transfer_id,
                "Relay incoming transfer paused; preserving checkpoint"
            );
        }
    }
}

/// 在通知 UI 前解密并校验传入 Relay 申请。
async fn receive_relay_offer(
    state: &Arc<RuntimeState>,
    session_id: String,
    sender_id: String,
    encoded_payload: String,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if session_id.len() != 32
        || !session_id.bytes().all(|value| value.is_ascii_hexdigit())
        || !state.peers.read().await.contains_key(&sender_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay sender is not a registered peer",
        )
        .into());
    }
    let envelope = URL_SAFE_NO_PAD.decode(encoded_payload)?;
    let session_bytes: [u8; 16] = hex::decode(&session_id)?.try_into().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Relay session ID")
    })?;
    let identity = state
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
    let clear = crypto::decrypt_application_offer(&envelope, &identity.e2e_key, &session_bytes)?;
    let value: serde_json::Value = serde_json::from_slice(&clear)?;
    let transfer_id = value
        .get("transfer_id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay transfer ID is missing"))?
        .to_string();
    let file_name = value
        .get("file_name")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay file name is missing"))?;
    let total_bytes = value
        .get("file_size")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| std::io::Error::other("Relay file size is invalid"))?;
    let modified_at = value
        .get("modified_at")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| std::io::Error::other("Relay modified time is invalid"))?;
    let content_hash = value
        .get("content_hash")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay content hash is missing"))?;
    let manifest_hash = value
        .get("manifest_hash")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay manifest hash is missing"))?;
    let offer_sender = value.get("sender_id").and_then(serde_json::Value::as_str);
    let receiver = value.get("receiver_id").and_then(serde_json::Value::as_str);
    if value.get("v").and_then(serde_json::Value::as_u64) != Some(1)
        || value
            .get("crypto_suite")
            .and_then(serde_json::Value::as_str)
            != Some(APPLICATION_CRYPTO_SUITE)
        || value.get("session_id").and_then(serde_json::Value::as_str) != Some(session_id.as_str())
        || value.get("transfer_id").and_then(serde_json::Value::as_str)
            != Some(transfer_id.as_str())
        || offer_sender != Some(sender_id.as_str())
        || receiver != Some(identity.device_id.as_str())
        || !is_sha256_hash(content_hash)
        || !is_sha256_hash(manifest_hash)
        || !is_safe_file_name(file_name)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer identity or metadata is invalid",
        )
        .into());
    }
    let crypto_session_id = value
        .get("crypto_session_id")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 16 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| std::io::Error::other("Relay crypto SessionId is invalid"))?
        .to_string();
    let manifest = FileManifest {
        transfer_id: transfer_id.clone(),
        file_name: file_name.to_string(),
        file_size: total_bytes,
        modified_at,
        content_hash: content_hash.to_string(),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    manifest
        .validate()
        .map_err(|message| std::io::Error::new(std::io::ErrorKind::InvalidData, message))?;
    if relay_manifest_hash(&manifest) != manifest_hash {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay manifest hash does not match metadata",
        )
        .into());
    }
    let logical_session_id = state
        .sessions
        .current_session_id(&sender_id)
        .await
        .ok_or_else(|| std::io::Error::other("logical Session is unavailable"))?
        .wire_key();
    let pending = PendingRelayIncoming {
        transfer_id: transfer_id.clone(),
        session_id: session_id.clone(),
        sender_id: sender_id.clone(),
        manifest: manifest.clone(),
        manifest_hash: manifest_hash.to_string(),
        crypto_session_id,
    };
    if state
        .relay_active_incoming
        .lock()
        .await
        .values()
        .any(|active| active.offer.transfer_id == transfer_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "Relay transfer is already receiving",
        )
        .into());
    }
    let mut is_new_offer = false;
    {
        let mut pending_transfers = state.relay_pending_incoming.write().await;
        if !pending_transfers.contains_key(&transfer_id)
            && pending_transfers.len() >= MAX_PENDING_INCOMING_TRANSFERS
        {
            return Err(std::io::Error::other("too many pending Relay offers").into());
        }
        if let Some(previous) = pending_transfers.get(&transfer_id) {
            if previous.sender_id != sender_id
                || previous.manifest != manifest
                || previous.manifest_hash != manifest_hash
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "TransferId is already bound to a different manifest",
                )
                .into());
            }
        } else {
            is_new_offer = true;
        }
        pending_transfers.insert(transfer_id.clone(), pending);
    }

    let resume_offset = state
        .transfers
        .claim_incoming_resume(&manifest, &sender_id, &logical_session_id)
        .await;
    let receive_directory = state.receive_directory.read().await.clone();
    let completed_path = if let Some(directory) = receive_directory.as_ref() {
        existing_completed_file(&manifest, directory).await?
    } else {
        None
    };
    if is_new_offer && resume_offset.is_none() {
        if !state
            .transfers
            .register_incoming(
                manifest.clone(),
                sender_id.clone(),
                logical_session_id.clone(),
            )
            .await
        {
            state
                .relay_pending_incoming
                .write()
                .await
                .remove(&transfer_id);
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "TransferId is already active",
            )
            .into());
        }
        if completed_path.is_none() {
            emit_incoming_offer(&state.event_tx, &sender_id, &manifest, RouteType::Relay);
        }
    }
    if resume_offset.is_some() || completed_path.is_some() {
        accept_pending_relay_incoming(state, &transfer_id).await?;
        return Ok(());
    }
    let expiry_state = Arc::clone(state);
    let expiry_transfer_id = transfer_id;
    let _ = state
        .task_supervisor
        .spawn_runtime("relay-approval-timeout", async move {
            tokio::time::sleep(INCOMING_APPROVAL_TIMEOUT).await;
            let expired = expiry_state
                .relay_pending_incoming
                .write()
                .await
                .get(&expiry_transfer_id)
                .is_some_and(|pending| pending.session_id == session_id);
            if expired {
                expiry_state
                    .relay_pending_incoming
                    .write()
                    .await
                    .remove(&expiry_transfer_id);
                expiry_state
                    .transfers
                    .fail_transfer(&expiry_transfer_id, TransferFailureReason::UserRejected)
                    .await;
                if let Some(relay) = expiry_state.relay.read().await.as_ref() {
                    let _ = relay.send_session_control("cancel", &session_id).await;
                }
            }
        });
    Ok(())
}

/// 应用传入 Relay 审批，并创建临时文件。
pub(crate) async fn respond_to_relay_incoming(
    state: &RuntimeState,
    transfer_id: &str,
    accepted: bool,
) -> Result<(), ProtocolError> {
    let pending = state
        .relay_pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| {
            protocol_error_with_context(
                NetworkErrorCode::InvalidArgument,
                "incoming transfer is not awaiting approval",
                "respond_incoming",
                None,
            )
        })?;
    if !accepted {
        state.transfers.cancel_transfer(transfer_id).await;
        state.transfers.remove_transfer(transfer_id).await;
        if let Some(relay) = state.relay.read().await.as_ref() {
            relay
                .send_session_control("cancel", &pending.session_id)
                .await
                .map_err(|_| {
                    protocol_error(NetworkErrorCode::RelayError, "Relay cancellation failed")
                })?;
        }
        return Ok(());
    }
    state
        .relay_pending_incoming
        .write()
        .await
        .insert(transfer_id.to_string(), pending);
    if let Err(error) = accept_pending_relay_incoming(state, transfer_id).await {
        cancel_relay_incoming(state, transfer_id).await;
        return Err(protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "respond_incoming",
            None,
        ));
    }
    Ok(())
}

/// 为首次审批或同一 TransferSession 的自动恢复创建接收 attempt。
async fn accept_pending_relay_incoming(
    state: &RuntimeState,
    transfer_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pending = state
        .relay_pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| std::io::Error::other("Relay transfer is not pending"))?;
    let relay = state.relay.read().await.clone().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotConnected, "Relay is unavailable")
    })?;
    let receive_directory = state
        .receive_directory
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
    tokio::fs::create_dir_all(&receive_directory).await?;
    let final_path = receive_directory.join(&pending.manifest.file_name);
    let temporary_path = relay_partial_path(&receive_directory, &pending.manifest.transfer_id);
    let (file, offset, hasher, already_completed) =
        if existing_completed_file(&pending.manifest, &receive_directory)
            .await?
            .is_some()
        {
            (None, pending.manifest.file_size, Sha256::new(), true)
        } else {
            if tokio::fs::symlink_metadata(&final_path).await.is_ok() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "destination file already exists with a different hash",
                )
                .into());
            }
            let offset = existing_partial_offset(&pending.manifest, &receive_directory).await?;
            if !valid_relay_offset(offset, pending.manifest.file_size) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "partial file offset is not aligned to Relay chunk boundary",
                )
                .into());
            }
            let hasher = hash_partial_file(&temporary_path, offset).await?;
            let mut options = tokio::fs::OpenOptions::new();
            options.write(true).read(true);
            let mut file = if offset == 0 {
                options
                    .create(true)
                    .truncate(true)
                    .open(&temporary_path)
                    .await?
            } else {
                let mut file = options.open(&temporary_path).await?;
                file.seek(SeekFrom::Start(offset)).await?;
                file
            };
            file.seek(SeekFrom::Start(offset)).await?;
            (Some(file), offset, hasher, false)
        };

    let expected_offset = state
        .transfers
        .snapshot(transfer_id)
        .await
        .filter(|snapshot| snapshot.state == network_transfer::TransferState::Resuming)
        .map(|snapshot| snapshot.bytes_transferred);
    if expected_offset.is_some_and(|expected| expected != offset) {
        drop(file);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "checkpoint offset does not match TransferSession",
        )
        .into());
    }
    state.transfers.update_progress(transfer_id, offset).await;
    if !state.transfers.mark_transferring(transfer_id).await {
        drop(file);
        return Err(std::io::Error::other("Relay transfer is no longer active").into());
    }
    let acceptance = serde_json::to_string(&RelayAcceptancePayload {
        v: 1,
        transfer_id: pending.transfer_id.clone(),
        manifest_hash: pending.manifest_hash.clone(),
        file_hash: pending.manifest.content_hash.clone(),
        offset,
    })?;
    state.relay_active_incoming.lock().await.insert(
        transfer_id.to_string(),
        ActiveRelayIncoming {
            offer: pending.clone(),
            file,
            temporary_path,
            final_path,
            next_sequence: offset / RELAY_FILE_CHUNK_BYTES,
            received_bytes: offset,
            hasher,
            already_completed,
        },
    );
    if let Err(error) = relay
        .send_session_control_with_payload("accept", &pending.session_id, Some(&acceptance))
        .await
    {
        if let Some(active) = state.relay_active_incoming.lock().await.remove(transfer_id) {
            drop(active.file);
        }
        state.transfers.pause_for_network(transfer_id).await;
        state
            .relay_pending_incoming
            .write()
            .await
            .insert(transfer_id.to_string(), pending);
        return Err(error.into());
    }
    Ok(())
}

/// 认证、排序并写入一个加密 Relay 分块。
async fn receive_relay_chunk(
    state: &RuntimeState,
    session_id: &str,
    sequence: u64,
    ciphertext: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active_transfers = state.relay_active_incoming.lock().await;
    let active = active_transfers
        .values_mut()
        .find(|active| active.offer.session_id == session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    let transfer_id = active.offer.transfer_id.clone();
    if active.already_completed
        || sequence != active.next_sequence
        || ciphertext.len() < 16
        || active.file.is_none()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk is replayed or reordered",
        )
        .into());
    }
    let crypto_session_id = active.offer.crypto_session_id.clone();
    let manifest_hash = active.offer.manifest_hash.clone();
    let aad = crypto::file_chunk_aad(&crypto_session_id, &transfer_id, &manifest_hash, sequence);
    let clear = state
        .decrypt_application_payload(
            &active.offer.sender_id,
            &crypto_session_id,
            CryptoMode::E2ee,
            &aad,
            ciphertext,
        )
        .await?;
    if clear.is_empty()
        || active.received_bytes + clear.len() as u64 > active.offer.manifest.file_size
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk exceeds declared file size",
        )
        .into());
    }
    active
        .file
        .as_mut()
        .expect("Relay active file checked above")
        .write_all(&clear)
        .await?;
    active.hasher.update(&clear);
    active.received_bytes += clear.len() as u64;
    active.next_sequence = crypto::next_sequence(active.next_sequence)?;
    emit_transfer_progress(
        &state.event_tx,
        &transfer_id,
        active.received_bytes,
        active.offer.manifest.file_size,
    );
    state
        .transfers
        .update_progress(&transfer_id, active.received_bytes)
        .await;
    Ok(())
}

/// 校验 Relay 完成状态，提交文件并发送 complete_ack。
async fn complete_relay_incoming(
    state: &RuntimeState,
    session_id: &str,
    sender_id: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (transfer_id, mut active) = {
        let mut active_transfers = state.relay_active_incoming.lock().await;
        let transfer_id = active_transfers
            .iter()
            .find(|(_, active)| active.offer.session_id == session_id)
            .map(|(transfer_id, _)| transfer_id.clone())
            .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
        let active = active_transfers
            .remove(&transfer_id)
            .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
        (transfer_id, active)
    };
    if sender_id != Some(active.offer.sender_id.as_str())
        || active.received_bytes != active.offer.manifest.file_size
    {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfers
            .fail_transfer(&transfer_id, TransferFailureReason::Protocol)
            .await;
        state.transfers.remove_transfer(&transfer_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay completion arrived before all bytes",
        )
        .into());
    }
    let relay = state
        .relay
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("Relay is unavailable"))?;
    if active.already_completed {
        state.transfers.mark_verifying(&transfer_id).await;
        state.transfers.mark_completed(&transfer_id).await;
        state.transfers.remove_transfer(&transfer_id).await;
        relay
            .send_session_control("complete_ack", session_id)
            .await?;
        return Ok(());
    }
    if !relay_hash_matches(active.hasher, &active.offer.manifest.content_hash) {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfers
            .fail_transfer(&transfer_id, TransferFailureReason::HashMismatch)
            .await;
        state.transfers.remove_transfer(&transfer_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay content hash does not match the offer",
        )
        .into());
    }
    if let Some(file) = active.file.as_mut() {
        if let Err(error) = file.flush().await {
            drop(active.file.take());
            tokio::fs::remove_file(&active.temporary_path).await.ok();
            state
                .transfers
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfers.remove_transfer(&transfer_id).await;
            return Err(error.into());
        }
    } else {
        return Err(std::io::Error::other("Relay active file is unavailable").into());
    }
    drop(active.file.take());
    if tokio::fs::symlink_metadata(&active.final_path)
        .await
        .is_ok()
    {
        if existing_completed_file(
            &active.offer.manifest,
            active
                .final_path
                .parent()
                .ok_or_else(|| std::io::Error::other("final path has no parent"))?,
        )
        .await?
        .is_none()
        {
            tokio::fs::remove_file(&active.temporary_path).await.ok();
            state
                .transfers
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfers.remove_transfer(&transfer_id).await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination file already exists with a different hash",
            )
            .into());
        }
        tokio::fs::remove_file(&active.temporary_path).await.ok();
    } else if let Err(error) = tokio::fs::rename(&active.temporary_path, &active.final_path).await {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfers
            .fail_transfer(&transfer_id, TransferFailureReason::Io)
            .await;
        state.transfers.remove_transfer(&transfer_id).await;
        return Err(error.into());
    }
    state.transfers.mark_verifying(&transfer_id).await;
    state.transfers.mark_completed(&transfer_id).await;
    state.transfers.remove_transfer(&transfer_id).await;
    emit_transfer_completed(
        &state.event_tx,
        &transfer_id,
        &active.final_path.to_string_lossy(),
    );
    relay
        .send_session_control("complete_ack", session_id)
        .await?;
    Ok(())
}

/// 取消或失败后移除待处理和临时 Relay 状态。
pub(crate) async fn cancel_relay_incoming(state: &RuntimeState, session_id: &str) {
    let pending = state
        .relay_pending_incoming
        .write()
        .await
        .remove(session_id);
    let active = {
        let mut active_transfers = state.relay_active_incoming.lock().await;
        if let Some(active) = active_transfers.remove(session_id) {
            Some((session_id.to_string(), active))
        } else {
            let transfer_id = active_transfers
                .iter()
                .find(|(_, active)| active.offer.session_id == session_id)
                .map(|(transfer_id, _)| transfer_id.clone());
            transfer_id.and_then(|transfer_id| {
                active_transfers
                    .remove(&transfer_id)
                    .map(|active| (transfer_id, active))
            })
        }
    };
    let transfer_id = pending
        .as_ref()
        .map(|pending| pending.transfer_id.clone())
        .or_else(|| active.as_ref().map(|(transfer_id, _)| transfer_id.clone()))
        .unwrap_or_else(|| session_id.to_string());
    if let Some((_, active)) = active {
        drop(active.file);
        tokio::fs::remove_file(active.temporary_path).await.ok();
    } else if let Some(directory) = state.receive_directory.read().await.clone() {
        tokio::fs::remove_file(relay_partial_path(&directory, &transfer_id))
            .await
            .ok();
    }
    state.transfers.cancel_transfer(&transfer_id).await;
    state.transfers.remove_transfer(&transfer_id).await;
}

/// CancelTransfer 的 Relay 侧清理入口；显式取消才会删除 checkpoint。
pub(crate) async fn cancel_transfer(state: &RuntimeState, transfer_id: &str) {
    let session_id = state.relay_sessions.write().await.remove(transfer_id);
    if let (Some(relay), Some(session_id)) = (state.relay.read().await.clone(), session_id) {
        let _ = relay.send_session_control("cancel", &session_id).await;
    }
    cancel_relay_incoming(state, transfer_id).await;
}

/// 返回 Relay 文件名是否是单个安全路径组件。
fn is_safe_file_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.contains(['/', '\\', '\0'])
        && std::path::Path::new(value).components().count() == 1
        && !matches!(
            std::path::Path::new(value).components().next(),
            Some(std::path::Component::ParentDir | std::path::Component::CurDir)
        )
}

/// 返回值是否为小写或大写形式的 SHA-256 十六进制摘要。
fn is_sha256_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// 返回接收内容的 SHA-256 摘要是否与 enrollment offer 一致。
fn relay_hash_matches(hasher: Sha256, expected: &str) -> bool {
    hex::encode(hasher.finalize()).eq_ignore_ascii_case(expected)
}

/// 计算稳定的 Manifest Hash；socket session token 不参与，因此重连可复用它。
fn relay_manifest_hash(manifest: &FileManifest) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"ssh-mobile/relay-manifest/v1\0");
    hasher.update(manifest.transfer_id.as_bytes());
    hasher.update([0]);
    hasher.update(manifest.file_name.as_bytes());
    hasher.update([0]);
    hasher.update(manifest.file_size.to_be_bytes());
    hasher.update(manifest.modified_at.to_be_bytes());
    hasher.update(manifest.content_hash.as_bytes());
    hasher.update(manifest.protocol_version.to_be_bytes());
    hex::encode(hasher.finalize())
}

fn relay_partial_path(directory: &std::path::Path, transfer_id: &str) -> PathBuf {
    directory.join(format!("{transfer_id}.part"))
}

fn valid_relay_offset(offset: u64, total_bytes: u64) -> bool {
    offset <= total_bytes
        && (offset == 0 || offset == total_bytes || offset.is_multiple_of(RELAY_FILE_CHUNK_BYTES))
}

async fn hash_partial_file(
    path: &std::path::Path,
    offset: u64,
) -> Result<Sha256, Box<dyn std::error::Error + Send + Sync>> {
    let mut hasher = Sha256::new();
    if offset == 0 && tokio::fs::symlink_metadata(path).await.is_err() {
        return Ok(hasher);
    }
    let mut file = tokio::fs::File::open(path).await?;
    let mut remaining = offset;
    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    while remaining > 0 {
        let to_read = std::cmp::min(remaining, buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..to_read]).await?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "partial file ended before its declared offset",
            )
            .into());
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(hasher)
}

fn is_transient_relay_error(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
        if let Some(error) = error.downcast_ref::<RelayError>() {
            if matches!(error, RelayError::NotConnected | RelayError::Socket(_)) {
                return true;
            }
        }
        if let Some(error) = error.downcast_ref::<std::io::Error>() {
            if matches!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::TimedOut
            ) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

/// 发送加密 Relay 申请、分块和完成确认。
pub(crate) async fn send_file_over_relay(
    peer: PeerConfig,
    transfer: ResumableTransfer,
    state: Arc<RuntimeState>,
) {
    let transfer_id = transfer.transfer_id.clone();
    let peer_id = transfer.peer_id.clone();
    let path = transfer.source_path.clone();
    let result = async {
        let relay = state
            .relay
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotConnected, "Relay is unavailable")
            })?;
        let current_manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        if current_manifest != transfer.manifest {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "source file changed during Relay transfer",
                )
                .into(),
            );
        }
        if !valid_relay_offset(transfer.offset, transfer.manifest.file_size) {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "transfer offset is not aligned to Relay chunk boundary",
                )
                .into(),
            );
        }
        let manifest = transfer.manifest.clone();
        let mut session_bytes = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut session_bytes);
        let session_id = hex::encode(session_bytes);
        let offer = serde_json::to_vec(&json!({
            "v": 1,
            "crypto_suite": APPLICATION_CRYPTO_SUITE,
            "session_id": session_id,
            "crypto_session_id": transfer.session_id,
            "transfer_id": manifest.transfer_id,
            "manifest_hash": relay_manifest_hash(&manifest),
            "sender_id": state.identity.read().await.as_ref().map(|identity| identity.device_id.as_str())
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?,
            "receiver_id": peer_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "modified_at": manifest.modified_at,
            "content_hash": manifest.content_hash,
        }))?;
        let encrypted_offer =
            crypto::encrypt_application_offer(&offer, peer.e2e_public_key, &session_bytes)?;
        let (acceptance_tx, acceptance_rx) = oneshot::channel();
        state
            .relay_acceptances
            .write()
            .await
            .insert(session_id.clone(), acceptance_tx);
        state
            .relay_sessions
            .write()
            .await
            .insert(transfer_id.clone(), session_id.clone());
        relay
            .send_offer(
                &session_id,
                &peer_id,
                &URL_SAFE_NO_PAD.encode(encrypted_offer),
            )
            .await?;
        let acceptance_result = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx).await;
        state.relay_acceptances.write().await.remove(&session_id);
        let acceptance = match acceptance_result {
            Ok(Ok(Some(acceptance))) => acceptance,
            Ok(Ok(None)) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "Relay receiver rejected file",
                    )
                    .into(),
                )
            }
            Ok(Err(_)) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::NotConnected,
                        "Relay acceptance channel closed",
                    )
                    .into(),
                )
            }
            Err(_) => {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "Relay receiver approval timed out",
                    )
                    .into(),
                )
            }
        };
        let expected_manifest_hash = relay_manifest_hash(&manifest);
        if acceptance.transfer_id != manifest.transfer_id
            || acceptance.v != 1
            || acceptance.manifest_hash != expected_manifest_hash
            || !acceptance.file_hash.eq_ignore_ascii_case(&manifest.content_hash)
            || !valid_relay_offset(acceptance.offset, manifest.file_size)
            || acceptance.offset < transfer.offset
        {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Relay acceptance does not match TransferSession",
                )
                .into(),
            );
        }
        if !state.transfers.mark_transferring(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::other("transfer is no longer active").into(),
            );
        }
        state
            .transfers
            .update_progress(&transfer_id, acceptance.offset)
            .await;
        let mut file = tokio::fs::File::open(&path).await?;
        file.seek(SeekFrom::Start(acceptance.offset)).await?;
        let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
        let mut sequence = acceptance.offset / RELAY_FILE_CHUNK_BYTES;
        let mut transferred = acceptance.offset;
        let cancellation = state.transfers.cancellation_token(&transfer_id).await;
        loop {
            if cancellation
                .as_ref()
                .is_some_and(network_transfer::TransferCancellation::is_cancelled)
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "Relay transfer cancelled",
                )
                .into());
            }
            let to_read = std::cmp::min(
                buffer.len() as u64,
                manifest.file_size.saturating_sub(transferred),
            ) as usize;
            let read = file.read(&mut buffer[..to_read]).await?;
            if read == 0 {
                break;
            }
            let aad = crypto::file_chunk_aad(
                &transfer.session_id,
                &manifest.transfer_id,
                &relay_manifest_hash(&manifest),
                sequence,
            );
            let ciphertext = state
                .encrypt_application_payload(
                    &peer_id,
                    &transfer.session_id,
                    CryptoMode::E2ee,
                    &aad,
                    &buffer[..read],
                )
                .await?;
            relay
                .forward_opaque_payload(&session_id, sequence, &ciphertext)
                .await?;
            sequence = crypto::next_sequence(sequence)?;
            transferred += read as u64;
            state
                .transfers
                .update_progress(&transfer_id, transferred)
                .await;
            emit_transfer_progress(
                &state.event_tx,
                &transfer_id,
                transferred,
                manifest.file_size,
            );
        }
        if transferred != manifest.file_size {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "Relay source size changed during transfer",
            )
            .into());
        }
        let (completion_tx, completion_rx) = oneshot::channel();
        state
            .relay_completions
            .write()
            .await
            .insert(session_id.clone(), completion_tx);
        relay.send_session_control("complete", &session_id).await?;
        let completed = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, completion_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay_completions.write().await.remove(&session_id);
        if !completed {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Relay completion acknowledgement timed out",
            )
                .into());
        }
        state.transfers.mark_verifying(&transfer_id).await;
        state.transfers.mark_completed(&transfer_id).await;
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    if let Some(session_id) = state.relay_sessions.write().await.remove(&transfer_id) {
        if result.is_err()
            && !result
                .as_ref()
                .err()
                .is_some_and(|error| is_transient_relay_error(error.as_ref()))
        {
            if let Some(relay) = state.relay.read().await.as_ref() {
                let _ = relay.send_session_control("cancel", &session_id).await;
            }
        }
    }
    if result.is_ok() || state.transfers.is_cancelled(&transfer_id).await {
        state.transfers.remove_transfer(&transfer_id).await;
    } else if let Err(error) = result {
        if is_transient_relay_error(error.as_ref())
            && state.transfers.pause_for_network(&transfer_id).await
        {
            tracing::debug!(
                transfer_id = %transfer_id,
                error = %error,
                "native Relay transfer paused for socket recovery"
            );
            return;
        }
        let reason = if error
            .downcast_ref::<std::io::Error>()
            .is_some_and(|error| error.kind() == std::io::ErrorKind::InvalidData)
        {
            TransferFailureReason::SourceChanged
        } else {
            TransferFailureReason::Io
        };
        state.transfers.fail_transfer(&transfer_id, reason).await;
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::RelayError,
            "Relay transfer failed".to_string(),
            "send",
            Some(&peer_id),
        );
        state.transfers.remove_transfer(&transfer_id).await;
        tracing::debug!(transfer_id = %transfer_id, error = %error, "native Relay file transfer failed");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 验证 Relay offer 只接受完整的 SHA-256 十六进制摘要。
    #[test]
    fn relay_offer_requires_sha256_hash() {
        let digest = hex::encode(Sha256::digest(b"relay-v1"));
        assert!(is_sha256_hash(&digest));
        assert!(!is_sha256_hash(&digest[..63]));
        let mut invalid = digest.clone();
        invalid.replace_range(0..1, "z");
        assert!(!is_sha256_hash(&invalid));
    }

    /// 验证接收哈希不匹配时不会被视为完成。
    #[test]
    fn relay_hash_mismatch_is_rejected() {
        let mut hasher = Sha256::new();
        hasher.update(b"received");
        assert!(!relay_hash_matches(
            hasher,
            &hex::encode(Sha256::digest(b"offered"))
        ));
    }

    #[test]
    fn relay_resume_offset_requires_fixed_chunk_boundary() {
        assert!(valid_relay_offset(0, RELAY_FILE_CHUNK_BYTES * 4 + 7));
        assert!(valid_relay_offset(
            RELAY_FILE_CHUNK_BYTES * 3,
            RELAY_FILE_CHUNK_BYTES * 4 + 7
        ));
        assert!(valid_relay_offset(
            RELAY_FILE_CHUNK_BYTES * 4 + 7,
            RELAY_FILE_CHUNK_BYTES * 4 + 7
        ));
        assert!(!valid_relay_offset(
            RELAY_FILE_CHUNK_BYTES * 3 + 1,
            RELAY_FILE_CHUNK_BYTES * 4 + 7
        ));
        assert!(!valid_relay_offset(
            RELAY_FILE_CHUNK_BYTES * 5,
            RELAY_FILE_CHUNK_BYTES * 4 + 7
        ));
    }

    #[test]
    fn relay_acceptance_binds_transfer_manifest_hash_file_hash_and_offset() {
        let payload = RelayAcceptancePayload {
            v: 1,
            transfer_id: "transfer-1".into(),
            manifest_hash: "a".repeat(64),
            file_hash: "b".repeat(64),
            offset: RELAY_FILE_CHUNK_BYTES,
        };
        let encoded = serde_json::to_string(&payload).expect("encode acceptance");
        let decoded: RelayAcceptance = serde_json::from_str(&encoded).expect("decode acceptance");
        assert_eq!(decoded.v, 1);
        assert_eq!(decoded.transfer_id, "transfer-1");
        assert_eq!(decoded.manifest_hash, "a".repeat(64));
        assert_eq!(decoded.file_hash, "b".repeat(64));
        assert_eq!(decoded.offset, RELAY_FILE_CHUNK_BYTES);
    }

    #[test]
    fn relay_manifest_hash_changes_when_source_manifest_changes() {
        let manifest = FileManifest {
            transfer_id: "transfer-1".into(),
            file_name: "payload.bin".into(),
            file_size: 4,
            modified_at: 1,
            content_hash: "a".repeat(64),
            protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
        };
        let mut changed = manifest.clone();
        changed.modified_at = 2;
        assert_ne!(
            relay_manifest_hash(&manifest),
            relay_manifest_hash(&changed)
        );
    }

    #[test]
    fn relay_file_chunk_uses_session_application_context() {
        let sender = network_identity::DeviceIdentity::from_private_keys(
            "sender".into(),
            [11u8; 32],
            [21u8; 32],
        );
        let receiver = network_identity::DeviceIdentity::from_private_keys(
            "receiver".into(),
            [12u8; 32],
            [22u8; 32],
        );
        let session_id = "0000000000000001";
        let transfer_id = "relay-transfer";
        let manifest_hash = "a".repeat(64);
        let aad = crypto::file_chunk_aad(session_id, transfer_id, &manifest_hash, 3);
        let mut sender_context = crate::crypto::CryptoContext::from_identity(
            &sender,
            *receiver.public_e2e_key().as_bytes(),
            session_id,
        )
        .expect("sender Session crypto");
        let mut receiver_context = crate::crypto::CryptoContext::from_identity(
            &receiver,
            *sender.public_e2e_key().as_bytes(),
            session_id,
        )
        .expect("receiver Session crypto");
        let ciphertext = sender_context
            .encrypt(&aad, b"opaque relay chunk")
            .expect("encrypt Relay chunk");
        assert_ne!(ciphertext, b"opaque relay chunk");
        assert_eq!(
            receiver_context.decrypt(&aad, &ciphertext).unwrap(),
            b"opaque relay chunk"
        );
        assert!(receiver_context
            .decrypt(
                &crypto::file_chunk_aad(session_id, transfer_id, &manifest_hash, 4),
                &ciphertext,
            )
            .is_err());
    }
}
