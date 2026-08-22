use super::*;

use crate::connection::GenericFrameKind;
use network_protocol::{
    DataMessage, DeliveryAck, DeliveryPolicyCode, NetworkEvent, NETWORK_PROTOCOL_VERSION,
};
use network_relay::v2::DataEvent;
use std::sync::atomic::AtomicU16;
use tokio::sync::{mpsc, oneshot};

fn state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
}

fn data_client() -> RelayDataClient {
    RelayDataClient::new(
        "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        vec![0u8; 32],
        "credential".into(),
        [0u8; 32],
    )
    .expect("valid unconnected Relay data client")
}

#[tokio::test]
async fn data_envelope_helpers_validate_tokens_before_touching_socket() {
    let data = data_client();
    assert!(matches!(
        send_data_envelope(&data, DATA_ENV_CHANNEL, b"payload").await,
        Err(RelayError::NotConnected)
    ));

    for result in [
        send_data_envelope_with_token(&data, DATA_ENV_CHANNEL, "token", b"payload").await,
        send_relay_channel_message(&data, "token", b"payload").await,
        send_relay_channel_ack(&data, "token", b"payload").await,
        send_relay_stream_frame(&data, "token", b"payload").await,
    ] {
        assert!(matches!(result, Err(RelayError::NotConnected)));
    }

    let oversized = "x".repeat(256);
    for result in [
        send_data_envelope_with_token(&data, DATA_ENV_CHANNEL, &oversized, b"payload").await,
        send_relay_channel_message(&data, &oversized, b"payload").await,
        send_relay_channel_ack(&data, &oversized, b"payload").await,
        send_relay_stream_frame(&data, &oversized, b"payload").await,
    ] {
        assert!(matches!(result, Err(RelayError::InvalidConfiguration(_))));
    }

    let uppercase_token = "A".repeat(32);
    assert!(matches!(
        send_relay_crypto(&data, &uppercase_token, 1, b"hello").await,
        Err(RelayError::InvalidConfiguration(_))
    ));
    assert!(matches!(
        send_relay_crypto_raw(&data, &uppercase_token, b"frame").await,
        Err(RelayError::InvalidConfiguration(_))
    ));

    let valid_token = "a".repeat(32);
    assert!(matches!(
        send_relay_crypto(&data, &valid_token, 1, b"hello").await,
        Err(RelayError::NotConnected)
    ));
    assert!(matches!(
        send_relay_crypto_raw(&data, &valid_token, b"frame").await,
        Err(RelayError::NotConnected)
    ));
}

#[test]
fn token_envelope_decoder_covers_truncation_utf8_and_payload() {
    assert!(matches!(
        decode_token_envelope(&[]),
        Err(RelayError::Protocol(message)) if message.contains("truncated")
    ));
    assert!(matches!(
        decode_token_envelope(&[3, b'a']),
        Err(RelayError::Protocol(message)) if message.contains("token is truncated")
    ));
    assert!(matches!(
        decode_token_envelope(&[1, 0xff]),
        Err(RelayError::Protocol(message)) if message.contains("UTF-8")
    ));
    assert_eq!(
        decode_token_envelope(&[3, b'a', b'b', b'c', 9, 8]).expect("valid token envelope"),
        ("abc", &[9, 8][..])
    );
    assert_eq!(relay_crypto_key("peer-a", "token-a"), "peer-a/token-a");
}

#[tokio::test]
async fn relay_payload_gate_and_control_ack_paths_fail_closed() {
    let state = state();
    let data = Arc::new(data_client());

    let error = handle_relay_data_payload(&state, &data, "peer-a", &[])
        .await
        .expect_err("empty envelope must fail");
    assert!(error.to_string().contains("empty"));

    let error = handle_relay_data_payload(&state, &data, "peer-a", &[DATA_ENV_FILE_CANCEL, b'x'])
        .await
        .expect_err("business payload before admission must fail");
    assert!(error.to_string().contains("admission"));

    state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert("peer-a".into());
    let error = handle_relay_data_payload(&state, &data, "peer-a", &[0xfe, 1, 2])
        .await
        .expect_err("unknown envelope kind must fail");
    assert!(error.to_string().contains("unknown"));

    let mut short_crypto = vec![DATA_ENV_CRYPTO];
    short_crypto.extend_from_slice(&[0u8; 31]);
    let error = handle_relay_data_payload(&state, &data, "peer-a", &short_crypto)
        .await
        .expect_err("short crypto envelope must fail");
    assert!(error.to_string().contains("crypto envelope"));

    let error =
        handle_relay_data_payload(&state, &data, "peer-a", &[DATA_ENV_FILE_ACCEPT, b'{', b'"'])
            .await
            .expect_err("malformed acceptance must fail");
    assert!(error.to_string().contains("EOF") || error.to_string().contains("expected"));

    let (ack_tx, ack_rx) = oneshot::channel();
    state
        .relay
        .completions
        .write()
        .await
        .insert("transfer-ack".into(), ack_tx);
    let mut complete_ack = vec![DATA_ENV_FILE_COMPLETE_ACK];
    complete_ack.extend_from_slice(b"transfer-ack");
    handle_relay_data_payload(&state, &data, "peer-a", &complete_ack)
        .await
        .expect("completion ACK should route to its waiter");
    assert!(ack_rx.await.expect("completion ACK waiter"));

    let (accept_tx, accept_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("transfer-accept".into(), accept_tx);
    let acceptance = serde_json::json!({
        "v": 1,
        "transfer_id": "transfer-accept",
        "manifest_hash": "a".repeat(64),
        "file_hash": "b".repeat(64),
        "offset": 0,
    });
    let mut accept_frame = vec![DATA_ENV_FILE_ACCEPT];
    accept_frame.extend_from_slice(serde_json::to_string(&acceptance).unwrap().as_bytes());
    handle_relay_data_payload(&state, &data, "peer-a", &accept_frame)
        .await
        .expect("file acceptance should route to its waiter");
    assert_eq!(
        accept_rx
            .await
            .expect("acceptance waiter")
            .unwrap()
            .transfer_id,
        "transfer-accept"
    );

    let (cancel_accept_tx, cancel_accept_rx) = oneshot::channel();
    let (cancel_complete_tx, cancel_complete_rx) = oneshot::channel();
    state
        .relay
        .acceptances
        .write()
        .await
        .insert("transfer-cancel".into(), cancel_accept_tx);
    state
        .relay
        .completions
        .write()
        .await
        .insert("transfer-cancel".into(), cancel_complete_tx);
    let mut cancel_frame = vec![DATA_ENV_FILE_CANCEL];
    cancel_frame.extend_from_slice(b"transfer-cancel");
    handle_relay_data_payload(&state, &data, "peer-a", &cancel_frame)
        .await
        .expect("cancel should clean up waiters");
    assert!(cancel_accept_rx
        .await
        .expect("cancel acceptance waiter")
        .is_none());
    assert!(!cancel_complete_rx.await.expect("cancel completion waiter"));
}

#[tokio::test]
async fn relay_crypto_payload_rejects_unregistered_peer_before_decoding() {
    let state = state();
    let data = Arc::new(data_client());
    let mut frame = vec![DATA_ENV_CRYPTO];
    frame.extend_from_slice(&[b'a'; 32]);
    frame.extend_from_slice(&[0xff, 0xff]);
    let error = handle_relay_data_payload(&state, &data, "unknown-peer", &frame)
        .await
        .expect_err("crypto handshake must require a configured peer");
    assert!(error.to_string().contains("registered peer"));
}

#[tokio::test]
async fn relay_event_consumer_handles_ack_payload_and_both_close_modes() {
    for terminal in [
        DataEvent::Close {
            reason: 7,
            detail: "closed by test".into(),
        },
        DataEvent::Disconnected {
            reason: "socket lost".into(),
        },
    ] {
        let state = state();
        let data = Arc::new(data_client());
        let (events_tx, events_rx) = mpsc::channel(4);
        events_tx
            .send(DataEvent::Ack { sequence: 3 })
            .await
            .unwrap();
        events_tx
            .send(DataEvent::Payload {
                sequence: 4,
                encrypted_payload: vec![0xff],
            })
            .await
            .unwrap();
        events_tx.send(terminal).await.unwrap();
        drop(events_tx);
        handle_relay_data_events(state, data, events_rx, "peer-a".into()).await;
    }
}

#[tokio::test]
async fn relay_business_payloads_bind_peer_tokens_and_stream_identity() {
    let state = state();
    let data = Arc::new(data_client());
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1u8; 32],
            e2e_public_key: [2u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );

    let message = DataMessage {
        session_id: "session-a".into(),
        channel_id: "channel-a".into(),
        message_id: vec![7u8; 16],
        sequence: 0,
        recovery_epoch: 0,
        policy: DeliveryPolicyCode::Acked as i32,
        payload: b"relay message".to_vec(),
    };
    let mut message_bytes = Vec::new();
    message.encode(&mut message_bytes).unwrap();
    let error = receive_relay_channel_message(
        &state,
        &data,
        "missing-peer",
        &hex::encode(&message.message_id),
        &message_bytes,
    )
    .await
    .expect_err("messages from unknown peers must be rejected");
    assert!(error.to_string().contains("registered peer"));

    let error =
        receive_relay_channel_message(&state, &data, "peer-a", "wrong-token", &message_bytes)
            .await
            .expect_err("Relay message token must bind MessageId");
    assert!(error.to_string().contains("MessageId"));

    let error = receive_relay_channel_message(
        &state,
        &data,
        "peer-a",
        &hex::encode(&message.message_id),
        &message_bytes,
    )
    .await
    .expect_err("a message without a current delivery session must fail closed");
    assert!(!error.to_string().is_empty());

    let ack = DeliveryAck {
        session_id: "session-a".into(),
        message_id: vec![9u8; 16],
        recovery_epoch: 1,
    };
    let mut ack_bytes = Vec::new();
    ack.encode(&mut ack_bytes).unwrap();
    let error = receive_relay_delivery_ack(&state, &data, "peer-a", "wrong-token", &ack_bytes)
        .await
        .expect_err("Relay ACK token must bind MessageId");
    assert!(error.to_string().contains("MessageId"));

    let open_payload = crate::stream::encode_stream_open_frame("peer-a", 7, "ssh")
        .expect("encode stream open frame");
    let mut stream_frame = b"SMGF".to_vec();
    stream_frame.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    stream_frame.push(GenericFrameKind::StreamOpen as u8);
    stream_frame.extend_from_slice(&(open_payload.len() as u32).to_be_bytes());
    stream_frame.extend_from_slice(&open_payload);

    let error =
        receive_relay_stream_frame(&state, &data, "peer-a", "wrong-stream-token", &stream_frame)
            .await
            .expect_err("Relay stream token must bind opener and stream ID");
    assert!(error.to_string().contains("stream token"));

    let error =
        receive_relay_channel_message(&state, &data, "peer-a", "wrong-stream-token", &stream_frame)
            .await
            .expect_err("generic Relay stream frames share the same token guard");
    assert!(error.to_string().contains("stream token"));

    let error = receive_relay_stream_frame(&state, &data, "peer-a", "stream:peer-a:7", b"bad")
        .await
        .expect_err("malformed generic stream frames must be rejected");
    assert!(!error.to_string().is_empty());

    let generic_frame = |kind: GenericFrameKind, body: &[u8]| {
        let mut frame = b"SMGF".to_vec();
        frame.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
        frame.push(kind as u8);
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(body);
        frame
    };
    let non_stream = generic_frame(GenericFrameKind::DataMessage, b"message");
    let error = receive_relay_stream_frame(&state, &data, "peer-a", "stream:peer-a:7", &non_stream)
        .await
        .expect_err("the stream envelope must reject non-stream generic frames");
    assert!(error.to_string().contains("stream frame"));

    let malformed_stream = generic_frame(GenericFrameKind::StreamOpen, &[1]);
    let error = receive_relay_stream_frame(
        &state,
        &data,
        "peer-a",
        "stream:peer-a:7",
        &malformed_stream,
    )
    .await
    .expect_err("the stream envelope must reject malformed stream payloads");
    assert!(!error.to_string().is_empty());
    let error = receive_relay_stream_frame(
        &state,
        &data,
        "missing-peer",
        "stream:peer-a:7",
        &malformed_stream,
    )
    .await
    .expect_err("Relay stream frames must require a registered peer");
    assert!(error.to_string().contains("registered peer"));
}

#[tokio::test]
async fn relay_file_envelopes_reject_truncation_utf8_and_unknown_waiters() {
    let state = state();
    let data = Arc::new(data_client());
    state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert("peer-a".into());

    for envelope in [
        vec![DATA_ENV_FILE_ACCEPT, 0xff],
        vec![DATA_ENV_FILE_COMPLETE, 0xff],
        vec![DATA_ENV_FILE_COMPLETE_ACK, 0xff],
        vec![DATA_ENV_FILE_CANCEL, 0xff],
    ] {
        let error = handle_relay_data_payload(&state, &data, "peer-a", &envelope)
            .await
            .expect_err("invalid UTF-8 file control bodies must fail");
        assert!(!error.to_string().is_empty());
    }

    let mut short_chunk = vec![DATA_ENV_FILE_CHUNK];
    short_chunk.extend_from_slice(&[0u8; 38]);
    let error = handle_relay_data_payload(&state, &data, "peer-a", &short_chunk)
        .await
        .expect_err("Relay chunk envelopes must carry session and sequence");
    assert!(error.to_string().contains("chunk envelope"));

    let mut valid_unknown_cancel = vec![DATA_ENV_FILE_CANCEL];
    valid_unknown_cancel.extend_from_slice(b"unknown-transfer");
    handle_relay_data_payload(&state, &data, "peer-a", &valid_unknown_cancel)
        .await
        .expect("cancelling an unknown transfer is idempotent");
}

#[tokio::test]
async fn relay_crypto_handshake_rejects_unbound_steps_and_policy_downgrades() {
    let state = state();
    let data = Arc::new(data_client());
    let token = "a".repeat(32);
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [3u8; 32],
            e2e_public_key: [4u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );

    let error = handle_relay_crypto_handshake(&state, &data, "short", "peer-a", &[1, 2])
        .await
        .expect_err("short crypto tokens must be rejected");
    assert!(error.to_string().contains("bound to a registered peer"));

    let error = handle_relay_crypto_handshake(&state, &data, &token, "missing-peer", &[1, 2])
        .await
        .expect_err("crypto handshake must be bound to the routed peer");
    assert!(error.to_string().contains("registered peer"));

    state
        .peers
        .write()
        .await
        .get_mut("peer-a")
        .unwrap()
        .e2ee_policy = network_protocol::E2eePolicy::Disabled;
    let response = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        b"response",
    )
    .unwrap();
    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &response)
        .await
        .expect_err("Relay application payloads cannot downgrade E2EE");
    assert!(error.to_string().contains("require application E2EE"));
    state
        .peers
        .write()
        .await
        .get_mut("peer-a")
        .unwrap()
        .e2ee_policy = network_protocol::E2eePolicy::Required;

    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &[0xff, 1])
        .await
        .expect_err("unsupported Relay handshake steps must fail closed");
    assert!(error.to_string().contains("invalid") || error.to_string().contains("Invalid"));

    let error = handle_relay_crypto_handshake(
        &state,
        &data,
        &token,
        "peer-a",
        &crate::crypto_handshake::encode_relay_frame(
            crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
            b"response",
        )
        .unwrap(),
    )
    .await
    .expect_err("a response without an active initiator must be rejected");
    assert!(error.to_string().contains("active initiator"));

    let final_frame = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_FINAL,
        b"final",
    )
    .unwrap();
    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &final_frame)
        .await
        .expect_err("a final frame without an active responder must be rejected");
    assert!(error.to_string().contains("active responder"));

    let confirm_frame = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
        b"confirm",
    )
    .unwrap();
    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &confirm_frame)
        .await
        .expect_err("a root confirm without an authenticated responder must be rejected");
    assert!(error.to_string().contains("authenticated responder"));

    let initiator = Arc::new(network_identity::DeviceIdentity::from_private_keys(
        "initiator".into(),
        [5u8; 32],
        [6u8; 32],
    ));
    let (_handshake, hello) =
        crate::crypto_handshake::RelayInitiatorHandshake::start(initiator, "0000000000000001")
            .expect("construct a valid Relay hello");
    let hello_frame = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_HELLO,
        &hello,
    )
    .unwrap();
    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &hello_frame)
        .await
        .expect_err("a responder without runtime identity must fail closed");
    assert!(error.to_string().contains("identity is unavailable"));
}

#[tokio::test]
async fn relay_crypto_hello_stages_a_responder_before_socket_failure() {
    let state = state();
    let data = Arc::new(data_client());
    let token = "a".repeat(32);
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [3u8; 32],
            e2e_public_key: [4u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("peer-a".into(), [5u8; 32], [6u8; 32]),
    ));
    let initiator = network_identity::DeviceIdentity::from_private_keys(
        "initiator".into(),
        [7u8; 32],
        [8u8; 32],
    );
    let (_handshake, hello) = crate::crypto_handshake::RelayInitiatorHandshake::start(
        Arc::new(initiator),
        "0000000000000001",
    )
    .expect("valid Relay hello");
    let frame = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_HELLO,
        &hello,
    )
    .expect("encoded hello");

    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &frame)
        .await
        .expect_err("the unconnected data client must fail after staging the responder");
    assert!(error.to_string().contains("not connected"));
    assert!(state
        .relay
        .crypto_responders
        .lock()
        .await
        .contains_key(&relay_crypto_key("peer-a", &token)));
}

#[tokio::test]
async fn relay_admission_checks_policy_binding_path_and_commits_current_route() {
    let data = Arc::new(data_client());
    let root_key = [17u8; 32];
    let make_state = || async {
        let state = state();
        state.peers.write().await.insert(
            "peer-a".into(),
            PeerConfig {
                endpoint: None,
                identity_public_key: [7u8; 32],
                e2e_public_key: [8u8; 32],
                e2ee_policy: network_protocol::E2eePolicy::Required,
            },
        );
        state
    };

    let state = make_state().await;
    let admission = state
        .admit_authenticated_session("peer-a", None, "remote-a")
        .await
        .expect("admit Relay Session");
    let material = SessionCryptoMaterial {
        root_key,
        local_session_binding: admission.session_id.wire_key(),
        remote_session_binding: "remote-a".into(),
        initiator: false,
        e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
        path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
    };
    assert!(
        state
            .connection_sessions
            .retire_session("peer-a", admission.session_id)
            .await
    );
    let error = complete_relay_admission(
        &state,
        &data,
        "remote-a",
        "peer-a",
        material.clone(),
        admission,
    )
    .await
    .expect_err("an admitted session without a current Relay path must fail");
    assert!(error.to_string().contains("capability"));

    let mismatch_state = make_state().await;
    let mismatch_admission = mismatch_state
        .admit_authenticated_session("peer-a", None, "remote-b")
        .await
        .expect("admit mismatch Session");
    let mut mismatch_material = material.clone();
    mismatch_material.local_session_binding = mismatch_admission.session_id.wire_key();
    mismatch_material.remote_session_binding = "remote-b".into();
    let error = complete_relay_admission(
        &mismatch_state,
        &data,
        "different-token",
        "peer-a",
        mismatch_material,
        mismatch_admission,
    )
    .await
    .expect_err("a Relay token must match the Noise session binding");
    assert!(error.to_string().contains("binding"));

    let disabled_state = make_state().await;
    disabled_state
        .peers
        .write()
        .await
        .get_mut("peer-a")
        .unwrap()
        .e2ee_policy = network_protocol::E2eePolicy::Disabled;
    let disabled_admission = disabled_state
        .admit_authenticated_session("peer-a", None, "remote-c")
        .await
        .expect("admit disabled-policy Session");
    let mut disabled_material = material.clone();
    disabled_material.local_session_binding = disabled_admission.session_id.wire_key();
    disabled_material.remote_session_binding = "remote-c".into();
    let error = complete_relay_admission(
        &disabled_state,
        &data,
        "remote-c",
        "peer-a",
        disabled_material,
        disabled_admission,
    )
    .await
    .expect_err("Relay admission must not downgrade the configured E2EE policy");
    assert!(error.to_string().contains("policy"));

    let commit_state = make_state().await;
    let commit_admission = commit_state
        .admit_authenticated_session("peer-a", None, "remote-d")
        .await
        .expect("admit commit Session");
    let commit_material = SessionCryptoMaterial {
        root_key,
        local_session_binding: commit_admission.session_id.wire_key(),
        remote_session_binding: "remote-d".into(),
        initiator: false,
        e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
        path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
    };
    complete_relay_admission(
        &commit_state,
        &data,
        "remote-d",
        "peer-a",
        commit_material,
        commit_admission,
    )
    .await
    .expect("current Relay route should commit after authenticated E2EE");
    assert!(commit_state
        .relay
        .relay_path_ready
        .read()
        .await
        .contains("peer-a"));
    assert!(commit_state
        .crypto_context("peer-a", "remote-d")
        .await
        .is_ok());
}

#[tokio::test]
async fn relay_data_connectors_fail_closed_without_config_or_socket() {
    let state = state();
    let reserve = network_relay::v2::RelayReserveResponse {
        request_id: 1,
        attempt_id: "attempt".into(),
        reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        expires_at_ms: 0,
        local_token: vec![0; 32],
    };
    let error = match connect_initiator_relay_data(&state, "peer-a", reserve.clone()).await {
        Ok(_) => panic!("Relay data unexpectedly connected without configuration"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    *state.relay.config.write().await = Some(RelayReconnectConfig {
        relay_url: "ws://127.0.0.1:9".into(),
        credential: "credential".into(),
        signing_seed: [0; 32],
    });
    let malformed_reserve = network_relay::v2::RelayReserveResponse {
        reservation_id: "not-a-reservation".into(),
        ..reserve.clone()
    };
    let error = match connect_initiator_relay_data(&state, "peer-a", malformed_reserve).await {
        Ok(_) => panic!("invalid reservation metadata unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    let error = match connect_initiator_relay_data(&state, "peer-a", reserve).await {
        Ok(_) => panic!("unreachable Relay data endpoint unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);

    connect_incoming_relay_data(
        &state,
        network_relay::v2::IncomingRelayReservation {
            attempt_id: "attempt".into(),
            reservation_id: "7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            initiator_device_id: "peer-a".into(),
            relay_data_endpoint: "ws://127.0.0.1:9/v2/relay/7a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"
                .into(),
            expires_at_ms: 0,
            local_token: vec![0; 31],
        },
    )
    .await;
}

#[tokio::test]
async fn relay_crypto_response_reports_a_closed_initiator_waiter() {
    let state = state();
    let data = Arc::new(data_client());
    let token = "a".repeat(32);
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [3u8; 32],
            e2e_public_key: [4u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    let (sender, receiver) = mpsc::channel(1);
    drop(receiver);
    state
        .relay
        .crypto_waiters
        .write()
        .await
        .insert(relay_crypto_key("peer-a", &token), sender);
    let response = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        b"response",
    )
    .expect("encoded response");

    let error = handle_relay_crypto_handshake(&state, &data, &token, "peer-a", &response)
        .await
        .expect_err("closed initiator waiter must be reported");
    assert!(error.to_string().contains("no longer waiting"));
}

#[tokio::test]
async fn relay_delivery_ack_rejects_unknown_peer_before_decoding() {
    let state = state();
    let data = Arc::new(data_client());
    let error = receive_relay_delivery_ack(&state, &data, "missing-peer", "token", b"bad")
        .await
        .expect_err("ACKs from unknown peers must fail closed");
    assert!(error.to_string().contains("registered peer"));
}

#[tokio::test]
async fn relay_business_envelopes_reject_malformed_token_and_stream_frames() {
    let state = state();
    let data = Arc::new(data_client());
    state.peers.write().await.insert(
        "peer-a".into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: [1u8; 32],
            e2e_public_key: [2u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert("peer-a".into());

    for envelope in [
        vec![DATA_ENV_CHANNEL, 3, b'a'],
        vec![DATA_ENV_CHANNEL_ACK, 1, b'x', 0xff],
        vec![DATA_ENV_STREAM, 1, b'x', 0xff],
    ] {
        let error = handle_relay_data_payload(&state, &data, "peer-a", &envelope)
            .await
            .expect_err("malformed business envelope must fail closed");
        assert!(!error.to_string().is_empty());
    }

    let error = handle_relay_data_payload(&state, &data, "peer-a", &[DATA_ENV_CHANNEL, 1, b'x', 0])
        .await
        .expect_err("a decoded Relay channel payload must reach channel validation");
    assert!(!error.to_string().is_empty());

    let stale = Arc::new(data_client());
    relay_data_disconnected(state, stale, "peer-a".into()).await;
}
