// Relay v2 control-plane, discovery, and reconnect ownership.
use super::*;

/// 连接原生 Relay v2 控制面并启动事件消费者（§31 `RelayControlClient`）。
pub(crate) async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    stop_relay_reconnect_task(&state).await;
    // 新的 ConfigureRelayCommand 携带新凭据，重置过期标记并清空旧配置。
    state
        .relay
        .credential_stale
        .store(false, std::sync::atomic::Ordering::Release);
    state.relay.config.write().await.take();
    disconnect_relay_data(state.as_ref()).await;
    let device_id = state
        .lifecycle
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
    *state.relay.config.write().await = Some(config.clone());
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
    Arc::clone(&state).resume_relay_transfers().await;
    Ok(())
}

/// transport-network v2：建立 `/v2/control` 控制面客户端并启动事件消费者。
///
/// 失败时返回类型化错误。凭据过期/身份冲突是终态错误：标记 `relay_credential_stale`
/// 并停止重连（现有 stale 守卫随后生效），等待 Dart 下发新 ConfigureRelayCommand 后
/// 恢复；其余传输错误仍走既有退避重连。
pub(super) async fn setup_v2_control_plane(
    state: &Arc<RuntimeState>,
    device_id: &str,
    config: &RelayReconnectConfig,
) -> Result<(), ProtocolError> {
    let previous_ready_presence_ttl = state
        .relay
        .control
        .read()
        .await
        .as_ref()
        .and_then(|control| control.ready_presence_ttl());
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
                .relay
                .credential_stale
                .store(true, std::sync::atomic::Ordering::Release);
        } else {
            schedule_relay_reconnect(Arc::clone(state));
        }
        return Err(relay_connect_protocol_error(&error, "setup_control_plane"));
    }
    let ready_presence_ttl = control.ready_presence_ttl();
    clear_remote_candidate_cache_if_ready_ttl_changed(
        state,
        previous_ready_presence_ttl,
        ready_presence_ttl,
    )
    .await;
    let events = control.take_events().map_err(|error| {
        tracing::warn!(error = %error, "Relay v2 control events were already consumed");
        relay_connect_protocol_error(&error, "setup_control_plane")
    })?;
    let control = Arc::new(control);
    *state.relay.control.write().await = Some(control.clone());
    let supervisor = Arc::clone(&state.task_supervisor);
    let state = Arc::clone(state);
    let _ = supervisor.spawn_runtime("relay-v2-control-events", async move {
        consume_control_events(state, control, events).await;
    });
    Ok(())
}

/// 消费 Relay v2 控制面异步事件（presence hints / inbound ConnectivityOffer /
/// IncomingRelayReservation / RealtimeSignal / Disconnected）。
pub(super) async fn consume_control_events(
    state: Arc<RuntimeState>,
    control: Arc<RelayControlClient>,
    mut events: mpsc::Receiver<ControlEvent>,
) {
    while let Some(event) = events.recv().await {
        match event {
            ControlEvent::PresenceHintSnapshot(snapshot) => {
                for peer in &snapshot.peers {
                    if peer.online && peer.revision != 0 {
                        if let Some(epoch) = peer.runtime_epoch.as_ref() {
                            invalidate_remote_candidate_cache_for_epoch(
                                &state,
                                &peer.device_id,
                                epoch,
                            )
                            .await;
                        }
                    }
                }
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
                if hint.revision != 0 {
                    if let Some(epoch) = hint.runtime_epoch.as_ref() {
                        invalidate_remote_candidate_cache_for_epoch(&state, &hint.device_id, epoch)
                            .await;
                    } else {
                        tracing::debug!(
                            peer_id = %hint.device_id,
                            revision = hint.revision,
                            "ignored available hint without runtime_epoch for candidate invalidation"
                        );
                    }
                } else {
                    tracing::debug!(
                        peer_id = %hint.device_id,
                        "ignored available hint with zero revision for candidate invalidation"
                    );
                }
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
                if let Some(identity) = state.lifecycle.identity.read().await.clone() {
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
                        realtime_id = %signal.realtime_id,
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
                state.relay.control.write().await.take();
                schedule_relay_reconnect(Arc::clone(&state));
                break;
            }
            _ => {}
        }
    }
}

/// A Ready frame is the authority for the candidate-cache freshness window.
/// When a control reconnect reports a different server-confirmed TTL, entries
/// learned under the previous control lease must not remain eligible for Stage
/// A. They are rebuilt by the next authoritative Resolve/Answer snapshot.
pub(super) async fn clear_remote_candidate_cache_if_ready_ttl_changed(
    state: &RuntimeState,
    previous_ttl: Option<Duration>,
    current_ttl: Option<Duration>,
) {
    if previous_ttl == current_ttl {
        return;
    }
    let mut cache = state.remote_candidate_cache.write().await;
    if !cache.is_empty() {
        tracing::debug!(
            ?previous_ttl,
            ?current_ttl,
            entries = cache.len(),
            "clearing remote candidate cache after Relay Ready TTL change"
        );
        cache.clear();
    }
}

/// Apply the server-advertised runtime epoch to the real per-peer candidate
/// cache. Presence remains UI-only; the epoch carried by the v2 hint is the
/// explicit invalidation signal for the old remote discovery snapshot.
pub(super) async fn invalidate_remote_candidate_cache_for_epoch(
    state: &RuntimeState,
    peer_id: &str,
    epoch: &RuntimeEpoch,
) {
    if epoch.high == 0 && epoch.low == 0 {
        tracing::debug!(
            peer_id = %peer_id,
            "ignored available hint with zero runtime_epoch for candidate invalidation"
        );
        return;
    }
    let remote_epoch = NatRuntimeEpoch {
        high: epoch.high,
        low: epoch.low,
    };
    let mut cache = state.remote_candidate_cache.write().await;
    let Some(entry) = cache.get_mut(peer_id) else {
        return;
    };
    if entry.invalidate_for_remote_epoch(remote_epoch, Instant::now()) {
        tracing::debug!(
            peer_id = %peer_id,
            runtime_epoch_high = epoch.high,
            runtime_epoch_low = epoch.low,
            "invalidated remote candidate cache for new runtime epoch"
        );
    }
}

/// Starts the responder half of a one-shot connectivity attempt. The
/// initiator's snapshot is copied into an attempt-scoped candidate set; no
/// candidate is written to PathManager or reused by a later attempt.
pub(super) fn spawn_responder_connectivity_checks(
    state: Arc<RuntimeState>,
    offer: ConnectivityOffer,
) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_runtime("connectivity-responder-checks", async move {
        let peer_id = offer.initiator_device_id.clone();
        let peer = state.peers.read().await.get(&peer_id).cloned();
        let Some(peer) = peer else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "ignored offer for unconfigured peer");
            return;
        };
        if state
            .peer_route_authorizations
            .read()
            .await
            .get(&peer_id)
            .is_some_and(|authorization| !authorization.direct)
        {
            tracing::debug!(
                peer_id = %peer_id,
                attempt_id = %offer.attempt_id,
                "ignored connectivity offer without Direct route authorization"
            );
            return;
        }
        let endpoint = state.lifecycle.endpoint.read().await.clone();
        let Some(endpoint) = endpoint else {
            tracing::debug!(peer_id = %peer_id, attempt_id = %offer.attempt_id, "cannot run responder checks without endpoint");
            return;
        };
        let identity = state.lifecycle.identity.read().await.clone();
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
            .map(|manager| {
                let epoch = manager.runtime_epoch();
                NatRuntimeEpoch {
                    high: epoch.high,
                    low: epoch.low,
                }
            })
            .unwrap_or(NatRuntimeEpoch { high: 0, low: 0 });
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
                .map(|epoch| NatRuntimeEpoch {
                    high: epoch.high,
                    low: epoch.low,
                }),
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
                let attempt_coordinator =
                    crate::connect::ConnectivityAttemptCoordinator::new(state);
                if let Err(error) = attempt_coordinator
                    .attach_direct_route(&peer_id, route)
                    .await
                {
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

pub(super) fn connectivity_offer_candidates(offer: &ConnectivityOffer) -> Vec<Candidate> {
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
pub(super) async fn local_discovery_tuple(
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
    state.relay.config.write().await.take();
    disconnect_relay_data(state).await;
    state.relay.control.write().await.take();
    crate::events::emit_relay_state(
        &state.event_tx,
        network_protocol::RelayConnectionState::Disconnected,
        None,
    );
    Ok(())
}

/// 取走并断开全部 reservation 数据面客户端。
pub(super) async fn disconnect_relay_data(state: &RuntimeState) {
    state.close_all_relay_paths().await;
    // 断开全部 reservation：清理所有对端的 Relay 状态。
    cleanup_relay_state(state, None).await;
}

/// 只在控制面 socket 意外结束时启动一个共享重连任务；显式 DisconnectRelay 会先
/// 清除配置，因此不会被这个后台任务重新拉起。
pub(super) fn schedule_relay_reconnect(state: Arc<RuntimeState>) {
    if state
        .relay
        .reconnect_active
        .swap(true, std::sync::atomic::Ordering::AcqRel)
    {
        return;
    }
    if state
        .relay
        .credential_stale
        .load(std::sync::atomic::Ordering::Acquire)
    {
        // 凭据已被判定过期/冲突，盲目重连只会复用失效凭据；等待 Dart 下发新的
        // ConfigureRelayCommand 后再恢复。
        state
            .relay
            .reconnect_active
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
                    .relay
                    .credential_stale
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    break;
                }
                let Some(config) = reconnect_state.relay.config.read().await.clone() else {
                    break;
                };
                let Some(device_id) = reconnect_state
                    .lifecycle
                    .identity
                    .read()
                    .await
                    .as_ref()
                    .map(|identity| identity.device_id.clone())
                else {
                    break;
                };
                if reconnect_state.relay.control.read().await.is_some() {
                    break;
                }
                reconnect_state.relay.control.write().await.take();
                match setup_v2_control_plane(&reconnect_state, &device_id, &config).await {
                    Ok(()) => {
                        crate::discovery::spawn_control_connected(&reconnect_state);
                        crate::events::emit_relay_state(
                            &reconnect_state.event_tx,
                            network_protocol::RelayConnectionState::Connected,
                            None,
                        );
                        Arc::clone(&reconnect_state).resume_relay_transfers().await;
                        break;
                    }
                    Err(error)
                        if reconnect_state
                            .relay
                            .credential_stale
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
                .relay
                .reconnect_active
                .store(false, std::sync::atomic::Ordering::Release);
            if let Ok(mut task) = reconnect_state.relay.reconnect_task.lock() {
                task.take();
            }
        });
    if let Some(task_id) = task_id {
        if let Ok(mut task) = state.relay.reconnect_task.lock() {
            *task = Some(task_id);
        }
    } else {
        state
            .relay
            .reconnect_active
            .store(false, std::sync::atomic::Ordering::Release);
    }
}

pub(super) async fn stop_relay_reconnect_task(state: &RuntimeState) {
    state
        .relay
        .reconnect_active
        .store(false, std::sync::atomic::Ordering::Release);
    let task_id = state
        .relay
        .reconnect_task
        .lock()
        .ok()
        .and_then(|mut task| task.take());
    if let Some(task_id) = task_id {
        state.task_supervisor.cancel_task(task_id).await;
    }
}

/// 将 Relay connect 失败映射为类型化协议错误。凭据过期/身份冲突是终态错误，
/// 其余仍走通用的 Relay 传输错误。
pub(super) fn relay_connect_protocol_error(error: &RelayError, operation: &str) -> ProtocolError {
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
#[path = "tests/relay_control.rs"]
mod tests;
