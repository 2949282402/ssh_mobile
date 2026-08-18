//! Relay v2 控制面 + reservation 数据面（transport-network v2 §24/§25/§31/§32）。
//!
//! v1 单一 `RelayClient`（`/v1/connect` JSON 控制 + 0x10 二进制数据）已在 Step 11
//! 删除。Relay 控制面（`/v2/control`）与数据面（`/v2/relay/{reservation_id}`）物理
//! 隔离：
//!
//! - 控制面：`RelayControlClient`。Resolve / Discovery / Connectivity / Presence /
//!   Realtime / Reservation 均经它路由（§31 `reserveRelay`）。
//! - 数据面：`RelayDataClient`（§25）。Direct 失败后由 `ConnectionOrchestrator` 经
//!   `reserve_relay` 获取 reservation，双方连接 `/v2/relay/{reservation_id}`；文件、
//!   流与可靠消息数据以不透明信封在数据面上转发（服务器不解密业务数据）。

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_protocol::{
    ConfigureRelayCommand, DataMessage, DeliveryAck, NetworkError as ProtocolError,
    NetworkErrorCode, PeerPresenceChangedEvent, PeerPresenceState, RouteType,
};
use network_relay::v2::{
    ConnectivityOffer, ControlEvent, DataEvent, DiscoverySnapshot, RuntimeEpoch,
};
use network_relay::{RelayControlClient, RelayDataClient, RelayError};
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
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio::sync::{mpsc, oneshot};

use crate::connection::{decode_generic_frame, GenericFrameKind};
use crate::crypto::{self, CryptoMode, APPLICATION_CRYPTO_SUITE};
use crate::events::{
    emit_incoming_offer, emit_peer_presence_changed, emit_peer_presence_snapshot,
    emit_transfer_completed, emit_transfer_error, emit_transfer_progress, protocol_error,
    protocol_error_with_context, protocol_error_with_retry,
};
use crate::runtime::{
    PeerConfig, RuntimeState, INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS,
    MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
};
use network_nat::{
    Candidate, CandidateAdvertisement, ConnectivityAttempt, ConnectivityAttemptState,
};
use network_protocol::RetryDisposition;
use std::time::SystemTime;

/// Relay 配置只存在 native runtime 内存中，用于控制面 socket 意外断开后的指数退避重连。
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

/// Relay 文件分块信封的固定开销：数据面 kind 标签(1) + session_id(32) +
/// sequence u64(8) + 应用 crypto 信封头(26，= crypto.rs ENVELOPE_HEADER_BYTES =
/// magic 4 + version 1 + suite 1 + epoch u64 8 + nonce 12) + GCM 认证标签(16，=
/// crypto.rs GCM_TAG_BYTES)。整块加密后包上 DATA_ENV_FILE_CHUNK 信封仍必须落在
/// 数据面 MAX_DATA_PAYLOAD_BYTES(512 KiB) 之内，否则 RelayDataClient::send 会以
/// InvalidConfiguration 拒绝，导致整份文件发送失败。
const RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES: usize = 1 + 32 + 8 + 26 + 16;

/// Relay 文件每个分块固定边界，确保断线时的 offset 能无歧义映射到 nonce 序号。
/// 明文分块比 DEFAULT_TRANSFER_BUFFER 小一个信封开销，加密后的整封不超数据面上限。
const RELAY_FILE_CHUNK_BYTES: u64 =
    (DEFAULT_TRANSFER_BUFFER - RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES) as u64;

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

// ---------------------------------------------------------------------------
// 数据面不透明信封（§25：数据通道只做 Encrypted Payload Forwarding）。
// 信封第一字节是类型标签（对 Relay 透明，不属于业务数据），其余为业务负载。
// ---------------------------------------------------------------------------

const DATA_ENV_CRYPTO: u8 = 0x01;
const DATA_ENV_FILE_OFFER: u8 = 0x02;
const DATA_ENV_FILE_ACCEPT: u8 = 0x03;
const DATA_ENV_FILE_COMPLETE: u8 = 0x04;
const DATA_ENV_FILE_COMPLETE_ACK: u8 = 0x05;
const DATA_ENV_FILE_CANCEL: u8 = 0x06;
const DATA_ENV_FILE_CHUNK: u8 = 0x07;
const DATA_ENV_CHANNEL: u8 = 0x08;
const DATA_ENV_CHANNEL_ACK: u8 = 0x09;
const DATA_ENV_STREAM: u8 = 0x0A;

/// 封装并发送一个数据面信封（sequence=0；文件分块单独使用真实序号）。
async fn send_data_envelope(
    data: &RelayDataClient,
    kind: u8,
    body: &[u8],
) -> Result<(), RelayError> {
    let mut envelope = Vec::with_capacity(1 + body.len());
    envelope.push(kind);
    envelope.extend_from_slice(body);
    data.send(0, &envelope).await
}

/// 封装并发送一个带 token 前缀的数据面信封（crypto/channel/stream 使用）。
async fn send_data_envelope_with_token(
    data: &RelayDataClient,
    kind: u8,
    token: &str,
    body: &[u8],
) -> Result<(), RelayError> {
    if token.len() > u8::MAX as usize {
        return Err(RelayError::InvalidConfiguration(
            "relay data envelope token is too long".into(),
        ));
    }
    let mut envelope = Vec::with_capacity(1 + 1 + token.len() + body.len());
    envelope.push(kind);
    envelope.push(token.len() as u8);
    envelope.extend_from_slice(token.as_bytes());
    envelope.extend_from_slice(body);
    data.send(0, &envelope).await
}

/// 发送一条 Relay E2EE 握手帧（加密握手不是业务数据，但复用数据面不透明转发）。
pub(crate) async fn send_relay_crypto(
    data: &RelayDataClient,
    token: &str,
    step: u8,
    payload: &[u8],
) -> Result<(), RelayError> {
    let frame = crate::crypto_handshake::encode_relay_frame(step, payload)
        .map_err(|error| RelayError::Protocol(error.to_string()))?;
    if token.len() != 32
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(RelayError::InvalidConfiguration(
            "relay crypto token must be 32 lowercase hexadecimal characters".into(),
        ));
    }
    let mut body = Vec::with_capacity(32 + frame.len());
    body.extend_from_slice(token.as_bytes());
    body.extend_from_slice(&frame);
    send_data_envelope(data, DATA_ENV_CRYPTO, &body).await
}

/// 发送一条 Relay 可靠消息（DataMessage protobuf 封装）。
pub(crate) async fn send_relay_channel_message(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_CHANNEL, token, payload).await
}

/// 发送一条 Relay DeliveryAck。
pub(crate) async fn send_relay_channel_ack(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_CHANNEL_ACK, token, payload).await
}

/// 发送一条 Relay byte-stream 帧（StreamOpen/StreamBytes/StreamClose）。
pub(crate) async fn send_relay_stream_frame(
    data: &RelayDataClient,
    token: &str,
    payload: &[u8],
) -> Result<(), RelayError> {
    send_data_envelope_with_token(data, DATA_ENV_STREAM, token, payload).await
}

/// 解码一个 token 前缀信封，返回 (token, body)。
fn decode_token_envelope(envelope: &[u8]) -> Result<(&str, &[u8]), RelayError> {
    if envelope.len() < 2 {
        return Err(RelayError::Protocol(
            "relay data envelope is truncated".into(),
        ));
    }
    let token_len = envelope[0] as usize;
    if envelope.len() < 1 + token_len {
        return Err(RelayError::Protocol(
            "relay data envelope token is truncated".into(),
        ));
    }
    let token = std::str::from_utf8(&envelope[1..1 + token_len])
        .map_err(|_| RelayError::Protocol("relay data envelope token is not UTF-8".into()))?;
    Ok((token, &envelope[1 + token_len..]))
}

/// 连接原生 Relay v2 控制面并启动事件消费者（§31 `RelayControlClient`）。
pub(crate) async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(&state).await;
    // 新的 ConfigureRelayCommand 携带新凭据，重置过期标记并清空旧配置。
    state
        .relay_credential_stale
        .store(false, std::sync::atomic::Ordering::Release);
    state.relay_config.write().await.take();
    disconnect_relay_data(state.as_ref()).await;
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
    *state.relay_config.write().await = Some(config.clone());
    if let Err(error) = setup_v2_control_plane(&state, &device_id, &config).await {
        // 控制面 socket 未建立：发布类型化 Failed（不伪造 Connected），Dart 据此
        // 提示或重新下发 ConfigureRelayCommand（凭据过期/冲突时携带类型化错误）。
        crate::events::emit_relay_state(
            &state.event_tx,
            network_protocol::RelayConnectionState::Failed,
            Some(error.clone()),
        );
        return Err(error);
    }
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Connected,
        None,
    );
    // transport-network v2：控制连接建立后发布完整 Discovery Snapshot（§8/§9）。
    crate::discovery::spawn_control_connected(&state);
    crate::transfer::resume_relay_transfers(state).await;
    Ok(())
}

/// transport-network v2：建立 `/v2/control` 控制面客户端并启动事件消费者。
///
/// 失败时返回类型化错误。凭据过期/身份冲突是终态错误：标记 `relay_credential_stale`
/// 并停止重连（现有 stale 守卫随后生效），等待 Dart 下发新 ConfigureRelayCommand 后
/// 恢复；其余传输错误仍走既有退避重连。
async fn setup_v2_control_plane(
    state: &Arc<RuntimeState>,
    device_id: &str,
    config: &RelayReconnectConfig,
) -> Result<(), ProtocolError> {
    let mut control = match RelayControlClient::new(
        config.relay_url.clone(),
        device_id.to_string(),
        config.credential.clone(),
        config.signing_seed,
    ) {
        Ok(control) => control,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 control client creation failed");
            return Err(relay_connect_protocol_error(&error, "setup_control_plane"));
        }
    };
    if let Err(error) = control.connect().await {
        tracing::warn!(error = %error, "Relay v2 control client connect failed");
        if matches!(
            error,
            RelayError::CredentialExpired(_) | RelayError::IdentityConflict(_)
        ) {
            // 终态认证错误：凭据已失效，盲目重连只会复用无效凭据；等待 Dart 下发
            // 新 ConfigureRelayCommand（configure 入口会重置该标记）。
            state
                .relay_credential_stale
                .store(true, std::sync::atomic::Ordering::Release);
        } else {
            schedule_relay_reconnect(Arc::clone(state));
        }
        return Err(relay_connect_protocol_error(&error, "setup_control_plane"));
    }
    let events = control.take_events().map_err(|error| {
        tracing::warn!(error = %error, "Relay v2 control events were already consumed");
        relay_connect_protocol_error(&error, "setup_control_plane")
    })?;
    let control = Arc::new(control);
    *state.relay_control.write().await = Some(control.clone());
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("relay-v2-control-events", async move {
        consume_control_events(state, control, events).await;
    });
    Ok(())
}

/// 消费 Relay v2 控制面异步事件（presence hints / inbound ConnectivityOffer /
/// IncomingRelayReservation / RealtimeSignal / Disconnected）。
async fn consume_control_events(
    state: Arc<RuntimeState>,
    control: Arc<RelayControlClient>,
    mut events: mpsc::Receiver<ControlEvent>,
) {
    while let Some(event) = events.recv().await {
        match event {
            ControlEvent::PresenceHintSnapshot(snapshot) => {
                let online = snapshot
                    .peers
                    .iter()
                    .map(|peer| {
                        let generation = u64::from(peer.revision);
                        (peer.device_id.clone(), generation)
                    })
                    .collect::<Vec<_>>();
                let dropped = state.presence_hints.reconcile_snapshot(&online);
                for device_id in &dropped {
                    emit_peer_presence_changed(
                        &state.event_tx,
                        device_id,
                        0,
                        PeerPresenceState::Offline,
                    );
                }
                emit_peer_presence_snapshot(
                    &state.event_tx,
                    snapshot
                        .peers
                        .iter()
                        .map(|peer| PeerPresenceChangedEvent {
                            peer_id: peer.device_id.clone(),
                            generation: u64::from(peer.revision),
                            state: PeerPresenceState::Online as i32,
                        })
                        .collect(),
                );
            }
            ControlEvent::PeerAvailableHint(hint) => {
                let generation = u64::from(hint.revision);
                state
                    .presence_hints
                    .mark_online(&hint.device_id, generation);
                emit_peer_presence_changed(
                    &state.event_tx,
                    &hint.device_id,
                    generation,
                    PeerPresenceState::Online,
                );
            }
            ControlEvent::PeerUnavailableHint(hint) => {
                state.presence_hints.mark_offline(&hint.device_id);
                emit_peer_presence_changed(
                    &state.event_tx,
                    &hint.device_id,
                    0,
                    PeerPresenceState::Offline,
                );
            }
            ControlEvent::ConnectivityOffer(offer) => {
                // 应答方视角（§14）：先回送 Answer，再在同一个 attempt window
                // 向 initiator_snapshot 中的候选发起认证检查；本端 accept loop
                // 同时继续接收发起方打进来的 QUIC Initial。
                if let Some(identity) = state.identity.read().await.clone() {
                    let (epoch, revision, snapshot) = local_discovery_tuple(&state).await;
                    let _ = control
                        .send_connectivity_answer(
                            &offer,
                            true,
                            &identity.device_id,
                            epoch,
                            revision,
                            snapshot,
                        )
                        .await;
                    spawn_responder_connectivity_checks(Arc::clone(&state), offer);
                }
            }
            ControlEvent::IncomingRelayReservation(reservation) => {
                // §25：应答方收到 reservation 后连接 /v2/relay/{reservation_id}，
                // 建立数据面客户端并启动事件循环（crypto 握手 + 文件/流/消息）。
                connect_incoming_relay_data(&state, reservation).await;
            }
            ControlEvent::RealtimeSignal(signal) => {
                // §17/§22：WebRTC 信令经 v2 Relay Control Plane；入站帧路由到
                // RealtimeManager 做 Offer/Answer/ICE 协商。
                if let Err(error) =
                    crate::realtime::handle_v2_realtime_signal(&state, &signal).await
                {
                    tracing::debug!(
                        peer_id = %signal.sender_device_id,
                        error = %error,
                        "rejected v2 WebRTC signaling control"
                    );
                }
            }
            ControlEvent::Disconnected { reason } => {
                tracing::debug!(reason, "Relay v2 control disconnected");
                // 意外断开：先取走控制面 sink 再调度重连，否则重连循环第一处守卫
                // （relay_control.is_some()）会立即 break——死 client 仍占位，
                // setup_v2_control_plane 永远不会被再次调用，Discovery / Resolve /
                // reserve_relay / Realtime 信令持续失效。
                state.relay_control.write().await.take();
                schedule_relay_reconnect(Arc::clone(&state));
                break;
            }
            _ => {}
        }
    }
}

/// Starts the responder half of a one-shot connectivity attempt. The
/// initiator's snapshot is copied into an attempt-scoped candidate set; no
/// candidate is written to PathManager or reused by a later attempt.
fn spawn_responder_connectivity_checks(state: Arc<RuntimeState>, offer: ConnectivityOffer) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_runtime("connectivity-responder-checks", async move {
        let peer_id = offer.initiator_device_id.clone();
        let peer = state.peers.read().await.get(&peer_id).cloned();
        let Some(peer) = peer else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "ignored offer for unconfigured peer");
            return;
        };
        let endpoint = state.endpoint.read().await.clone();
        let Some(endpoint) = endpoint else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "cannot run responder checks without endpoint");
            return;
        };
        let identity = state.identity.read().await.clone();
        let Some(identity) = identity else {
            return;
        };
        let mut candidates = connectivity_offer_candidates(&offer);
        if let Some(configured_endpoint) = peer.endpoint {
            if !candidates
                .iter()
                .any(|candidate| candidate.endpoint == configured_endpoint)
            {
                candidates.push(Candidate::new(
                    configured_endpoint,
                    crate::peer::candidate_kind_for(configured_endpoint),
                    "peer-configured".into(),
                ));
            }
        }
        let local_epoch = state
            .local_discovery
            .read()
            .await
            .as_ref()
            .map(|manager| manager.runtime_epoch().low)
            .unwrap_or(0);
        let mut attempt = ConnectivityAttempt::with_connect_window(
            offer.attempt_id.clone(),
            peer_id.clone(),
            local_epoch,
            SystemTime::now(),
            crate::connect::DIRECT_CONNECT_WINDOW,
        );
        let _ = attempt.apply_remote_candidates(
            offer
                .initiator_runtime_epoch
                .as_ref()
                .map(|epoch| epoch.high.rotate_left(17) ^ epoch.low),
            u64::from(offer.initiator_revision),
            candidates.clone(),
        );
        let _ = attempt.set_state(ConnectivityAttemptState::Resolved);
        let _ = attempt.set_state(ConnectivityAttemptState::Coordinating);
        let _ = attempt.set_state(ConnectivityAttemptState::Connecting);
        let digest = Sha256::digest(offer.attempt_id.as_bytes());
        let session_binding = hex::encode(&digest[..16]);
        let result = crate::peer::connect_responder_direct(
            endpoint,
            candidates,
            identity,
            peer.identity_public_key,
            peer_id.clone(),
            offer.attempt_id.clone(),
            session_binding,
            Arc::clone(&state),
            crate::connect::DIRECT_CONNECT_WINDOW,
        )
        .await;
        match result {
            Ok(route) => {
                let _ = attempt.set_state(ConnectivityAttemptState::Succeeded);
                let orchestrator = crate::connect::ConnectionOrchestrator::new(state);
                if let Err(error) = orchestrator.attach_direct_route(&peer_id, route).await {
                    tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, error = %error.message, "responder direct route was not attached");
                }
            }
            Err(error) => {
                let _ = attempt.set_state(if error.code == network_protocol::NetworkErrorCode::Timeout as i32 {
                    ConnectivityAttemptState::Expired
                } else {
                    ConnectivityAttemptState::Failed
                });
                tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, error = %error.message, "responder direct checks failed");
            }
        }
    });
}

fn connectivity_offer_candidates(offer: &ConnectivityOffer) -> Vec<Candidate> {
    offer
        .initiator_snapshot
        .as_ref()
        .and_then(|snapshot| snapshot.candidate_bundle.as_ref())
        .into_iter()
        .flat_map(|bundle| bundle.candidates.iter())
        .filter_map(|bytes| serde_json::from_slice::<CandidateAdvertisement>(bytes).ok())
        .filter_map(|advertisement| Candidate::from_advertisement(advertisement).ok())
        .collect()
}

/// 读取本地 Discovery 三元组（epoch / revision / snapshot），供 offer/answer 附带。
async fn local_discovery_tuple(
    state: &RuntimeState,
) -> (RuntimeEpoch, u32, Option<DiscoverySnapshot>) {
    let Some(manager) = state.local_discovery.read().await.clone() else {
        return (RuntimeEpoch { high: 0, low: 0 }, 1, None);
    };
    (
        manager.runtime_epoch(),
        manager.revision(),
        Some(manager.snapshot()),
    )
}

/// 断开原生 Relay 数据面客户端，并发布类型化最终状态。
pub(crate) async fn disconnect_relay(state: &RuntimeState) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(state).await;
    state.relay_config.write().await.take();
    disconnect_relay_data(state).await;
    state.relay_control.write().await.take();
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        None,
    );
    Ok(())
}

/// 取走并断开全部 reservation 数据面客户端。
async fn disconnect_relay_data(state: &RuntimeState) {
    let data = state.relay_data.write().await.drain().collect::<Vec<_>>();
    for (_, data) in data {
        data.request_disconnect().await;
    }
    // 断开全部 reservation：清理所有对端的 Relay 状态。
    cleanup_relay_state(state, None).await;
}

/// 只在控制面 socket 意外结束时启动一个共享重连任务；显式 DisconnectRelay 会先
/// 清除配置，因此不会被这个后台任务重新拉起。
fn schedule_relay_reconnect(state: Arc<RuntimeState>) {
    if state
        .relay_reconnect_active
        .swap(true, std::sync::atomic::Ordering::AcqRel)
    {
        return;
    }
    if state
        .relay_credential_stale
        .load(std::sync::atomic::Ordering::Acquire)
    {
        // 凭据已被判定过期/冲突，盲目重连只会复用失效凭据；等待 Dart 下发新的
        // ConfigureRelayCommand 后再恢复。
        state
            .relay_reconnect_active
            .store(false, std::sync::atomic::Ordering::Release);
        return;
    }
    let reconnect_state = Arc::clone(&state);
    let task_id = state
        .task_supervisor
        .spawn_runtime("relay-reconnect", async move {
            let mut backoff = crate::runtime::RECONNECT_INITIAL_BACKOFF;
            loop {
                tokio::time::sleep(backoff).await;
                if reconnect_state
                    .relay_credential_stale
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    break;
                }
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
                if reconnect_state.relay_control.read().await.is_some() {
                    break;
                }
                reconnect_state.relay_control.write().await.take();
                match setup_v2_control_plane(&reconnect_state, &device_id, &config).await {
                    Ok(()) => {
                        crate::discovery::spawn_control_connected(&reconnect_state);
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Connected,
                            None,
                        );
                        crate::transfer::resume_relay_transfers(Arc::clone(&reconnect_state)).await;
                        break;
                    }
                    Err(error)
                        if reconnect_state
                            .relay_credential_stale
                            .load(std::sync::atomic::Ordering::Acquire) =>
                    {
                        // 凭据过期/冲突：停止重连并发布类型化 Failed（现有 stale 守卫
                        // 随后生效），Dart 据此下发新的 ConfigureRelayCommand。
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Failed,
                            Some(error),
                        );
                        break;
                    }
                    Err(error) => {
                        tracing::debug!(error = ?error, "Relay reconnect attempt failed");
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

/// 应答方收到 `IncomingRelayReservation` 后连接数据面并启动事件循环。
async fn connect_incoming_relay_data(
    state: &Arc<RuntimeState>,
    reservation: network_relay::v2::IncomingRelayReservation,
) {
    let Some(config) = state.relay_config.read().await.clone() else {
        tracing::warn!("incoming relay reservation arrived without a Relay config");
        return;
    };
    let mut data = match RelayDataClient::new(
        reservation.relay_data_endpoint.clone(),
        reservation.reservation_id.clone(),
        reservation.local_token.clone(),
        config.credential.clone(),
        config.signing_seed,
    ) {
        Ok(data) => data,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 data client creation failed");
            return;
        }
    };
    if let Err(error) = data.connect_reservation().await {
        tracing::warn!(error = %error, "Relay v2 data client connect failed");
        return;
    }
    let events = match data.take_events() {
        Ok(events) => events,
        Err(error) => {
            tracing::warn!(error = %error, "Relay v2 data events were already consumed");
            return;
        }
    };
    let peer_id = reservation.initiator_device_id.clone();
    let data = Arc::new(data);
    // 以对端为 key 记录活跃 reservation 数据连接：替换同一对端的旧连接（会话重建），
    // 但绝不因此断开其他对端的活跃连接（§25 每条 reservation 数据面相互独立）。
    state
        .relay_data
        .write()
        .await
        .insert(peer_id.clone(), data.clone());
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("relay-data-events", async move {
        handle_relay_data_events(state, data, events, peer_id).await;
    });
    tracing::info!(
        peer_id = %reservation.initiator_device_id,
        reservation_id = %reservation.reservation_id,
        "relay v2 data plane connected (responder)"
    );
}

/// 建立 reservation 数据面客户端（发起方）并返回事件接收器。
pub(crate) async fn connect_initiator_relay_data(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    reservation: network_relay::v2::RelayReserveResponse,
) -> Result<Arc<RelayDataClient>, ProtocolError> {
    let config = state.relay_config.read().await.clone().ok_or_else(|| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            "Relay is not configured",
            "relay_data_connect",
            None,
        )
    })?;
    let mut data = RelayDataClient::new(
        reservation.relay_data_endpoint,
        reservation.reservation_id,
        reservation.local_token,
        config.credential,
        config.signing_seed,
    )
    .map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    data.connect_reservation().await.map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    let events = data.take_events().map_err(|error| {
        protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            "relay_data_connect",
            None,
        )
    })?;
    let data = Arc::new(data);
    // 以对端为 key 记录活跃 reservation 数据连接：连接新对端绝不切断其他对端
    // 的活跃连接（回归 #2：旧单 slot .replace + request_disconnect 会切断）。
    state
        .relay_data
        .write()
        .await
        .insert(peer_id.to_string(), data.clone());
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let peer_id = peer_id.to_string();
    let data_for_loop = Arc::clone(&data);
    let _ = supervisor.spawn_runtime("relay-data-events", async move {
        handle_relay_data_events(state, data_for_loop, events, peer_id).await;
    });
    Ok(data)
}

/// 消费 reservation 数据面事件，按信封类型分派到业务处理。
async fn handle_relay_data_events(
    state: Arc<RuntimeState>,
    data: Arc<RelayDataClient>,
    mut events: mpsc::Receiver<DataEvent>,
    peer_id: String,
) {
    while let Some(event) = events.recv().await {
        match event {
            DataEvent::Payload {
                encrypted_payload, ..
            } => {
                if let Err(error) =
                    handle_relay_data_payload(&state, &data, &peer_id, &encrypted_payload).await
                {
                    tracing::debug!(
                        peer_id = %peer_id,
                        error = %error,
                        "rejected relay v2 data envelope"
                    );
                }
            }
            DataEvent::Ack { .. } => {
                // 流控回执：当前文件发送路径不使用显式 Ack 门控，静默忽略。
            }
            DataEvent::Close { reason, detail } => {
                tracing::debug!(peer_id = %peer_id, reason, detail, "relay v2 data closed");
                break;
            }
            DataEvent::Disconnected { reason } => {
                tracing::debug!(peer_id = %peer_id, reason, "relay v2 data disconnected");
                break;
            }
        }
    }
    relay_data_disconnected(state, data, peer_id).await;
}

/// 分派一条数据面信封。
async fn handle_relay_data_payload(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    peer_id: &str,
    envelope: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let Some((&kind, body)) = envelope.split_first() else {
        return Err(std::io::Error::other("relay data envelope is empty").into());
    };
    match kind {
        DATA_ENV_CRYPTO => {
            // body = [token 32][step+payload]
            if body.len() < 32 {
                return Err(std::io::Error::other("relay crypto envelope is truncated").into());
            }
            let token = std::str::from_utf8(&body[..32])?.to_string();
            handle_relay_crypto_handshake(state, data, &token, peer_id, &body[32..]).await
        }
        DATA_ENV_FILE_OFFER => receive_relay_offer(state, data, peer_id, body).await,
        DATA_ENV_FILE_ACCEPT => {
            let payload = std::str::from_utf8(body)?;
            let acceptance = serde_json::from_str::<RelayAcceptance>(payload)?;
            // 发送方按 transfer_id 等待 accept 应答。
            if let Some(sender) = state
                .relay_acceptances
                .write()
                .await
                .remove(&acceptance.transfer_id)
            {
                let _ = sender.send(Some(acceptance));
            }
            Ok(())
        }
        DATA_ENV_FILE_COMPLETE => {
            let session_id = std::str::from_utf8(body)?;
            complete_relay_incoming(state, data, session_id, Some(peer_id)).await
        }
        DATA_ENV_FILE_COMPLETE_ACK => {
            let transfer_id = std::str::from_utf8(body)?.to_string();
            if let Some(sender) = state.relay_completions.write().await.remove(&transfer_id) {
                let _ = sender.send(true);
            }
            Ok(())
        }
        DATA_ENV_FILE_CANCEL => {
            let transfer_id = std::str::from_utf8(body)?.to_string();
            if let Some(sender) = state.relay_acceptances.write().await.remove(&transfer_id) {
                let _ = sender.send(None);
            }
            if let Some(sender) = state.relay_completions.write().await.remove(&transfer_id) {
                let _ = sender.send(false);
            }
            cancel_relay_incoming(state, &transfer_id).await;
            Ok(())
        }
        DATA_ENV_FILE_CHUNK => {
            // body = [session_id 32][sequence u64 BE][ciphertext]
            if body.len() < 40 {
                return Err(std::io::Error::other("relay chunk envelope is truncated").into());
            }
            let session_id = std::str::from_utf8(&body[..32])?.to_string();
            let sequence = u64::from_be_bytes(body[32..40].try_into()?);
            receive_relay_chunk(state, data, &session_id, sequence, &body[40..]).await
        }
        DATA_ENV_CHANNEL => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_channel_message(state, data, peer_id, token, &payload).await
        }
        DATA_ENV_CHANNEL_ACK => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_delivery_ack(state, data, peer_id, token, &payload).await
        }
        DATA_ENV_STREAM => {
            let (token, payload) = decode_token_envelope(body)?;
            let payload = payload.to_vec();
            receive_relay_stream_frame(state, data, peer_id, token, &payload).await
        }
        other => {
            Err(std::io::Error::other(format!("unknown relay data envelope kind {other}")).into())
        }
    }
}

/// 数据面断开：移除该对端的 reservation 数据客户端并暂停 Relay 传输；会话侧由
/// route 丢失统一处理。只清理断开对端的条目，其他对端的活跃数据连接不受影响。
async fn relay_data_disconnected(
    state: Arc<RuntimeState>,
    data: Arc<RelayDataClient>,
    peer_id: String,
) {
    let mut entries = state.relay_data.write().await;
    if entries
        .get(&peer_id)
        .is_some_and(|current| Arc::ptr_eq(current, &data))
    {
        entries.remove(&peer_id);
    }
    drop(entries);
    // 只清理断开对端的 Relay 状态；其他对端的在途传输原样保留。
    cleanup_relay_state(&state, Some(&peer_id)).await;
    // §18/§35：transport 丢失即销毁 ConnectionSession（Relay route 由其数据客户端
    // 断开驱动）。显式 close 会 emit Disconnected。
    crate::peer::teardown_relay_route(&state, &peer_id, &data).await;
}

fn relay_crypto_key(peer_id: &str, session_token: &str) -> String {
    format!("{peer_id}/{session_token}")
}

/// 处理一条数据面 crypto 信封（应答方或等待中的发起方）。
async fn handle_relay_crypto_handshake(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    session_token: &str,
    peer_id: &str,
    frame_bytes: &[u8],
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
    let (step, payload) = crate::crypto_handshake::decode_relay_frame(frame_bytes)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    let key = relay_crypto_key(peer_id, session_token);
    match step {
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE
        | crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED
        | crate::crypto_handshake::RELAY_CRYPTO_ACCEPT => {
            let sender = state
                .relay_crypto_waiters
                .read()
                .await
                .get(&key)
                .cloned()
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE response has no active initiator state",
                    )
                })?;
            sender.send((step, payload.to_vec())).await.map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "Relay E2EE initiator is no longer waiting",
                )
            })?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_HELLO => {
            state.relay_crypto_confirmers.lock().await.remove(&key);
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
            // 用原始 frame 编码回传（data 侧负责加 token 前缀）。
            send_relay_crypto_raw(data, session_token, &response).await?;
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
            let binding_state = Arc::clone(state);
            let (authenticated_peer_id, confirmer, encrypted_seed) = responder
                .accept_final(
                    payload,
                    &state.trusted_peer_keys,
                    move |authenticated_peer_id, remote_session_binding| {
                        let binding_state = Arc::clone(&binding_state);
                        let authenticated_peer_id = authenticated_peer_id.to_string();
                        let remote_session_binding = remote_session_binding.to_string();
                        async move {
                            let admission = binding_state
                                .admit_authenticated_session(
                                    &authenticated_peer_id,
                                    None,
                                    &remote_session_binding,
                                )
                                .await
                                .map_err(|_| {
                                    crate::crypto_handshake::CryptoHandshakeError::Failed
                                })?;
                            Ok((admission.session_id.wire_key(), admission))
                        }
                    },
                )
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
            let mut confirmers = state.relay_crypto_confirmers.lock().await;
            if confirmers.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES
                && !confirmers.contains_key(&key)
            {
                return Err(std::io::Error::other("Relay E2EE confirmer queue is full").into());
            }
            confirmers.insert(key, confirmer);
            drop(confirmers);
            let root_seed = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
                &encrypted_seed,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            send_relay_crypto_raw(data, session_token, &root_seed).await?;
        }
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM => {
            let confirmer = state
                .relay_crypto_confirmers
                .lock()
                .await
                .remove(&key)
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay E2EE confirmation has no authenticated responder",
                    )
                })?;
            let (authenticated_peer_id, encrypted_accept, material, admission) =
                confirmer.accept_root_confirm(payload).map_err(|error| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, error.to_string())
                })?;
            if authenticated_peer_id != peer_id {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay E2EE confirmation identity does not match the routed peer",
                )
                .into());
            }
            let accept = crate::crypto_handshake::encode_relay_frame(
                crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
                &encrypted_accept,
            )
            .map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            })?;
            send_relay_crypto_raw(data, session_token, &accept).await?;
            if admission.session_id.wire_key() != material.local_session_binding {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "Relay Session binding became stale",
                )
                .into());
            }
            state
                .sessions
                .finalize_authenticated_session(
                    peer_id,
                    admission.session_id,
                    &material.remote_session_binding,
                )
                .await
                .map_err(|_| {
                    std::io::Error::other("Relay Session was replaced during handshake")
                })?;
            crate::peer::install_admitted_crypto(state, peer_id, &admission, &material).await?;
            let session_id = admission.session_id;
            if !state
                .sessions
                .mark_relay_route_connected(
                    peer_id,
                    session_id,
                    RouteType::Relay,
                    Some(Arc::clone(data)),
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
            crate::channel::recover_session(Arc::clone(state), peer_id.to_string()).await;
            // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
            crate::transfer::resume_transfers_for_peer(Arc::clone(state), peer_id.to_string())
                .await;
            // transport-network v2：Relay → Direct 后台升级已删除（§35）；路由建立后不变。
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

/// 发送一条已编码的 crypto 帧（data 侧加 token 前缀）。
async fn send_relay_crypto_raw(
    data: &RelayDataClient,
    token: &str,
    encoded_frame: &[u8],
) -> Result<(), RelayError> {
    if token.len() != 32
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(RelayError::InvalidConfiguration(
            "relay crypto token must be 32 lowercase hexadecimal characters".into(),
        ));
    }
    let mut body = Vec::with_capacity(32 + encoded_frame.len());
    body.extend_from_slice(token.as_bytes());
    body.extend_from_slice(encoded_frame);
    send_data_envelope(data, DATA_ENV_CRYPTO, &body).await
}

/// Relay 只转发不透明 DataMessage；业务解码仍在 native core。
async fn receive_relay_channel_message(
    state: &Arc<RuntimeState>,
    _data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    // ReliableStream frames ride the same Relay data channel (design §17 Relay
    // Stream): transparent forwarding, the Relay never parses business bytes.
    if let Ok(frame) = decode_generic_frame(payload) {
        match frame.kind {
            GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamClose => {
                if !state.peers.read().await.contains_key(peer_id) {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "Relay channel sender is not a registered peer",
                    )
                    .into());
                }
                let (opener_peer_id, stream_id) =
                    crate::stream::decode_stream_frame_identity(frame.kind, &frame.payload)
                        .map_err(|error| {
                            std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
                        })?;
                let expected_token = crate::stream::stream_relay_token(&opener_peer_id, stream_id);
                if session_token != expected_token {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Relay stream token does not match stream opener and id",
                    )
                    .into());
                }
                crate::stream::handle_inbound_stream_frame(
                    state,
                    peer_id,
                    frame.kind,
                    &frame.payload,
                )
                .await?;
                return Ok(());
            }
            _ => {}
        }
    }
    let message = DataMessage::decode(payload)?;
    if hex::encode(&message.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay channel token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_data_message(state, peer_id, payload).await
}

/// 专门处理 Relay byte-stream 帧（`DATA_ENV_STREAM`）。
async fn receive_relay_stream_frame(
    state: &Arc<RuntimeState>,
    _data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let frame = decode_generic_frame(payload)?;
    if !matches!(
        frame.kind,
        GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamClose
    ) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay stream envelope must carry a stream frame",
        )
        .into());
    }
    let (opener_peer_id, stream_id) =
        crate::stream::decode_stream_frame_identity(frame.kind, &frame.payload).map_err(
            |error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()),
        )?;
    let expected_token = crate::stream::stream_relay_token(&opener_peer_id, stream_id);
    if session_token != expected_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay stream token does not match stream opener and id",
        )
        .into());
    }
    crate::stream::handle_inbound_stream_frame(state, peer_id, frame.kind, &frame.payload)
        .await
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    Ok(())
}

async fn receive_relay_delivery_ack(
    state: &Arc<RuntimeState>,
    _data: &Arc<RelayDataClient>,
    peer_id: &str,
    session_token: &str,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(peer_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay channel sender is not a registered peer",
        )
        .into());
    }
    let ack = DeliveryAck::decode(payload)?;
    if hex::encode(&ack.message_id) != session_token {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay ACK token does not match MessageId",
        )
        .into());
    }
    crate::channel::handle_delivery_ack(state, peer_id, payload).await
}

/// 清理一次 Relay 数据面断开，但保留可由新连接继续使用的业务状态。
///
/// `TransferManager` 和稳定 `.part` 属于 TransferSession，不属于 Relay 数据面；这里
/// 只丢弃等待中的 oneshot 和打开的文件句柄，绝不取消传输或删除 checkpoint。
/// `peer` 为 `Some` 时只清理该对端的条目（单条 reservation 断开），`None` 表示全部
/// （disconnect_relay_data 断开所有 reservation）。
async fn cleanup_relay_state(state: &RuntimeState, peer: Option<&str>) {
    // relay_active_incoming：按 offer.sender_id 只暂停断开对端的接收传输，其余对端
    // 的活跃接收保持原样。
    let active_ids = {
        let active = state.relay_active_incoming.lock().await;
        match peer {
            Some(peer) => active
                .iter()
                .filter(|(_, incoming)| incoming.offer.sender_id == peer)
                .map(|(transfer_id, _)| transfer_id.clone())
                .collect::<Vec<_>>(),
            None => active.keys().cloned().collect::<Vec<_>>(),
        }
    };
    for transfer_id in active_ids {
        let incoming = state
            .relay_active_incoming
            .lock()
            .await
            .remove(&transfer_id);
        if let Some(incoming) = incoming {
            drop(incoming.file);
            if state.transfers.pause_for_network(&transfer_id).await {
                tracing::debug!(
                    transfer_id = %transfer_id,
                    "Relay incoming transfer paused; preserving checkpoint"
                );
            }
        }
    }

    // acceptances/completions 以 transfer_id 为键；按 TransferManager 的 peer 归属
    // 过滤，绝不清掉其他对端的等待者（None = 全部清空）。
    let mut waiter_ids = {
        let mut ids = Vec::new();
        ids.extend(state.relay_acceptances.read().await.keys().cloned());
        ids.extend(state.relay_completions.read().await.keys().cloned());
        ids
    };
    waiter_ids.sort_unstable();
    waiter_ids.dedup();
    if let Some(peer) = peer {
        // 逐条查询 TransferManager 的 peer 归属（snapshot 是 async，不能放在
        // 同步 retain 闭包里）。
        let mut scoped = Vec::new();
        for transfer_id in &waiter_ids {
            if state
                .transfers
                .snapshot(transfer_id)
                .await
                .is_some_and(|snapshot| snapshot.peer_id == peer)
            {
                scoped.push(transfer_id.clone());
            }
        }
        waiter_ids = scoped;
    }
    for transfer_id in &waiter_ids {
        state.relay_acceptances.write().await.remove(transfer_id);
        state.relay_completions.write().await.remove(transfer_id);
    }

    // crypto waiters/responders/confirmers 的键是 "{peer_id}/{token}"：按对端前缀清理。
    let crypto_prefix = peer.map(|peer| format!("{peer}/"));
    {
        let mut waiters = state.relay_crypto_waiters.write().await;
        if let Some(prefix) = &crypto_prefix {
            waiters.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            waiters.clear();
        }
    }
    {
        let mut responders = state.relay_crypto_responders.lock().await;
        if let Some(prefix) = &crypto_prefix {
            responders.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            responders.clear();
        }
    }
    {
        let mut confirmers = state.relay_crypto_confirmers.lock().await;
        if let Some(prefix) = &crypto_prefix {
            confirmers.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            confirmers.clear();
        }
    }
}

/// 在通知 UI 前解密并校验传入 Relay 申请。
async fn receive_relay_offer(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    sender_id: &str,
    body: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !state.peers.read().await.contains_key(sender_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay sender is not a registered peer",
        )
        .into());
    }
    // body = [session_id 32][base64(encrypted offer)]：session_id 用于派生 offer 的
    // 加密 nonce（与 v1 同构），必须在明文中。
    if body.len() < 32 {
        return Err(std::io::Error::other("Relay offer envelope is truncated").into());
    }
    let session_id = std::str::from_utf8(&body[..32])?.to_string();
    if session_id.len() != 32
        || !session_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay offer session ID is invalid",
        )
        .into());
    }
    let encoded_payload = std::str::from_utf8(&body[32..])?;
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
        || offer_sender != Some(sender_id)
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
    let pending = PendingRelayIncoming {
        transfer_id: transfer_id.clone(),
        session_id: session_id.clone(),
        sender_id: sender_id.to_string(),
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
        .claim_incoming_resume(&manifest, sender_id)
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
            .register_incoming(manifest.clone(), sender_id.to_string())
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
            emit_incoming_offer(&state.event_tx, sender_id, &manifest, RouteType::Relay);
        }
    }
    if resume_offset.is_some() || completed_path.is_some() {
        accept_pending_relay_incoming(state, data, &transfer_id).await?;
        return Ok(());
    }
    let expiry_state = Arc::clone(state);
    let expiry_transfer_id = transfer_id;
    let _ = state
        .task_supervisor
        .spawn_runtime("relay-approval-timeout", async move {
            tokio::time::sleep(INCOMING_APPROVAL_TIMEOUT).await;
            let (expired, sender_id) = {
                let pending = expiry_state.relay_pending_incoming.read().await;
                let entry = pending.get(&expiry_transfer_id);
                (
                    entry.is_some_and(|pending| pending.session_id == session_id),
                    entry.map(|pending| pending.sender_id.clone()),
                )
            };
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
                // 审批超时是终态失败：移除 TransferManager 条目，释放 transfer_id。
                // 否则条目停留在 Failed，register_incoming/claim_incoming_resume 只接受
                // Vacant 或 Paused，后续同一 transfer_id 的再 Offer 会被
                // "TransferId is already active" 永久拒绝。
                expiry_state
                    .transfers
                    .remove_transfer(&expiry_transfer_id)
                    .await;
                // 取消只发到承载该 transfer 的对端 reservation 连接。
                if let Some(sender_id) = sender_id {
                    if let Some(data) = expiry_state
                        .relay_data
                        .read()
                        .await
                        .get(&sender_id)
                        .cloned()
                    {
                        let _ = send_file_cancel(&data, &expiry_transfer_id).await;
                    }
                }
            }
        });
    Ok(())
}

/// 发送文件控制取消信封（body = transfer_id）。
async fn send_file_cancel(data: &RelayDataClient, transfer_id: &str) -> Result<(), RelayError> {
    send_data_envelope(data, DATA_ENV_FILE_CANCEL, transfer_id.as_bytes()).await
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
    let data = state
        .relay_data
        .read()
        .await
        .get(&pending.sender_id)
        .cloned()
        .ok_or_else(|| {
            protocol_error_with_context(
                NetworkErrorCode::RelayError,
                "Relay data plane is unavailable",
                "respond_incoming",
                None,
            )
        })?;
    if !accepted {
        state.transfers.cancel_transfer(transfer_id).await;
        state.transfers.remove_transfer(transfer_id).await;
        send_file_cancel(&data, transfer_id).await.map_err(|_| {
            protocol_error(NetworkErrorCode::RelayError, "Relay cancellation failed")
        })?;
        return Ok(());
    }
    state
        .relay_pending_incoming
        .write()
        .await
        .insert(transfer_id.to_string(), pending);
    if let Err(error) = accept_pending_relay_incoming(state, &data, transfer_id).await {
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
    data: &Arc<RelayDataClient>,
    transfer_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pending = state
        .relay_pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| std::io::Error::other("Relay transfer is not pending"))?;
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
        .map(|snapshot| snapshot.confirmed_offset);
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
    if let Err(error) = send_data_envelope(data, DATA_ENV_FILE_ACCEPT, acceptance.as_bytes()).await
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
    data: &Arc<RelayDataClient>,
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
    let _ = data;
    Ok(())
}

/// 校验 Relay 完成状态，提交文件并发送 complete_ack。
async fn complete_relay_incoming(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
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
    if active.already_completed {
        state.transfers.mark_verifying(&transfer_id).await;
        state.transfers.mark_completed(&transfer_id).await;
        state.transfers.remove_transfer(&transfer_id).await;
        send_data_envelope(data, DATA_ENV_FILE_COMPLETE_ACK, transfer_id.as_bytes()).await?;
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
    let completed = state.transfers.mark_completed(&transfer_id).await;
    state.transfers.remove_transfer(&transfer_id).await;
    if completed {
        emit_transfer_completed(
            &state.event_tx,
            &transfer_id,
            &active.final_path.to_string_lossy(),
        );
    }
    send_data_envelope(data, DATA_ENV_FILE_COMPLETE_ACK, transfer_id.as_bytes()).await?;
    Ok(())
}

/// 取消或失败后移除待处理和临时 Relay 状态。
pub(crate) async fn cancel_relay_incoming(state: &RuntimeState, session_or_transfer_id: &str) {
    let pending = state
        .relay_pending_incoming
        .write()
        .await
        .remove(session_or_transfer_id);
    let active = {
        let mut active_transfers = state.relay_active_incoming.lock().await;
        if let Some(active) = active_transfers.remove(session_or_transfer_id) {
            Some((session_or_transfer_id.to_string(), active))
        } else {
            let transfer_id = active_transfers
                .iter()
                .find(|(_, active)| active.offer.session_id == session_or_transfer_id)
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
        .unwrap_or_else(|| session_or_transfer_id.to_string());
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
    // 取消只发到承载该 transfer 的对端 reservation 连接（按 transfer 所属 peer 定位）。
    if let Some(peer_id) = state
        .transfers
        .snapshot(transfer_id)
        .await
        .map(|snapshot| snapshot.peer_id)
    {
        if let Some(data) = state.relay_data.read().await.get(&peer_id).cloned() {
            let _ = send_file_cancel(&data, transfer_id).await;
        }
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
    let mut buffer = vec![0u8; RELAY_FILE_CHUNK_BYTES as usize];
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

/// 发送加密 Relay 申请、分块和完成确认（reservation 数据面）。
pub(crate) async fn send_file_over_relay(
    peer: PeerConfig,
    transfer: ResumableTransfer,
    state: Arc<RuntimeState>,
) {
    let transfer_id = transfer.transfer_id.clone();
    let peer_id = transfer.peer_id.clone();
    let path = transfer.source_path.clone();
    let result = async {
        let data = state
            .sessions
            .current_relay_data(&peer_id)
            .await
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
        // offer 用对端 E2E 公钥加密（与 v1 同构）；信封 = [session_id][base64(密文)]。
        let encrypted_offer =
            crypto::encrypt_application_offer(&offer, peer.e2e_public_key, &session_bytes)?;
        let encoded_offer = URL_SAFE_NO_PAD.encode(encrypted_offer);
        let mut offer_envelope = Vec::with_capacity(32 + encoded_offer.len());
        offer_envelope.extend_from_slice(session_id.as_bytes());
        offer_envelope.extend_from_slice(encoded_offer.as_bytes());
        let (acceptance_tx, acceptance_rx) = oneshot::channel();
        state
            .relay_acceptances
            .write()
            .await
            .insert(transfer_id.clone(), acceptance_tx);
        send_data_envelope(&data, DATA_ENV_FILE_OFFER, &offer_envelope).await?;
        let acceptance_result = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx).await;
        state
            .relay_acceptances
            .write()
            .await
            .remove(&transfer_id);
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
        // 缓冲区按明文分块大小分配：整块加密后 + 信封开销仍落在数据面载荷上限内。
        let mut buffer = vec![0u8; RELAY_FILE_CHUNK_BYTES as usize];
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
            // body = [session_id 32][sequence u64 BE][ciphertext]
            let mut chunk = Vec::with_capacity(40 + ciphertext.len());
            chunk.extend_from_slice(session_id.as_bytes());
            chunk.extend_from_slice(&sequence.to_be_bytes());
            chunk.extend_from_slice(&ciphertext);
            send_data_envelope(&data, DATA_ENV_FILE_CHUNK, &chunk).await?;
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
            .insert(transfer_id.clone(), completion_tx);
        send_data_envelope(&data, DATA_ENV_FILE_COMPLETE, transfer_id.as_bytes()).await?;
        let completed = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, completion_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay_completions.write().await.remove(&transfer_id);
        if !completed {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Relay completion acknowledgement timed out",
            )
                .into());
        }
        state.transfers.mark_verifying(&transfer_id).await;
        if state.transfers.mark_completed(&transfer_id).await {
            emit_transfer_completed(&state.event_tx, &transfer_id, "");
        }
        Ok(())
    }
    .await;
    if result.is_err()
        && result
            .as_ref()
            .err()
            .is_some_and(|error| !is_transient_relay_error(error.as_ref()))
    {
        if let Some(data) = state.sessions.current_relay_data(&peer_id).await {
            let _ = send_file_cancel(&data, &transfer_id).await;
        }
    }
    if result.is_err() && state.transfers.snapshot(&transfer_id).await.is_none() {
        return;
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

/// 将 Relay connect 失败映射为类型化协议错误。凭据过期/身份冲突是终态错误，
/// 其余仍走通用的 Relay 传输错误。
fn relay_connect_protocol_error(error: &RelayError, operation: &str) -> ProtocolError {
    match error {
        RelayError::CredentialExpired(_) => protocol_error_with_retry(
            NetworkErrorCode::CredentialExpired,
            error.to_string(),
            operation,
            None,
            RetryDisposition::RefreshCredentialThenRetry,
            0,
        ),
        RelayError::IdentityConflict(_) => protocol_error_with_retry(
            NetworkErrorCode::IdentityConflict,
            error.to_string(),
            operation,
            None,
            RetryDisposition::NoRetry,
            0,
        ),
        _ => protocol_error_with_context(
            NetworkErrorCode::RelayError,
            error.to_string(),
            operation,
            None,
        ),
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
    fn relay_connect_error_maps_credential_expired_and_identity_conflict_as_terminal() {
        let expired = relay_connect_protocol_error(
            &RelayError::CredentialExpired("expired".into()),
            "configure_relay",
        );
        assert_eq!(expired.code, NetworkErrorCode::CredentialExpired as i32);
        assert_eq!(
            expired.retry_disposition,
            RetryDisposition::RefreshCredentialThenRetry as i32
        );

        let conflict = relay_connect_protocol_error(
            &RelayError::IdentityConflict("conflict".into()),
            "configure_relay",
        );
        assert_eq!(conflict.code, NetworkErrorCode::IdentityConflict as i32);
        assert_eq!(conflict.retry_disposition, RetryDisposition::NoRetry as i32);

        let transient =
            relay_connect_protocol_error(&RelayError::Socket("boom".into()), "configure_relay");
        assert_eq!(transient.code, NetworkErrorCode::RelayError as i32);
        assert_eq!(
            transient.retry_disposition,
            RetryDisposition::Unspecified as i32
        );
    }

    #[test]
    fn relay_reconnect_is_suppressed_when_credential_is_stale() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        state
            .relay_credential_stale
            .store(true, std::sync::atomic::Ordering::Release);
        schedule_relay_reconnect(Arc::clone(&state));
        assert!(!state
            .relay_reconnect_active
            .load(std::sync::atomic::Ordering::Acquire));
        assert!(state.relay_reconnect_task.lock().unwrap().is_none());
    }

    /// 回归 #1：意外控制面断开必须清空 relay_control sink 并调度重连，否则重连
    /// 循环第一处守卫（relay_control.is_some()）会立即 break——死 client 仍占位，
    /// setup_v2_control_plane 永远不会被再次调用，Discovery/Resolve/Reservation/
    /// Realtime 信令持续失效，直到 Dart 重新下发 ConfigureRelayCommand。
    #[tokio::test]
    async fn control_disconnect_clears_slot_and_reconnect_loop_reruns_setup() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        state.identity.write().await.replace(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "device-a".into(),
                [1u8; 32],
                [2u8; 32],
            ),
        ));
        // 快速失败的 loopback 端点：重连循环会立刻尝试 setup_v2_control_plane，
        // 而不是卡在 relay_control 守卫上。URL 必须是无路径的 origin。
        *state.relay_config.write().await = Some(RelayReconnectConfig {
            relay_url: "ws://127.0.0.1:9".into(),
            credential: "credential".into(),
            signing_seed: [0u8; 32],
        });
        let dead_control = Arc::new(
            RelayControlClient::new(
                "ws://127.0.0.1:9".into(),
                "device-a".into(),
                "credential".into(),
                [0u8; 32],
            )
            .expect("control client"),
        );
        *state.relay_control.write().await = Some(dead_control.clone());

        let (events_tx, events_rx) = mpsc::channel(16);
        let consume_state = Arc::clone(&state);
        let handler = tokio::spawn(async move {
            consume_control_events(consume_state, dead_control, events_rx).await;
        });
        events_tx
            .send(ControlEvent::Disconnected {
                reason: "test disconnect".into(),
            })
            .await
            .expect("send disconnected");
        drop(events_tx);
        handler.await.expect("control consumer should exit");

        // 意外断开必须清空控制面 sink，否则重连循环会在死 client 处立即 break。
        assert!(
            state.relay_control.read().await.is_none(),
            "unexpected disconnect must clear the control-plane slot"
        );
        assert!(
            state
                .relay_reconnect_active
                .load(std::sync::atomic::Ordering::Acquire),
            "reconnect must be scheduled after an unexpected disconnect"
        );
        // 等待超过首个退避周期：重连循环必须仍在重试（setup 反复执行），而不是在
        // relay_control 守卫处立即退出。
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        assert!(
            state
                .relay_reconnect_active
                .load(std::sync::atomic::Ordering::Acquire),
            "reconnect loop must keep retrying instead of breaking on the stale control slot"
        );
    }

    /// 回归 #2：关闭一条 reservation 数据连接只移除该对端的条目，另一对端的活跃
    /// 数据连接必须原样保留（旧单 slot .take() 会连带清掉其他连接）。
    #[tokio::test]
    async fn relay_data_disconnect_removes_only_the_matching_peer_entry() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        let data_b = Arc::new(
            RelayDataClient::new(
                "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                vec![0u8; 32],
                "credential".into(),
                [0u8; 32],
            )
            .expect("peer-b data client"),
        );
        let data_c = Arc::new(
            RelayDataClient::new(
                "ws://127.0.0.1:9/v2/relay/7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                "7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                vec![0u8; 32],
                "credential".into(),
                [0u8; 32],
            )
            .expect("peer-c data client"),
        );
        state
            .relay_data
            .write()
            .await
            .insert("peer-b".into(), data_b.clone());
        state
            .relay_data
            .write()
            .await
            .insert("peer-c".into(), data_c.clone());
        assert_eq!(state.relay_data.read().await.len(), 2);

        relay_data_disconnected(Arc::clone(&state), data_b, "peer-b".into()).await;

        let entries = state.relay_data.read().await;
        assert!(
            entries
                .get("peer-c")
                .is_some_and(|current| Arc::ptr_eq(current, &data_c)),
            "peer-c data connection must survive peer-b disconnecting"
        );
        assert!(
            entries.get("peer-b").is_none(),
            "only the disconnected peer's entry must be removed"
        );
    }

    /// 回归 #5a：控制面 socket 未能建立时，configure_relay_for_state 必须发布类型化
    /// Failed（而不是伪造 Connected），并返回错误。
    #[tokio::test]
    async fn configure_relay_emits_failed_when_control_connect_fails() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        state.identity.write().await.replace(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "device-a".into(),
                [1u8; 32],
                [2u8; 32],
            ),
        ));
        let command = ConfigureRelayCommand {
            // 无路径 origin：控制面 socket 建立失败（连接被拒绝）。
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0u8; 32],
        };
        let result = configure_relay_for_state(Arc::clone(&state), command).await;
        assert!(
            result.is_err(),
            "failed control connect must fail configure"
        );
        assert!(
            !state
                .relay_credential_stale
                .load(std::sync::atomic::Ordering::Acquire),
            "transient socket failure is not a credential error"
        );

        let mut saw_failed = false;
        while let Ok(event) = event_rx.try_recv() {
            if let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
                event.payload
            {
                assert_ne!(
                    change.state,
                    network_protocol::RelayConnectionState::Connected as i32,
                    "control connect failure must not emit Connected"
                );
                if change.state == network_protocol::RelayConnectionState::Failed as i32 {
                    saw_failed = true;
                }
            }
        }
        assert!(saw_failed, "control connect failure must emit Failed");
    }

    /// 回归 #5b：凭据过期（服务端以 HTTP 401 + code 12 拒绝）时，configure 必须
    /// 标记 relay_credential_stale 并停止重连（现有 stale 守卫随后生效），且发布携带
    /// CredentialExpired 的 Failed，Dart 据此下发新的 ConfigureRelayCommand。
    #[tokio::test]
    async fn configure_relay_with_expired_credential_marks_stale_and_emits_failed() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind fake control listener");
        let address = listener.local_addr().expect("fake control address");
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept control connect");
            // 读完请求头，随后以设备面 code 12（凭据过期）拒绝。
            let mut request = vec![0u8; 4096];
            let mut used = 0usize;
            loop {
                let read = stream
                    .read(&mut request[used..])
                    .await
                    .expect("read control request");
                if read == 0 {
                    break;
                }
                used += read;
                if request[..used]
                    .windows(4)
                    .any(|window| window == b"\r\n\r\n")
                {
                    break;
                }
            }
            // 响应头与 body 必须一次性写入：tungstenite 客户端只在同一次 read 中
            // 捕获 header 之后的 tail 作为错误响应 body，分两次写会丢失 {"code":12}。
            let body = "{\"code\":12}";
            let response = format!(
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .await
                .expect("write rejection response");
            stream.flush().await.expect("flush");
        });

        let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
        state.identity.write().await.replace(Arc::new(
            network_identity::DeviceIdentity::from_private_keys(
                "device-a".into(),
                [1u8; 32],
                [2u8; 32],
            ),
        ));
        let command = ConfigureRelayCommand {
            relay_url: format!("ws://{address}"),
            relay_credential: "expired-credential".into(),
            relay_signing_seed: vec![0u8; 32],
        };
        let result = configure_relay_for_state(Arc::clone(&state), command).await;
        let error = result.expect_err("expired credential must fail configure");
        assert_eq!(error.code, NetworkErrorCode::CredentialExpired as i32);
        assert!(
            state
                .relay_credential_stale
                .load(std::sync::atomic::Ordering::Acquire),
            "expired credential must mark the credential stale"
        );
        assert!(
            !state
                .relay_reconnect_active
                .load(std::sync::atomic::Ordering::Acquire),
            "expired credential must stop scheduling reconnects"
        );
        assert!(
            state.relay_reconnect_task.lock().unwrap().is_none(),
            "expired credential must not leave a reconnect task behind"
        );

        let mut saw_failed = false;
        while let Ok(event) = event_rx.try_recv() {
            if let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
                event.payload
            {
                if change.state == network_protocol::RelayConnectionState::Failed as i32 {
                    saw_failed = true;
                    assert_eq!(
                        change.error.as_ref().map(|error| error.code),
                        Some(NetworkErrorCode::CredentialExpired as i32),
                        "Failed must carry the CredentialExpired error so Dart can re-issue credentials"
                    );
                }
            }
        }
        assert!(saw_failed, "expired credential must emit Failed");
        server.await.expect("fake control server should finish");
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

    /// 构造一个合法的 Relay 文件 Manifest（满足 validate / is_safe_file_name）。
    fn relay_test_manifest(transfer_id: &str) -> FileManifest {
        FileManifest {
            transfer_id: transfer_id.into(),
            file_name: "payload.bin".into(),
            file_size: RELAY_FILE_CHUNK_BYTES * 2,
            modified_at: 1,
            content_hash: "a".repeat(64),
            protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
        }
    }

    fn relay_test_active(pending: PendingRelayIncoming) -> ActiveRelayIncoming {
        ActiveRelayIncoming {
            offer: pending,
            file: None,
            temporary_path: PathBuf::from("/tmp/relay-test.part"),
            final_path: PathBuf::from("/tmp/relay-test.bin"),
            next_sequence: 0,
            received_bytes: 0,
            hasher: Sha256::new(),
            already_completed: false,
        }
    }

    /// 构造一条可被 receive_relay_offer 接受的 Relay 文件 Offer 信封：
    /// body = [session_id 32][URL_SAFE_NO_PAD base64(encrypted offer)]。
    fn build_relay_offer_envelope(
        sender: &network_identity::DeviceIdentity,
        receiver: &network_identity::DeviceIdentity,
        session_id: &str,
        manifest: &FileManifest,
        crypto_session_id: &str,
    ) -> Vec<u8> {
        use base64::Engine as _;
        let offer = serde_json::to_vec(&serde_json::json!({
            "v": 1,
            "crypto_suite": APPLICATION_CRYPTO_SUITE,
            "session_id": session_id,
            "crypto_session_id": crypto_session_id,
            "transfer_id": manifest.transfer_id,
            "manifest_hash": relay_manifest_hash(manifest),
            "sender_id": sender.device_id,
            "receiver_id": receiver.device_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "modified_at": manifest.modified_at,
            "content_hash": manifest.content_hash,
        }))
        .expect("serialize Relay offer");
        let session_bytes: [u8; 16] = hex::decode(session_id)
            .expect("hex session")
            .try_into()
            .expect("session must decode to 16 bytes");
        let encrypted = crypto::encrypt_application_offer(
            &offer,
            *receiver.public_e2e_key().as_bytes(),
            &session_bytes,
        )
        .expect("encrypt Relay offer");
        let encoded = URL_SAFE_NO_PAD.encode(encrypted);
        let mut envelope = Vec::with_capacity(32 + encoded.len());
        envelope.extend_from_slice(session_id.as_bytes());
        envelope.extend_from_slice(encoded.as_bytes());
        envelope
    }

    /// 回归 #2：满块 Relay 分块（RELAY_FILE_CHUNK_BYTES 明文）加密并包上
    /// DATA_ENV_FILE_CHUNK 信封后必须仍落在数据面载荷上限（512 KiB）之内；否则
    /// RelayDataClient::send 会以 InvalidConfiguration 拒绝，导致整份文件发送失败。
    #[tokio::test]
    async fn relay_file_chunk_full_size_fits_data_plane_bound() {
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
        let plaintext = vec![0xABu8; RELAY_FILE_CHUNK_BYTES as usize];
        let ciphertext = sender_context
            .encrypt(&aad, &plaintext)
            .expect("encrypt full Relay chunk");
        // 数据面单帧载荷上限（network-relay v2 data_client MAX_DATA_PAYLOAD_BYTES）。
        const DATA_PLANE_MAX_PAYLOAD_BYTES: usize = 512 * 1024;
        // 明文分块 + 信封固定开销必须不超上限（旧的 512 KiB 明文会超限被 send 拒绝）。
        assert!(
            RELAY_FILE_CHUNK_BYTES as usize + RELAY_FILE_CHUNK_ENVELOPE_OVERHEAD_BYTES
                <= DATA_PLANE_MAX_PAYLOAD_BYTES,
            "full-size Relay chunk exceeds the data-plane payload bound"
        );
        // body = [session_id 32][sequence u64 BE][ciphertext]，信封再加 kind 标签(1)。
        let mut body = Vec::with_capacity(40 + ciphertext.len());
        body.extend_from_slice(session_id.as_bytes());
        body.extend_from_slice(&0u64.to_be_bytes());
        body.extend_from_slice(&ciphertext);
        let envelope_len = 1 + body.len();
        assert!(
            envelope_len <= DATA_PLANE_MAX_PAYLOAD_BYTES,
            "full-size Relay chunk envelope ({envelope_len} B) exceeds the 512 KiB data-plane bound"
        );

        let data = Arc::new(
            RelayDataClient::new(
                "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                vec![0u8; 32],
                "credential".into(),
                [0u8; 32],
            )
            .expect("relay data client"),
        );
        // 满块信封必须通过尺寸校验：未连接客户端在出站阶段才报 NotConnected；若尺寸
        // 超限则会在校验处直接报 InvalidConfiguration。
        assert!(matches!(
            send_data_envelope(&data, DATA_ENV_FILE_CHUNK, &body).await,
            Err(RelayError::NotConnected)
        ));
    }

    /// 回归 #6：单条 reservation 数据面断开（relay_data_disconnected →
    /// cleanup_relay_state Some(peer)）只清理该对端的 Relay 状态；另一对端的在途
    /// 接收/发送状态（active incoming、acceptance/completion waiter、crypto 握手
    /// 队列）原样保留，而不是像旧的全量清理那样把其他对端一并清空。
    #[tokio::test]
    async fn relay_disconnect_cleanup_is_scoped_to_the_disconnecting_peer() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));

        // peer-b 与 peer-c 各自有在途接收传输 + 等待中的 accept/completion/crypto waiter。
        let manifest_b = relay_test_manifest("relay-transfer-b");
        let manifest_c = relay_test_manifest("relay-transfer-c");
        assert!(
            state
                .transfers
                .register_incoming(manifest_b.clone(), "peer-b".into())
                .await
        );
        assert!(
            state
                .transfers
                .register_incoming(manifest_c.clone(), "peer-c".into())
                .await
        );
        state.relay_active_incoming.lock().await.insert(
            "relay-transfer-b".into(),
            relay_test_active(PendingRelayIncoming {
                transfer_id: "relay-transfer-b".into(),
                session_id: "000000000000000000000000000000bb".into(),
                sender_id: "peer-b".into(),
                manifest: manifest_b,
                manifest_hash: "a".repeat(64),
                crypto_session_id: "00000000000000bb".into(),
            }),
        );
        state.relay_active_incoming.lock().await.insert(
            "relay-transfer-c".into(),
            relay_test_active(PendingRelayIncoming {
                transfer_id: "relay-transfer-c".into(),
                session_id: "000000000000000000000000000000cc".into(),
                sender_id: "peer-c".into(),
                manifest: manifest_c,
                manifest_hash: "a".repeat(64),
                crypto_session_id: "00000000000000cc".into(),
            }),
        );
        state
            .relay_acceptances
            .write()
            .await
            .insert("relay-transfer-b".into(), oneshot::channel().0);
        state
            .relay_acceptances
            .write()
            .await
            .insert("relay-transfer-c".into(), oneshot::channel().0);
        state
            .relay_completions
            .write()
            .await
            .insert("relay-transfer-b".into(), oneshot::channel().0);
        state
            .relay_completions
            .write()
            .await
            .insert("relay-transfer-c".into(), oneshot::channel().0);
        let (wait_b, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
        let (wait_c, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
        state
            .relay_crypto_waiters
            .write()
            .await
            .insert(relay_crypto_key("peer-b", "token-b"), wait_b);
        state
            .relay_crypto_waiters
            .write()
            .await
            .insert(relay_crypto_key("peer-c", "token-c"), wait_c);

        // peer-b 断开：只清理 peer-b 的条目，peer-c 的全部保留。
        cleanup_relay_state(&state, Some("peer-b")).await;

        assert!(
            state
                .relay_active_incoming
                .lock()
                .await
                .contains_key("relay-transfer-c"),
            "peer-c active incoming must survive peer-b disconnecting"
        );
        assert!(!state
            .relay_active_incoming
            .lock()
            .await
            .contains_key("relay-transfer-b"));
        assert!(state
            .relay_acceptances
            .read()
            .await
            .contains_key("relay-transfer-c"));
        assert!(!state
            .relay_acceptances
            .read()
            .await
            .contains_key("relay-transfer-b"));
        assert!(state
            .relay_completions
            .read()
            .await
            .contains_key("relay-transfer-c"));
        assert!(!state
            .relay_completions
            .read()
            .await
            .contains_key("relay-transfer-b"));
        assert!(
            state
                .relay_crypto_waiters
                .read()
                .await
                .contains_key(&relay_crypto_key("peer-c", "token-c")),
            "peer-c crypto waiter must survive peer-b disconnecting"
        );
        assert!(!state
            .relay_crypto_waiters
            .read()
            .await
            .contains_key(&relay_crypto_key("peer-b", "token-b")));
        // peer-c 的接收传输未被暂停；peer-b 的被暂停（保留 checkpoint）。
        assert_eq!(
            state
                .transfers
                .snapshot("relay-transfer-c")
                .await
                .unwrap()
                .state,
            network_transfer::TransferState::WaitingApproval
        );
        assert_eq!(
            state
                .transfers
                .snapshot("relay-transfer-b")
                .await
                .unwrap()
                .state,
            network_transfer::TransferState::Paused
        );

        // 全部断开（disconnect_relay_data 路径）仍清理所有对端的条目。
        cleanup_relay_state(&state, None).await;
        assert!(state.relay_active_incoming.lock().await.is_empty());
        assert!(state.relay_acceptances.read().await.is_empty());
        assert!(state.relay_completions.read().await.is_empty());
        assert!(state.relay_crypto_waiters.read().await.is_empty());
    }

    /// 回归 #12：未获批的 Relay 传入 Offer 在审批超时后必须释放 transfer_id；随后
    /// 同一 transfer_id 的再 Offer 必须能被 register_incoming 接受（不得报
    /// "TransferId is already active"）。
    #[tokio::test(start_paused = true)]
    async fn relay_approval_timeout_releases_transfer_id_for_reoffer() {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = Arc::new(RuntimeState::new(
            event_tx,
            Arc::new(std::sync::atomic::AtomicU16::new(0)),
        ));
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
        state.peers.write().await.insert(
            "sender".into(),
            PeerConfig {
                endpoint: None,
                identity_public_key: [0u8; 32],
                e2e_public_key: *sender.public_e2e_key().as_bytes(),
            },
        );
        let data = Arc::new(
            RelayDataClient::new(
                "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
                vec![0u8; 32],
                "credential".into(),
                [0u8; 32],
            )
            .expect("relay data client"),
        );
        let manifest = relay_test_manifest("relay-reoffer-transfer");
        // 两个 Offer 都在把 receiver 移入 state 前构造（encrypt 需要借用其公钥）。
        let first_envelope = build_relay_offer_envelope(
            &sender,
            &receiver,
            "00000000000000000000000000000001",
            &manifest,
            "0000000000000001",
        );
        let second_envelope = build_relay_offer_envelope(
            &sender,
            &receiver,
            "00000000000000000000000000000002",
            &manifest,
            "0000000000000002",
        );
        state.identity.write().await.replace(Arc::new(receiver));

        receive_relay_offer(&state, &data, "sender", &first_envelope)
            .await
            .expect("first offer is accepted for approval");
        assert_eq!(
            state
                .transfers
                .snapshot("relay-reoffer-transfer")
                .await
                .unwrap()
                .state,
            network_transfer::TransferState::WaitingApproval
        );
        // 先让 timeout 任务被 poll 一次、注册 30s 睡眠定时器，再快进时钟。
        tokio::task::yield_now().await;

        // 快进超过审批超时，让 relay-approval-timeout 任务执行。
        tokio::time::advance(INCOMING_APPROVAL_TIMEOUT + std::time::Duration::from_secs(1)).await;
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        // 超时任务必须移除 TransferManager 条目并清空 pending，释放 transfer_id。
        assert!(
            state
                .transfers
                .snapshot("relay-reoffer-transfer")
                .await
                .is_none(),
            "timed-out transfer must be removed so the transfer_id can be reused"
        );
        assert!(state.relay_pending_incoming.read().await.is_empty());

        // 同一 transfer_id 的新 Offer（新 session_id）必须能被接受，不得报 already active。
        receive_relay_offer(&state, &data, "sender", &second_envelope)
            .await
            .expect("second offer of the same transfer_id is accepted after timeout");
    }
}
