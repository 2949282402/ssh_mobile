//! Relay v1 enrollment 运行时、透明传输路由与 E2E 处理。

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_protocol::{ConfigureRelayCommand, NetworkError as ProtocolError, NetworkErrorCode};
use network_relay::{RelayClient, RelayEvent};
use network_transfer::build_file_manifest;
use rand::RngCore;
use serde_json::json;
use std::collections::hash_map::Entry;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

use crate::events::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error, emit_transfer_progress,
    protocol_error, protocol_error_with_context,
};
use crate::runtime::{
    PeerConfig, RuntimeState, INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS,
};

/// 等待 UI 审批的待处理 Relay 申请。
pub(crate) struct PendingRelayIncoming {
    pub(crate) sender_id: String,
    pub(crate) file_name: String,
    pub(crate) total_bytes: u64,
    pub(crate) content_key: [u8; 32],
    pub(crate) nonce_prefix: [u8; 4],
}

/// 在校验文件提交前使用的活跃 Relay 接收状态。
pub(crate) struct ActiveRelayIncoming {
    pub(crate) offer: PendingRelayIncoming,
    pub(crate) file: tokio::fs::File,
    pub(crate) temporary_path: PathBuf,
    pub(crate) final_path: PathBuf,
    pub(crate) next_sequence: u64,
    pub(crate) received_bytes: u64,
}

/// 连接原生 Relay 数据面并启动事件消费者。
pub(crate) async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
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
    let mut relay = RelayClient::new(
        command.relay_url,
        device_id,
        command.relay_credential,
        signing_seed,
    )
    .map_err(|_| protocol_error(NetworkErrorCode::RelayError, "invalid Relay configuration"))?;
    relay
        .connect()
        .await
        .map_err(|_| protocol_error(NetworkErrorCode::RelayError, "Relay connection failed"))?;
    let events = relay
        .take_events()
        .map_err(|_| protocol_error(NetworkErrorCode::RelayError, "Relay event stream failed"))?;
    *state.relay.write().await = Some(Arc::new(relay));
    tokio::spawn(handle_relay_events(events, state));
    Ok(())
}

/// 断开原生 Relay 客户端，并发布类型化最终状态。
pub(crate) async fn disconnect_relay(state: &RuntimeState) -> Result<(), ProtocolError> {
    let relay = state.relay.write().await.take();
    if let Some(relay) = relay {
        if let Ok(mut relay) = Arc::try_unwrap(relay) {
            relay.disconnect().await;
        }
    }
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        None,
    );
    Ok(())
}

/// 消费 Relay 控制帧和二进制帧，不将其暴露给 Dart。
pub(crate) async fn handle_relay_events(
    mut events: mpsc::Receiver<RelayEvent>,
    state: Arc<RuntimeState>,
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
                        receive_relay_offer(&state, session_id.clone(), sender_id, payload).await
                    {
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
                ..
            } if kind == "complete" => {
                if let Err(error) =
                    complete_relay_incoming(&state, &session_id, peer_id.as_deref()).await
                {
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    tracing::warn!("Failed inbound Relay completion: {}", error);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "accept" => {
                if let Some(sender) = state.relay_acceptances.write().await.remove(&session_id) {
                    let _ = sender.send(true);
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
                    let _ = sender.send(false);
                }
                if let Some(sender) = state.relay_completions.write().await.remove(&session_id) {
                    let _ = sender.send(false);
                }
                cancel_relay_incoming(&state, &session_id).await;
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
                    cancel_relay_incoming(&state, &session_id).await;
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    tracing::warn!("Rejected inbound Relay chunk: {}", error);
                }
            }
            RelayEvent::Control { .. } => {}
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
    if envelope.len() < 32 + 12 + 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer envelope is truncated",
        )
        .into());
    }
    let ephemeral_key: [u8; 32] = envelope[..32].try_into()?;
    let nonce = &envelope[32..44];
    let identity = state
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
    let shared = identity
        .e2e_key
        .diffie_hellman(&X25519PublicKey::from(ephemeral_key));
    let cipher = Aes256Gcm::new_from_slice(shared.as_bytes())
        .map_err(|_| std::io::Error::other("invalid E2E shared secret"))?;
    let clear = cipher
        .decrypt(Nonce::from_slice(nonce), &envelope[44..])
        .map_err(|_| std::io::Error::other("Relay offer authentication failed"))?;
    let value: serde_json::Value = serde_json::from_slice(&clear)?;
    let file_name = value
        .get("file_name")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay file name is missing"))?;
    let total_bytes = value
        .get("file_size")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| std::io::Error::other("Relay file size is invalid"))?;
    let offer_sender = value.get("sender_id").and_then(serde_json::Value::as_str);
    let receiver = value.get("receiver_id").and_then(serde_json::Value::as_str);
    if value.get("v").and_then(serde_json::Value::as_u64) != Some(1)
        || value.get("session_id").and_then(serde_json::Value::as_str) != Some(session_id.as_str())
        || offer_sender != Some(sender_id.as_str())
        || receiver != Some(identity.device_id.as_str())
        || !is_safe_file_name(file_name)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer identity or metadata is invalid",
        )
        .into());
    }
    let content_key: [u8; 32] = URL_SAFE_NO_PAD
        .decode(
            value
                .get("content_key")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| std::io::Error::other("content key is missing"))?,
        )?
        .try_into()
        .map_err(|_| std::io::Error::other("content key has an invalid length"))?;
    let nonce_prefix: [u8; 4] = URL_SAFE_NO_PAD
        .decode(
            value
                .get("nonce_prefix")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| std::io::Error::other("nonce prefix is missing"))?,
        )?
        .try_into()
        .map_err(|_| std::io::Error::other("nonce prefix has an invalid length"))?;
    let pending = PendingRelayIncoming {
        sender_id: sender_id.clone(),
        file_name: file_name.to_string(),
        total_bytes,
        content_key,
        nonce_prefix,
    };
    if state
        .relay_active_incoming
        .lock()
        .await
        .contains_key(&session_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "duplicate Relay session",
        )
        .into());
    }
    {
        let mut pending_transfers = state.relay_pending_incoming.write().await;
        if pending_transfers.len() >= MAX_PENDING_INCOMING_TRANSFERS {
            return Err(std::io::Error::other("too many pending Relay offers").into());
        }
        match pending_transfers.entry(session_id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(pending);
            }
            Entry::Occupied(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "duplicate Relay session",
                )
                .into());
            }
        }
    }
    let manifest = network_transfer::FileManifest {
        transfer_id: session_id,
        file_name: file_name.to_string(),
        file_size: total_bytes,
        modified_at: 0,
        content_hash: "0".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    emit_incoming_offer(&state.event_tx, &sender_id, &manifest);
    let expiry_state = Arc::clone(state);
    let expiry_session_id = manifest.transfer_id;
    tokio::spawn(async move {
        tokio::time::sleep(INCOMING_APPROVAL_TIMEOUT).await;
        if expiry_state
            .relay_pending_incoming
            .write()
            .await
            .remove(&expiry_session_id)
            .is_some()
        {
            if let Some(relay) = expiry_state.relay.read().await.as_ref() {
                let _ = relay
                    .send_session_control("cancel", &expiry_session_id)
                    .await;
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
    let result = async {
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
        let relay = state.relay.read().await.clone().ok_or_else(|| {
            protocol_error_with_context(
                NetworkErrorCode::RelayError,
                "Relay is unavailable",
                "respond_incoming",
                Some(&pending.sender_id),
            )
        })?;
        if !accepted {
            relay
                .send_session_control("cancel", transfer_id)
                .await
                .map_err(|_| {
                    protocol_error(NetworkErrorCode::RelayError, "Relay cancellation failed")
                })?;
            return Ok(());
        }
        let receive_directory = state
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "receive directory is unavailable",
                )
            })?;
        tokio::fs::create_dir_all(&receive_directory)
            .await
            .map_err(|_| {
                protocol_error(
                    NetworkErrorCode::IoError,
                    "receive directory is unavailable",
                )
            })?;
        let final_path = receive_directory.join(&pending.file_name);
        if tokio::fs::symlink_metadata(&final_path).await.is_ok() {
            return Err(protocol_error(
                NetworkErrorCode::IoError,
                "destination file already exists",
            ));
        }
        let temporary_path = receive_directory.join(format!("{transfer_id}.relay.part"));
        let file = tokio::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary_path)
            .await
            .map_err(|_| {
                protocol_error(
                    NetworkErrorCode::IoError,
                    "temporary file cannot be created",
                )
            })?;
        state.relay_active_incoming.lock().await.insert(
            transfer_id.to_string(),
            ActiveRelayIncoming {
                offer: pending,
                file,
                temporary_path,
                final_path,
                next_sequence: 0,
                received_bytes: 0,
            },
        );
        relay
            .send_session_control("accept", transfer_id)
            .await
            .map_err(|_| protocol_error(NetworkErrorCode::RelayError, "Relay approval failed"))
    }
    .await;
    if result.is_err() {
        cancel_relay_incoming(state, transfer_id).await;
        if let Some(relay) = state.relay.read().await.as_ref() {
            let _ = relay.send_session_control("cancel", transfer_id).await;
        }
    }
    result
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
        .get_mut(session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    if sequence != active.next_sequence || ciphertext.len() < 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk is replayed or reordered",
        )
        .into());
    }
    let cipher = Aes256Gcm::new_from_slice(&active.offer.content_key)
        .map_err(|_| std::io::Error::other("invalid Relay content key"))?;
    let session_bytes: [u8; 16] = hex::decode(session_id)?.try_into().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Relay session ID")
    })?;
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(&active.offer.nonce_prefix);
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    let mut aad = [0u8; 24];
    aad[..16].copy_from_slice(&session_bytes);
    aad[16..].copy_from_slice(&sequence.to_be_bytes());
    let clear = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| std::io::Error::other("Relay chunk authentication failed"))?;
    if clear.is_empty() || active.received_bytes + clear.len() as u64 > active.offer.total_bytes {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk exceeds declared file size",
        )
        .into());
    }
    active.file.write_all(&clear).await?;
    active.received_bytes += clear.len() as u64;
    active.next_sequence += 1;
    emit_transfer_progress(
        &state.event_tx,
        session_id,
        active.received_bytes,
        active.offer.total_bytes,
    );
    Ok(())
}

/// 校验 Relay 完成状态，提交文件并发送 complete_ack。
async fn complete_relay_incoming(
    state: &RuntimeState,
    session_id: &str,
    sender_id: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active = state
        .relay_active_incoming
        .lock()
        .await
        .remove(session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    if sender_id != Some(active.offer.sender_id.as_str())
        || active.received_bytes != active.offer.total_bytes
    {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay completion arrived before all bytes",
        )
        .into());
    }
    if let Err(error) = active.file.flush().await {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(error.into());
    }
    drop(active.file);
    if let Err(error) = tokio::fs::rename(&active.temporary_path, &active.final_path).await {
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(error.into());
    }
    let relay = state
        .relay
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("Relay is unavailable"))?;
    relay
        .send_session_control("complete_ack", session_id)
        .await?;
    emit_transfer_completed(
        &state.event_tx,
        session_id,
        &active.final_path.to_string_lossy(),
    );
    Ok(())
}

/// 取消或失败后移除待处理和临时 Relay 状态。
pub(crate) async fn cancel_relay_incoming(state: &RuntimeState, session_id: &str) {
    state
        .relay_pending_incoming
        .write()
        .await
        .remove(session_id);
    if let Some(active) = state.relay_active_incoming.lock().await.remove(session_id) {
        drop(active.file);
        tokio::fs::remove_file(active.temporary_path).await.ok();
    }
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

/// 发送加密 Relay 申请、分块和完成确认。
pub(crate) async fn send_file_over_relay(
    peer: PeerConfig,
    peer_id: String,
    path: PathBuf,
    transfer_id: String,
    state: Arc<RuntimeState>,
) {
    let result = async {
        let relay = state
            .relay
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("Relay is unavailable"))?;
        let manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        let mut session_bytes = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut session_bytes);
        let session_id = hex::encode(session_bytes);
        let mut content_key = [0u8; 32];
        let mut nonce_prefix = [0u8; 4];
        rand::rngs::OsRng.fill_bytes(&mut content_key);
        rand::rngs::OsRng.fill_bytes(&mut nonce_prefix);
        let offer = serde_json::to_vec(&json!({
            "v": 1,
            "session_id": session_id,
            "sender_id": state.identity.read().await.as_ref().map(|identity| identity.device_id.as_str())
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?,
            "receiver_id": peer_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "content_key": URL_SAFE_NO_PAD.encode(content_key),
            "nonce_prefix": URL_SAFE_NO_PAD.encode(nonce_prefix),
        }))?;
        let encrypted_offer = encrypt_relay_offer(&offer, peer.e2e_public_key)?;
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
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay_acceptances.write().await.remove(&session_id);
        if !accepted {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay receiver rejected file",
                )
                .into(),
            );
        }
        let cipher = Aes256Gcm::new_from_slice(&content_key)
            .map_err(|_| std::io::Error::other("invalid Relay content key"))?;
        let mut file = tokio::fs::File::open(&path).await?;
        let mut buffer = vec![0u8; network_transfer::DEFAULT_TRANSFER_BUFFER];
        let mut sequence = 0u64;
        let mut transferred = 0u64;
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
            let read = file.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            let ciphertext = encrypt_relay_chunk(
                &cipher,
                &session_bytes,
                &nonce_prefix,
                sequence,
                &buffer[..read],
            )?;
            relay
                .forward_opaque_payload(&session_id, sequence, &ciphertext)
                .await?;
            sequence += 1;
            transferred += read as u64;
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
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    if let Some(session_id) = state.relay_sessions.write().await.remove(&transfer_id) {
        if result.is_err() {
            if let Some(relay) = state.relay.read().await.as_ref() {
                let _ = relay.send_session_control("cancel", &session_id).await;
            }
        }
    }
    state.transfers.remove_transfer(&transfer_id).await;
    if let Err(error) = result {
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::RelayError,
            "Relay transfer failed".to_string(),
            "send",
            Some(&peer_id),
        );
        tracing::debug!(transfer_id = %transfer_id, error = %error, "native Relay transfer failed");
    }
}

/// 使用临时 X25519 密钥和 AES-GCM 加密 Relay 申请。
fn encrypt_relay_offer(
    plaintext: &[u8],
    peer_public_key: [u8; 32],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&X25519PublicKey::from(peer_public_key));
    let cipher = Aes256Gcm::new_from_slice(shared.as_bytes())
        .map_err(|_| std::io::Error::other("invalid E2E shared secret"))?;
    let mut nonce = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| std::io::Error::other("Relay offer encryption failed"))?;
    let mut envelope = Vec::with_capacity(44 + encrypted.len());
    envelope.extend_from_slice(ephemeral_public.as_bytes());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&encrypted);
    Ok(envelope)
}

/// 使用序列绑定 nonce 和关联数据加密一个 Relay 分块。
fn encrypt_relay_chunk(
    cipher: &Aes256Gcm,
    session_id: &[u8; 16],
    nonce_prefix: &[u8; 4],
    sequence: u64,
    plaintext: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(nonce_prefix);
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    let mut aad = [0u8; 24];
    aad[..16].copy_from_slice(session_id);
    aad[16..].copy_from_slice(&sequence.to_be_bytes());
    cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| std::io::Error::other("Relay chunk encryption failed").into())
}
