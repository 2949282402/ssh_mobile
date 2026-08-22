// Relay v2 file-transfer offer, approval, chunking, resume, and cancel ownership.
use super::*;

/// 在通知 UI 前解密并校验传入 Relay 申请。
pub(super) async fn receive_relay_offer(
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
    // 加密 nonce（与 V2 同构），必须在明文中。
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
        .lifecycle
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
        .relay
        .active_incoming
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
        let mut pending_transfers = state.relay.pending_incoming.write().await;
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
        .transfer
        .manager
        .claim_incoming_resume(&manifest, sender_id)
        .await;
    let receive_directory = state.lifecycle.receive_directory.read().await.clone();
    let completed_path = if let Some(directory) = receive_directory.as_ref() {
        existing_completed_file(&manifest, directory).await?
    } else {
        None
    };
    if is_new_offer && resume_offset.is_none() {
        if !state
            .transfer
            .manager
            .register_incoming(manifest.clone(), sender_id.to_string())
            .await
        {
            state
                .relay
                .pending_incoming
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
                let pending = expiry_state.relay.pending_incoming.read().await;
                let entry = pending.get(&expiry_transfer_id);
                (
                    entry.is_some_and(|pending| pending.session_id == session_id),
                    entry.map(|pending| pending.sender_id.clone()),
                )
            };
            if expired {
                expiry_state
                    .relay
                    .pending_incoming
                    .write()
                    .await
                    .remove(&expiry_transfer_id);
                expiry_state
                    .transfer
                    .manager
                    .fail_transfer(&expiry_transfer_id, TransferFailureReason::UserRejected)
                    .await;
                // 审批超时是终态失败：移除 TransferManager 条目，释放 transfer_id。
                // 否则条目停留在 Failed，register_incoming/claim_incoming_resume 只接受
                // Vacant 或 Paused，后续同一 transfer_id 的再 Offer 会被
                // "TransferId is already active" 永久拒绝。
                expiry_state
                    .transfer
                    .manager
                    .remove_transfer(&expiry_transfer_id)
                    .await;
                // 取消只发到承载该 transfer 的对端 reservation 连接。
                if let Some(sender_id) = sender_id {
                    if let Some(data) = expiry_state.path_relay_data(&sender_id).await {
                        let _ = send_file_cancel(&data, &expiry_transfer_id).await;
                    }
                }
            }
        });
    Ok(())
}

/// 发送文件控制取消信封（body = transfer_id）。
pub(super) async fn send_file_cancel(
    data: &RelayDataClient,
    transfer_id: &str,
) -> Result<(), RelayError> {
    send_data_envelope(data, DATA_ENV_FILE_CANCEL, transfer_id.as_bytes()).await
}

/// 应用传入 Relay 审批，并创建临时文件。
pub(crate) async fn respond_to_relay_incoming(
    state: &RuntimeState,
    transfer_id: &str,
    accepted: bool,
) -> Result<(), ProtocolError> {
    let pending = state
        .relay
        .pending_incoming
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
        .path_relay_data(&pending.sender_id)
        .await
        .ok_or_else(|| {
            protocol_error_with_context(
                NetworkErrorCode::RelayError,
                "Relay data plane is unavailable",
                "respond_incoming",
                None,
            )
        })?;
    if !accepted {
        state.transfer.manager.cancel_transfer(transfer_id).await;
        state.transfer.manager.remove_transfer(transfer_id).await;
        send_file_cancel(&data, transfer_id).await.map_err(|_| {
            protocol_error(NetworkErrorCode::RelayError, "Relay cancellation failed")
        })?;
        return Ok(());
    }
    state
        .relay
        .pending_incoming
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
pub(super) async fn accept_pending_relay_incoming(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    transfer_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pending = state
        .relay
        .pending_incoming
        .write()
        .await
        .remove(transfer_id)
        .ok_or_else(|| std::io::Error::other("Relay transfer is not pending"))?;
    let receive_directory = state
        .lifecycle
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
        .transfer
        .manager
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
    state
        .transfer
        .manager
        .update_progress(transfer_id, offset)
        .await;
    if !state.transfer.manager.mark_transferring(transfer_id).await {
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
    state.relay.active_incoming.lock().await.insert(
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
        if let Some(active) = state.relay.active_incoming.lock().await.remove(transfer_id) {
            drop(active.file);
        }
        state.transfer.manager.pause_for_network(transfer_id).await;
        state
            .relay
            .pending_incoming
            .write()
            .await
            .insert(transfer_id.to_string(), pending);
        return Err(error.into());
    }
    Ok(())
}

/// 认证、排序并写入一个加密 Relay 分块。
pub(super) async fn receive_relay_chunk(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    session_id: &str,
    sequence: u64,
    ciphertext: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active_transfers = state.relay.active_incoming.lock().await;
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
        .transfer
        .manager
        .update_progress(&transfer_id, active.received_bytes)
        .await;
    let _ = data;
    Ok(())
}

/// 校验 Relay 完成状态，提交文件并发送 complete_ack。
pub(super) async fn complete_relay_incoming(
    state: &RuntimeState,
    data: &Arc<RelayDataClient>,
    session_id: &str,
    sender_id: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (transfer_id, mut active) = {
        let mut active_transfers = state.relay.active_incoming.lock().await;
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
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::Protocol)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay completion arrived before all bytes",
        )
        .into());
    }
    if active.already_completed {
        state.transfer.manager.mark_verifying(&transfer_id).await;
        state.transfer.manager.mark_completed(&transfer_id).await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        send_data_envelope(data, DATA_ENV_FILE_COMPLETE_ACK, transfer_id.as_bytes()).await?;
        return Ok(());
    }
    if !relay_hash_matches(active.hasher, &active.offer.manifest.content_hash) {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::HashMismatch)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
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
                .transfer
                .manager
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfer.manager.remove_transfer(&transfer_id).await;
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
                .transfer
                .manager
                .fail_transfer(&transfer_id, TransferFailureReason::Io)
                .await;
            state.transfer.manager.remove_transfer(&transfer_id).await;
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
            .transfer
            .manager
            .fail_transfer(&transfer_id, TransferFailureReason::Io)
            .await;
        state.transfer.manager.remove_transfer(&transfer_id).await;
        return Err(error.into());
    }
    state.transfer.manager.mark_verifying(&transfer_id).await;
    let completed = state.transfer.manager.mark_completed(&transfer_id).await;
    state.transfer.manager.remove_transfer(&transfer_id).await;
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
        .relay
        .pending_incoming
        .write()
        .await
        .remove(session_or_transfer_id);
    let active = {
        let mut active_transfers = state.relay.active_incoming.lock().await;
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
    } else if let Some(directory) = state.lifecycle.receive_directory.read().await.clone() {
        tokio::fs::remove_file(relay_partial_path(&directory, &transfer_id))
            .await
            .ok();
    }
    state.transfer.manager.cancel_transfer(&transfer_id).await;
    state.transfer.manager.remove_transfer(&transfer_id).await;
}

/// CancelTransfer 的 Relay 侧清理入口；显式取消才会删除 checkpoint。
pub(crate) async fn cancel_transfer(state: &RuntimeState, transfer_id: &str) {
    // 取消只发到承载该 transfer 的对端 reservation 连接（按 transfer 所属 peer 定位）。
    if let Some(peer_id) = state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .map(|snapshot| snapshot.peer_id)
    {
        if let Some(data) = state.path_relay_data(&peer_id).await {
            let _ = send_file_cancel(&data, transfer_id).await;
        }
    }
    cancel_relay_incoming(state, transfer_id).await;
}

impl RelayTransferPort for RuntimeState {
    fn dispatch_relay_transfer(
        self: Arc<Self>,
        peer: PeerConfig,
        transfer: ResumableTransfer,
        lease: crate::connect::PathLease,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'static>> {
        Box::pin(async move {
            let _lease = lease;
            send_file_over_relay(peer, transfer, self).await;
        })
    }

    fn respond_to_relay_incoming<'a>(
        &'a self,
        transfer_id: &'a str,
        accepted: bool,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Result<(), network_protocol::NetworkError>>
                + Send
                + 'a,
        >,
    > {
        Box::pin(respond_to_relay_incoming(self, transfer_id, accepted))
    }

    fn cancel_relay_transfer<'a>(
        &'a self,
        transfer_id: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
        Box::pin(cancel_transfer(self, transfer_id))
    }
}

/// 返回 Relay 文件名是否是单个安全路径组件。
pub(super) fn is_safe_file_name(value: &str) -> bool {
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
pub(super) fn is_sha256_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// 返回接收内容的 SHA-256 摘要是否与 enrollment offer 一致。
pub(super) fn relay_hash_matches(hasher: Sha256, expected: &str) -> bool {
    hex::encode(hasher.finalize()).eq_ignore_ascii_case(expected)
}

/// 计算稳定的 Manifest Hash；socket session token 不参与，因此重连可复用它。
pub(super) fn relay_manifest_hash(manifest: &FileManifest) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"ssh-mobile/relay-manifest/V2\0");
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

pub(super) fn relay_partial_path(directory: &std::path::Path, transfer_id: &str) -> PathBuf {
    directory.join(format!("{transfer_id}.part"))
}

pub(super) fn valid_relay_offset(offset: u64, total_bytes: u64) -> bool {
    offset <= total_bytes
        && (offset == 0 || offset == total_bytes || offset.is_multiple_of(RELAY_FILE_CHUNK_BYTES))
}

pub(super) async fn hash_partial_file(
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

pub(super) fn is_transient_relay_error(error: &(dyn std::error::Error + 'static)) -> bool {
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
        let data = state.path_relay_data(&peer_id).await
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
            "sender_id": state.lifecycle.identity.read().await.as_ref().map(|identity| identity.device_id.as_str())
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?,
            "receiver_id": peer_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "modified_at": manifest.modified_at,
            "content_hash": manifest.content_hash,
        }))?;
        // offer 用对端 E2E 公钥加密（与 V2 同构）；信封 = [session_id][base64(密文)]。
        let encrypted_offer =
            crypto::encrypt_application_offer(&offer, peer.e2e_public_key, &session_bytes)?;
        let encoded_offer = URL_SAFE_NO_PAD.encode(encrypted_offer);
        let mut offer_envelope = Vec::with_capacity(32 + encoded_offer.len());
        offer_envelope.extend_from_slice(session_id.as_bytes());
        offer_envelope.extend_from_slice(encoded_offer.as_bytes());
        let (acceptance_tx, acceptance_rx) = oneshot::channel();
        state
            .relay.acceptances
            .write()
            .await
            .insert(transfer_id.clone(), acceptance_tx);
        send_data_envelope(&data, DATA_ENV_FILE_OFFER, &offer_envelope).await?;
        let acceptance_result = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx).await;
        state
            .relay.acceptances
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
        if !state.transfer.manager.mark_transferring(&transfer_id).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::other("transfer is no longer active").into(),
            );
        }
        state
            .transfer.manager
            .update_progress(&transfer_id, acceptance.offset)
            .await;
        let mut file = tokio::fs::File::open(&path).await?;
        file.seek(SeekFrom::Start(acceptance.offset)).await?;
        // 缓冲区按明文分块大小分配：整块加密后 + 信封开销仍落在数据面载荷上限内。
        let mut buffer = vec![0u8; RELAY_FILE_CHUNK_BYTES as usize];
        let mut sequence = acceptance.offset / RELAY_FILE_CHUNK_BYTES;
        let mut transferred = acceptance.offset;
        let cancellation = state.transfer.manager.cancellation_token(&transfer_id).await;
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
                .transfer.manager
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
            .relay.completions
            .write()
            .await
            .insert(transfer_id.clone(), completion_tx);
        send_data_envelope(&data, DATA_ENV_FILE_COMPLETE, transfer_id.as_bytes()).await?;
        let completed = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, completion_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay.completions.write().await.remove(&transfer_id);
        if !completed {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Relay completion acknowledgement timed out",
            )
                .into());
        }
        state.transfer.manager.mark_verifying(&transfer_id).await;
        if state.transfer.manager.mark_completed(&transfer_id).await {
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
        if let Some(data) = state.path_relay_data(&peer_id).await {
            let _ = send_file_cancel(&data, &transfer_id).await;
        }
    }
    if result.is_err()
        && state
            .transfer
            .manager
            .snapshot(&transfer_id)
            .await
            .is_none()
    {
        return;
    }
    if result.is_ok() || state.transfer.manager.is_cancelled(&transfer_id).await {
        state.transfer.manager.remove_transfer(&transfer_id).await;
    } else if let Err(error) = result {
        if is_transient_relay_error(error.as_ref())
            && state.transfer.manager.pause_for_network(&transfer_id).await
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
        state
            .transfer
            .manager
            .fail_transfer(&transfer_id, reason)
            .await;
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::RelayError,
            "Relay transfer failed".to_string(),
            "send",
            Some(&peer_id),
        );
        state.transfer.manager.remove_transfer(&transfer_id).await;
        tracing::debug!(transfer_id = %transfer_id, error = %error, "native Relay file transfer failed");
    }
}
