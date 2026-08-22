// Relay v2 data-plane envelopes, E2EE admission, and message/stream routing.
use super::*;

/// 封装并发送一个数据面信封（sequence=0；文件分块单独使用真实序号）。
pub(super) async fn send_data_envelope(
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
pub(super) async fn send_data_envelope_with_token(
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
pub(super) fn decode_token_envelope(envelope: &[u8]) -> Result<(&str, &[u8]), RelayError> {
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

/// 应答方收到 `IncomingRelayReservation` 后连接数据面并启动事件循环。
pub(super) async fn connect_incoming_relay_data(
    state: &Arc<RuntimeState>,
    reservation: network_relay::v2::IncomingRelayReservation,
) {
    let Some(config) = state.relay.config.read().await.clone() else {
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
    // A newly paired reservation must pass through Noise/E2EE before any
    // business envelope is admitted.  Clear the peer-level projection before
    // replacing the reservation so a stale data client cannot open this one.
    state.relay.relay_path_ready.write().await.remove(&peer_id);
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
    let config = state.relay.config.read().await.clone().ok_or_else(|| {
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
    // PairReady belongs to this reservation.  Do not let readiness from a
    // previous reservation authorize business data on the new data client.
    state.relay.relay_path_ready.write().await.remove(peer_id);
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
pub(super) async fn handle_relay_data_events(
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
pub(super) async fn handle_relay_data_payload(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    peer_id: &str,
    envelope: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let Some((&kind, body)) = envelope.split_first() else {
        return Err(std::io::Error::other("relay data envelope is empty").into());
    };
    if kind != DATA_ENV_CRYPTO && !state.relay.relay_path_ready.read().await.contains(peer_id) {
        return Err(std::io::Error::other(
            "Relay Session admission is not complete; business envelope rejected",
        )
        .into());
    }
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
                .relay
                .acceptances
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
            if let Some(sender) = state.relay.completions.write().await.remove(&transfer_id) {
                let _ = sender.send(true);
            }
            Ok(())
        }
        DATA_ENV_FILE_CANCEL => {
            let transfer_id = std::str::from_utf8(body)?.to_string();
            if let Some(sender) = state.relay.acceptances.write().await.remove(&transfer_id) {
                let _ = sender.send(None);
            }
            if let Some(sender) = state.relay.completions.write().await.remove(&transfer_id) {
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
pub(super) async fn relay_data_disconnected(
    state: Arc<RuntimeState>,
    data: Arc<RelayDataClient>,
    peer_id: String,
) {
    // The PhysicalRoute is the sole owner of an admitted Relay data client.
    // A close event from a pre-admission/stale client must not tear down a
    // different current route.
    if !state.path_is_current_relay_data(&peer_id, &data).await {
        return;
    }
    // 只清理断开对端的 Relay 状态；其他对端的在途传输原样保留。
    cleanup_relay_state(&state, Some(&peer_id)).await;
    // §18/§35：transport 丢失即销毁 ConnectionSession（Relay route 由其数据客户端
    // 断开驱动）。显式 close 会 emit Disconnected。
    crate::peer::teardown_relay_route(&state, &peer_id, &data).await;
}

pub(super) fn relay_crypto_key(peer_id: &str, session_token: &str) -> String {
    format!("{peer_id}/{session_token}")
}

/// 处理一条数据面 crypto 信封（应答方或等待中的发起方）。
pub(super) async fn handle_relay_crypto_handshake(
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
    if state.e2ee_policy(peer_id).await
        != crate::crypto_handshake::path_handshake::E2eePolicy::Required
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay paths require application E2EE",
        )
        .into());
    }
    let key = relay_crypto_key(peer_id, session_token);
    let (step, payload) = crate::crypto_handshake::decode_relay_frame(frame_bytes)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    match step {
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE
        | crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED
        | crate::crypto_handshake::RELAY_CRYPTO_ACCEPT => {
            let sender = state
                .relay
                .crypto_waiters
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
            state.relay.crypto_confirmers.lock().await.remove(&key);
            let identity = state
                .lifecycle
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
            let mut responders = state.relay.crypto_responders.lock().await;
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
                .relay
                .crypto_responders
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
                                .admit_authenticated_session_with_capability(
                                    &authenticated_peer_id,
                                    None,
                                    &remote_session_binding,
                                    crate::connect::DEFAULT_CONNECTION_CAPABILITY,
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
            let mut confirmers = state.relay.crypto_confirmers.lock().await;
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
                .relay
                .crypto_confirmers
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
            // Root/Accept is the complete authenticated Relay admission
            // boundary.  PathHandshakeV2 metadata/proof was already bound to
            // this Noise transcript; no pending responder or second frame is
            // allowed to become a business gate.
            complete_relay_admission(state, data, session_token, peer_id, material, admission)
                .await?;
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

/// Commits the responder after the authenticated Noise Root/Accept exchange.
/// The reservation PairReady gate is owned by RelayDataClient; PathHandshakeV2
/// metadata/proof is transcript-bound inside Noise and never creates a second
/// pending responder or business admission queue.
pub(super) async fn complete_relay_admission(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
    session_token: &str,
    peer_id: &str,
    material: SessionCryptoMaterial,
    admission: ConnectionAdmissionLease,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let session_id = admission.session_id;
    if state.e2ee_policy(peer_id).await
        != crate::crypto_handshake::path_handshake::E2eePolicy::Required
        || material.e2ee_policy != crate::crypto_handshake::path_handshake::E2eePolicy::Required
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay application E2EE policy is not Required",
        )
        .into());
    }
    if material.local_session_binding != session_id.wire_key()
        || material.remote_session_binding != session_token
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay E2EE Session/token binding is invalid",
        )
        .into());
    }
    let relay_profile = crate::connection::ConnectionProfile::for_route(RouteType::Relay)
        .expect("Relay route has a composed profile");
    if !state
        .candidate_supports(
            peer_id,
            session_id,
            relay_profile,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        )
        .await
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::other(
            "Relay route no longer satisfies the requested capability",
        )
        .into());
    }
    if state
        .connection_sessions
        .finalize_authenticated_session(peer_id, session_id, &material.remote_session_binding)
        .await
        .is_err()
    {
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::other(
            "Relay Session admission became stale before route commit",
        )
        .into());
    }
    crate::peer::install_admitted_crypto(state, peer_id, &admission, &material).await?;
    if !state
        .mark_relay_route_connected(peer_id, session_id, Some(Arc::clone(data)))
        .await
    {
        state.crypto.remove_session(peer_id, &session_id.wire_key());
        state.fail_session(peer_id, session_id).await;
        return Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "Relay Session was closed before route commit",
        )
        .into());
    }
    state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert(peer_id.to_string());
    crate::events::emit_peer_state(
        &state.event_tx,
        peer_id,
        network_protocol::PeerConnectionState::Connected,
        RouteType::Relay,
        None,
    );
    crate::channel::recover_session(Arc::clone(state), peer_id.to_string()).await;
    // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
    Arc::clone(state)
        .resume_transfers_for_peer(peer_id.to_string())
        .await;
    Ok(())
}

/// 发送一条已编码的 crypto 帧（data 侧加 token 前缀）。
pub(super) async fn send_relay_crypto_raw(
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
pub(super) async fn receive_relay_channel_message(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
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
                    crate::stream::InboundPath::Relay(Arc::clone(data)),
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
pub(super) async fn receive_relay_stream_frame(
    state: &Arc<RuntimeState>,
    data: &Arc<RelayDataClient>,
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
    crate::stream::handle_inbound_stream_frame(
        state,
        peer_id,
        frame.kind,
        &frame.payload,
        crate::stream::InboundPath::Relay(Arc::clone(data)),
    )
    .await
    .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string()))?;
    Ok(())
}

pub(super) async fn receive_relay_delivery_ack(
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
pub(super) async fn cleanup_relay_state(state: &RuntimeState, peer: Option<&str>) {
    // relay_active_incoming：按 offer.sender_id 只暂停断开对端的接收传输，其余对端
    // 的活跃接收保持原样。
    let active_ids = {
        let active = state.relay.active_incoming.lock().await;
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
            .relay
            .active_incoming
            .lock()
            .await
            .remove(&transfer_id);
        if let Some(incoming) = incoming {
            drop(incoming.file);
            if state.transfer.manager.pause_for_network(&transfer_id).await {
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
        ids.extend(state.relay.acceptances.read().await.keys().cloned());
        ids.extend(state.relay.completions.read().await.keys().cloned());
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
                .transfer
                .manager
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
        state.relay.acceptances.write().await.remove(transfer_id);
        state.relay.completions.write().await.remove(transfer_id);
    }

    // crypto waiters/responders/confirmers 的键是 "{peer_id}/{token}"：按对端前缀清理。
    let crypto_prefix = peer.map(|peer| format!("{peer}/"));
    {
        let mut waiters = state.relay.crypto_waiters.write().await;
        if let Some(prefix) = &crypto_prefix {
            waiters.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            waiters.clear();
        }
    }
    {
        let mut responders = state.relay.crypto_responders.lock().await;
        if let Some(prefix) = &crypto_prefix {
            responders.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            responders.clear();
        }
    }
    {
        let mut confirmers = state.relay.crypto_confirmers.lock().await;
        if let Some(prefix) = &crypto_prefix {
            confirmers.retain(|key, _| !key.starts_with(prefix.as_str()));
        } else {
            confirmers.clear();
        }
    }
    if let Some(peer) = peer {
        state.relay.relay_path_ready.write().await.remove(peer);
    } else {
        state.relay.relay_path_ready.write().await.clear();
    }
}
