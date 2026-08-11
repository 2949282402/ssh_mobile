//! v1 直连文件传输任务分发及类型化完成/失败事件。

use network_protocol::{
    NetworkCommand, NetworkError as ProtocolError, NetworkErrorCode,
    RespondIncomingTransferCommand, RouteType, SendFileCommand,
};
use network_quic::{
    read_file_completion, read_file_decision, read_file_offer, write_file_completion,
    write_file_decision, write_file_offer,
};
use network_transfer::{
    build_file_manifest, existing_completed_file, existing_partial_offset,
    stream_receive_file_cancellable, stream_send_file_cancellable, FileManifest, TransferManager,
};
use quinn::{Connection, RecvStream, SendStream};
use std::collections::hash_map::Entry;
use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

use crate::events::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error, emit_transfer_progress,
    protocol_error, protocol_error_with_peer,
};
use crate::runtime::{
    RuntimeState, INCOMING_APPROVAL_TIMEOUT, MAX_PENDING_INCOMING_TRANSFERS,
    RECONNECT_INITIAL_BACKOFF, TRANSFER_COMPLETION_TIMEOUT,
};

/// 校验源文件，并分离直连传输任务。
pub(crate) async fn start_file_send(
    state: Arc<RuntimeState>,
    command: SendFileCommand,
) -> Result<(), ProtocolError> {
    if command.transfer_id.is_empty() || command.peer_id.is_empty() || command.file_path.is_empty()
    {
        return Err(crate::events::protocol_error_with_context(
            NetworkErrorCode::InvalidArgument,
            "transfer_id, peer_id, and file_path are required",
            "send",
            Some(&command.peer_id),
        ));
    }
    let path = PathBuf::from(&command.file_path);
    let metadata = tokio::fs::metadata(&path).await.map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::IoError,
            "source file is unavailable",
            "send",
            &command.peer_id,
        )
    })?;
    if !metadata.is_file() {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "source is not a regular file",
            "send",
            &command.peer_id,
        ));
    }
    let connection = state.sessions.current_connection(&command.peer_id).await;
    let peer = state
        .peers
        .read()
        .await
        .get(&command.peer_id)
        .cloned()
        .ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "peer is not registered",
                "send",
                &command.peer_id,
            )
        })?;
    let relay_available = match state.relay.read().await.clone() {
        Some(relay) => relay.is_usable().await,
        None => false,
    };
    if connection.is_none() && !relay_available {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no active direct or Relay route",
            "send",
            &command.peer_id,
        ));
    }

    let manifest = build_file_manifest(command.transfer_id.clone(), &path)
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::IoError,
                "source file cannot be hashed",
                "send",
                &command.peer_id,
            )
        })?;
    manifest.validate().map_err(|message| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            message,
            "send",
            &command.peer_id,
        )
    })?;
    if !state
        .transfers
        .register_outgoing(manifest.clone(), path.clone(), command.peer_id.clone())
        .await
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "transfer_id is already active",
            "send",
            &command.peer_id,
        ));
    }
    if let Some(connection) = connection {
        tokio::spawn(send_file(
            connection,
            path,
            manifest,
            command.transfer_id,
            command.peer_id,
            state,
        ));
    } else {
        tokio::spawn(crate::relay::send_file_over_relay(
            peer,
            command.peer_id,
            path,
            command.transfer_id,
            state,
        ));
    }
    Ok(())
}

/// 流式传输直连 QUIC 文件，并只发布最终类型化结果。
async fn send_file(
    connection: Connection,
    path: PathBuf,
    manifest: FileManifest,
    transfer_id: String,
    peer_id: String,
    state: Arc<RuntimeState>,
) {
    let result = async {
        let current_manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        if current_manifest != manifest {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "source file changed during resumable transfer",
                )
                .into(),
            );
        }
        let (mut send, mut receive) = connection.open_bi().await?;
        write_file_offer(&mut send, &manifest).await?;
        let offset = read_file_decision(&mut receive).await?.ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "receiver rejected file",
            )
        })?;
        if offset > manifest.file_size {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid resume offset")
                    .into(),
            );
        }
        state.transfers.update_progress(&transfer_id, offset).await;
        let (progress_tx, progress_rx) = unbounded_channel();
        tokio::spawn(forward_progress(
            transfer_id.clone(),
            progress_rx,
            state.event_tx.clone(),
            state.transfers.clone(),
        ));
        let cancellation = state.transfers.cancellation_token(&transfer_id).await;
        stream_send_file_cancellable(
            &path,
            offset,
            &mut send,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        send.finish()?;
        tokio::time::timeout(
            TRANSFER_COMPLETION_TIMEOUT,
            read_file_completion(&mut receive),
        )
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "file completion timed out")
        })??;
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    match result {
        Ok(()) => state.transfers.remove_transfer(&transfer_id).await,
        Err(error)
            if !state.transfers.is_cancelled(&transfer_id).await
                && is_transient_transport_error(error.as_ref())
                && state.transfers.pause_transfer(&transfer_id).await =>
        {
            // 保留源文件、TransferId 和接收端的 `.part`，等待下一次
            // Connection Ready 后重新走 manifest/offset 协商。
            schedule_resume(Arc::clone(&state), peer_id);
            tracing::debug!(transfer_id = %transfer_id, error = %error, "native QUIC transfer paused for resume");
        }
        Err(error) => {
            state.transfers.remove_transfer(&transfer_id).await;
            emit_transfer_error(
                &state.event_tx,
                &transfer_id,
                NetworkErrorCode::QuicError,
                "file transfer failed".to_string(),
                "send",
                Some(&peer_id),
            );
            tracing::debug!(transfer_id = %transfer_id, error = %error, "native file transfer failed");
        }
    }
}

/// Connection Ready 后领取一个 Peer 的暂停传输，并重新协商真实 offset。
pub(crate) async fn resume_transfers_for_peer(state: Arc<RuntimeState>, peer_id: String) {
    let Some(connection) = state.sessions.current_connection(&peer_id).await else {
        return;
    };
    for transfer in state.transfers.take_resumable_for_peer(&peer_id).await {
        tokio::spawn(send_file(
            connection.clone(),
            transfer.source_path,
            transfer.manifest,
            transfer.transfer_id,
            transfer.peer_id,
            Arc::clone(&state),
        ));
    }
}

/// 让暂停发生在 Connection Ready 事件之后也能触发一次恢复检查。
fn schedule_resume(state: Arc<RuntimeState>, peer_id: String) {
    tokio::spawn(async move {
        tokio::time::sleep(RECONNECT_INITIAL_BACKOFF).await;
        resume_transfers_for_peer(state, peer_id).await;
    });
}

/// 校验传入申请，并等待接收方审批决定。
pub(crate) async fn handle_incoming_file(
    peer_id: String,
    mut send: SendStream,
    mut receive: RecvStream,
    state: Arc<RuntimeState>,
) {
    let mut active_transfer_id = None;
    let mut owns_transfer = false;
    let result = async {
        let manifest = read_file_offer(&mut receive).await?;
        active_transfer_id = Some(manifest.transfer_id.clone());
        let (decision_tx, decision_rx) = tokio::sync::oneshot::channel();
        {
            let mut decisions = state.incoming_decisions.write().await;
            if decisions.len() >= MAX_PENDING_INCOMING_TRANSFERS {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::other("too many pending incoming transfers").into(),
                );
            }
            match decisions.entry(manifest.transfer_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(decision_tx);
                }
                Entry::Occupied(_) => {
                    return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                        std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            "duplicate transfer ID",
                        )
                        .into(),
                    );
                }
            }
        }
        emit_incoming_offer(&state.event_tx, &peer_id, &manifest, RouteType::QuicDirect);
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, decision_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state
            .incoming_decisions
            .write()
            .await
            .remove(&manifest.transfer_id);
        if !accepted {
            write_file_decision(&mut send, false, 0).await?;
            send.finish()?;
            return Ok(());
        }

        let receive_directory = state
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
        let completed_path = existing_completed_file(&manifest, &receive_directory).await?;
        let resume_offset = match completed_path.as_ref() {
            Some(_) => manifest.file_size,
            None => existing_partial_offset(&manifest, &receive_directory).await?,
        };
        write_file_decision(&mut send, true, resume_offset).await?;
        if let Some(local_path) = completed_path {
            write_file_completion(&mut send).await?;
            send.finish()?;
            emit_transfer_completed(&state.event_tx, &manifest.transfer_id, &local_path);
            return Ok(());
        }
        if !state.transfers.register_transfer(manifest.clone()).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer ID is already active",
                )
                .into(),
            );
        }
        owns_transfer = true;
        state
            .transfers
            .update_progress(&manifest.transfer_id, resume_offset)
            .await;
        let cancellation = state
            .transfers
            .cancellation_token(&manifest.transfer_id)
            .await;
        let (progress_tx, progress_rx) = unbounded_channel();
        tokio::spawn(forward_progress(
            manifest.transfer_id.clone(),
            progress_rx,
            state.event_tx.clone(),
            state.transfers.clone(),
        ));
        let local_path = stream_receive_file_cancellable(
            &manifest,
            &receive_directory,
            resume_offset,
            &mut receive,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        state.transfers.remove_transfer(&manifest.transfer_id).await;
        write_file_completion(&mut send).await?;
        send.finish()?;
        emit_transfer_completed(&state.event_tx, &manifest.transfer_id, &local_path);
        Ok(())
    }
    .await;
    let preserve_partial = result
        .as_ref()
        .err()
        .is_some_and(|error| is_transient_transport_error(error.as_ref()));
    if let Some(transfer_id) = active_transfer_id.as_deref() {
        if owns_transfer {
            state.transfers.remove_transfer(transfer_id).await;
        }
        state.incoming_decisions.write().await.remove(transfer_id);
        if owns_transfer && result.is_err() && !preserve_partial {
            let receive_directory = state.receive_directory.read().await.clone();
            if let Some(receive_directory) = receive_directory {
                tokio::fs::remove_file(receive_directory.join(format!("{transfer_id}.part")))
                    .await
                    .ok();
            }
        }
    }
    if let Err(error) = result {
        emit_transfer_error(
            &state.event_tx,
            active_transfer_id.as_deref().unwrap_or("incoming"),
            NetworkErrorCode::QuicError,
            "incoming file transfer failed".to_string(),
            "receive",
            Some(&peer_id),
        );
        tracing::debug!(peer_id = %peer_id, error = %error, "incoming native file transfer failed");
    }
}

/// 将 UI 审批决定应用到待处理直连传输。
pub(crate) async fn respond_to_incoming(
    state: &RuntimeState,
    response: RespondIncomingTransferCommand,
) -> Result<(), ProtocolError> {
    if let Some(sender) = state
        .incoming_decisions
        .write()
        .await
        .remove(&response.transfer_id)
    {
        return sender.send(response.accept).map_err(|_| {
            protocol_error(
                NetworkErrorCode::Cancelled,
                "incoming transfer approval expired",
            )
        });
    }
    crate::relay::respond_to_relay_incoming(state, &response.transfer_id, response.accept).await
}

/// 将流 worker 的有界传输进度转发为事件。
async fn forward_progress(
    transfer_id: String,
    mut progress: UnboundedReceiver<(u64, u64)>,
    event_tx: tokio::sync::mpsc::UnboundedSender<network_protocol::NetworkEvent>,
    manager: TransferManager,
) {
    while let Some((bytes_transferred, total_bytes)) = progress.recv().await {
        manager
            .update_progress(&transfer_id, bytes_transferred)
            .await;
        emit_transfer_progress(&event_tx, &transfer_id, bytes_transferred, total_bytes);
    }
}

/// 区分可通过新 Connection 恢复的 transport 失败与 manifest/审批/校验失败。
fn is_transient_transport_error(error: &(dyn Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
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
        if let Some(error) = error.downcast_ref::<quinn::ConnectionError>() {
            if matches!(
                error,
                quinn::ConnectionError::TransportError(_)
                    | quinn::ConnectionError::ConnectionClosed(_)
                    | quinn::ConnectionError::ApplicationClosed(_)
                    | quinn::ConnectionError::Reset
                    | quinn::ConnectionError::TimedOut
            ) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

/// 将传输专属命令分发到所属传输子系统。
pub(crate) async fn dispatch_transfer_command(
    state: Arc<RuntimeState>,
    command: NetworkCommand,
) -> Result<(), ProtocolError> {
    match command.payload {
        Some(network_protocol::network_command::Payload::SendFile(send)) => {
            start_file_send(state, send).await
        }
        Some(network_protocol::network_command::Payload::CancelTransfer(cancel)) => {
            if state.transfers.cancel_transfer(&cancel.transfer_id).await {
                Ok(())
            } else {
                Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "transfer is not active",
                ))
            }
        }
        Some(network_protocol::network_command::Payload::RespondIncomingTransfer(response)) => {
            respond_to_incoming(&state, response).await
        }
        _ => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "unsupported transfer command",
        )),
    }
}
