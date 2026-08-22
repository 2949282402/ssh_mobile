use super::*;

/// 验证 Relay offer 只接受完整的 SHA-256 十六进制摘要。
#[test]
fn relay_offer_requires_sha256_hash() {
    let digest = hex::encode(Sha256::digest(b"relay-V2"));
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
        .relay
        .credential_stale
        .store(true, std::sync::atomic::Ordering::Release);
    schedule_relay_reconnect(Arc::clone(&state));
    assert!(!state
        .relay
        .reconnect_active
        .load(std::sync::atomic::Ordering::Acquire));
    assert!(state.relay.reconnect_task.lock().unwrap().is_none());
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
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    // 快速失败的 loopback 端点：重连循环会立刻尝试 setup_v2_control_plane，
    // 而不是卡在 relay_control 守卫上。URL 必须是无路径的 origin。
    *state.relay.config.write().await = Some(RelayReconnectConfig {
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
    *state.relay.control.write().await = Some(dead_control.clone());

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
        state.relay.control.read().await.is_none(),
        "unexpected disconnect must clear the control-plane slot"
    );
    assert!(
        state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "reconnect must be scheduled after an unexpected disconnect"
    );
    // 等待超过首个退避周期：重连循环必须仍在重试（setup 反复执行），而不是在
    // relay_control 守卫处立即退出。
    tokio::time::sleep(std::time::Duration::from_millis(600)).await;
    assert!(
        state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "reconnect loop must keep retrying instead of breaking on the stale control slot"
    );
}

#[tokio::test]
async fn remote_candidate_cache_invalidates_on_epoch_and_ready_ttl_change() {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let cache = network_nat::ResolvedCandidateCache::from_snapshot(
        network_nat::ResolvedCandidateSnapshot {
            runtime_epoch: NatRuntimeEpoch { high: 1, low: 1 },
            revision: 1,
            candidates: vec![network_nat::CandidatePayloadV2 {
                version: network_nat::CANDIDATE_PAYLOAD_VERSION,
                candidate_id: "lan-1".into(),
                endpoint: std::net::SocketAddr::from(([192, 168, 1, 10], 41001)),
                kind: network_nat::CandidateKind::Lan,
                transport_capabilities: vec![network_nat::CandidateTransport::Quic],
                priority: 100,
                interface: "wifi".into(),
                generation: 1,
            }],
            server_presence_ttl: Some(Duration::from_secs(60)),
        },
        Instant::now(),
    )
    .expect("valid candidate cache");
    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-a".into(), cache.clone());

    let control = Arc::new(
        RelayControlClient::new(
            "ws://127.0.0.1:9".into(),
            "device-a".into(),
            "credential".into(),
            [0u8; 32],
        )
        .expect("control client"),
    );
    let (events_tx, events_rx) = mpsc::channel(1);
    let consumer_state = Arc::clone(&state);
    let consumer = tokio::spawn(async move {
        consume_control_events(consumer_state, control, events_rx).await;
    });
    events_tx
        .send(ControlEvent::PeerAvailableHint(
            network_relay::v2::PeerAvailableHint {
                device_id: "peer-a".into(),
                runtime_epoch: Some(RuntimeEpoch { high: 2, low: 1 }),
                revision: 2,
            },
        ))
        .await
        .expect("send available hint");
    drop(events_tx);
    consumer.await.expect("control event consumer");
    assert!(state
        .remote_candidate_cache
        .read()
        .await
        .get("peer-a")
        .expect("cache entry")
        .stage_a_candidates_at(Instant::now())
        .is_none());

    state
        .remote_candidate_cache
        .write()
        .await
        .insert("peer-b".into(), cache);
    clear_remote_candidate_cache_if_ready_ttl_changed(
        &state,
        Some(Duration::from_secs(60)),
        Some(Duration::from_secs(30)),
    )
    .await;
    assert!(state.remote_candidate_cache.read().await.is_empty());
}

/// 回归 #2：关闭一条 reservation 数据连接只移除该对端的物理 Relay path，
/// 另一对端的活跃数据连接必须原样保留。
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
    let session_b = match state
        .begin_connect("peer-b", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected peer-b session decision: {decision:?}"),
    };
    let session_c = match state
        .begin_connect("peer-c", crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        crate::runtime::ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected peer-c session decision: {decision:?}"),
    };
    assert!(
        state
            .mark_relay_route_connected("peer-b", session_b, Some(data_b.clone()))
            .await
    );
    assert!(
        state
            .mark_relay_route_connected("peer-c", session_c, Some(data_c.clone()))
            .await
    );

    relay_data_disconnected(Arc::clone(&state), data_b, "peer-b".into()).await;

    assert!(
        state
            .path_relay_data("peer-c")
            .await
            .is_some_and(|current| Arc::ptr_eq(&current, &data_c)),
        "peer-c data connection must survive peer-b disconnecting"
    );
    assert!(
        state.path_relay_data("peer-b").await.is_none(),
        "only the disconnected peer's path must be removed"
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
    state.lifecycle.identity.write().await.replace(Arc::new(
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
            .relay
            .credential_stale
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
    state.lifecycle.identity.write().await.replace(Arc::new(
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
            .relay
            .credential_stale
            .load(std::sync::atomic::Ordering::Acquire),
        "expired credential must mark the credential stale"
    );
    assert!(
        !state
            .relay
            .reconnect_active
            .load(std::sync::atomic::Ordering::Acquire),
        "expired credential must stop scheduling reconnects"
    );
    assert!(
        state.relay.reconnect_task.lock().unwrap().is_none(),
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
            .transfer
            .manager
            .register_incoming(manifest_b.clone(), "peer-b".into())
            .await
    );
    assert!(
        state
            .transfer
            .manager
            .register_incoming(manifest_c.clone(), "peer-c".into())
            .await
    );
    state.relay.active_incoming.lock().await.insert(
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
    state.relay.active_incoming.lock().await.insert(
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
        .relay
        .acceptances
        .write()
        .await
        .insert("relay-transfer-b".into(), oneshot::channel().0);
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("relay-transfer-c".into(), oneshot::channel().0);
    state
        .relay
        .completions
        .write()
        .await
        .insert("relay-transfer-b".into(), oneshot::channel().0);
    state
        .relay
        .completions
        .write()
        .await
        .insert("relay-transfer-c".into(), oneshot::channel().0);
    let (wait_b, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
    let (wait_c, _) = mpsc::channel::<(u8, Vec<u8>)>(1);
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .insert(relay_crypto_key("peer-b", "token-b"), wait_b);
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .insert(relay_crypto_key("peer-c", "token-c"), wait_c);

    // peer-b 断开：只清理 peer-b 的条目，peer-c 的全部保留。
    cleanup_relay_state(&state, Some("peer-b")).await;

    assert!(
        state
            .relay
            .active_incoming
            .lock()
            .await
            .contains_key("relay-transfer-c"),
        "peer-c active incoming must survive peer-b disconnecting"
    );
    assert!(!state
        .relay
        .active_incoming
        .lock()
        .await
        .contains_key("relay-transfer-b"));
    assert!(state
        .relay
        .acceptances
        .read()
        .await
        .contains_key("relay-transfer-c"));
    assert!(!state
        .relay
        .acceptances
        .read()
        .await
        .contains_key("relay-transfer-b"));
    assert!(state
        .relay
        .completions
        .read()
        .await
        .contains_key("relay-transfer-c"));
    assert!(!state
        .relay
        .completions
        .read()
        .await
        .contains_key("relay-transfer-b"));
    assert!(
        state
            .relay
            .crypto_waiters
            .read()
            .await
            .contains_key(&relay_crypto_key("peer-c", "token-c")),
        "peer-c crypto waiter must survive peer-b disconnecting"
    );
    assert!(!state
        .relay
        .crypto_waiters
        .read()
        .await
        .contains_key(&relay_crypto_key("peer-b", "token-b")));
    // peer-c 的接收传输未被暂停；peer-b 的被暂停（保留 checkpoint）。
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot("relay-transfer-c")
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::WaitingApproval
    );
    assert_eq!(
        state
            .transfer
            .manager
            .snapshot("relay-transfer-b")
            .await
            .unwrap()
            .state,
        network_transfer::TransferState::Paused
    );

    // 全部断开（disconnect_relay_data 路径）仍清理所有对端的路径。
    cleanup_relay_state(&state, None).await;
    assert!(state.relay.active_incoming.lock().await.is_empty());
    assert!(state.relay.acceptances.read().await.is_empty());
    assert!(state.relay.completions.read().await.is_empty());
    assert!(state.relay.crypto_waiters.read().await.is_empty());
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
            e2ee_policy: network_protocol::E2eePolicy::Required,
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
    state
        .lifecycle
        .identity
        .write()
        .await
        .replace(Arc::new(receiver));

    receive_relay_offer(&state, &data, "sender", &first_envelope)
        .await
        .expect("first offer is accepted for approval");
    assert_eq!(
        state
            .transfer
            .manager
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
            .transfer
            .manager
            .snapshot("relay-reoffer-transfer")
            .await
            .is_none(),
        "timed-out transfer must be removed so the transfer_id can be reused"
    );
    assert!(state.relay.pending_incoming.read().await.is_empty());

    // 同一 transfer_id 的新 Offer（新 session_id）必须能被接受，不得报 already active。
    receive_relay_offer(&state, &data, "sender", &second_envelope)
        .await
        .expect("second offer of the same transfer_id is accepted after timeout");
}
