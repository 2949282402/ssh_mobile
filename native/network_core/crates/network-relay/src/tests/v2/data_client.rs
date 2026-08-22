use super::*;
use prost::Message;

#[test]
fn data_payload_frame_round_trips() {
    let frame = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
            sequence: 42,
            encrypted_payload: (65..129).collect::<Vec<u8>>(),
        })),
    };
    let encoded = encode_data_frame(&frame).expect("encode");
    // [4-byte BE length][protobuf]
    assert_eq!(encoded.len(), 4 + frame.encoded_len());
    assert_eq!(
        u32::from_be_bytes(encoded[..4].try_into().unwrap()) as usize,
        encoded.len() - 4
    );
    let decoded = decode_data_frame(&encoded).expect("decode");
    assert_eq!(decoded, frame);
}

#[test]
fn data_connect_frame_is_encoded_for_the_reservation() {
    let frame = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Connect(RelayDataConnect {
            reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            local_token: (1..33).collect(),
        })),
    };
    let encoded = encode_data_frame(&frame).expect("encode");
    let decoded = decode_data_frame(&encoded).expect("decode");
    assert_eq!(decoded, frame);
}

#[test]
fn data_close_event_decodes() {
    let frame = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Close(RelayDataClose {
            reason: 1,
            detail: "expiry".into(),
        })),
    };
    let encoded = encode_data_frame(&frame).expect("encode");
    let event = data_event_from_frame(decode_data_frame(&encoded).expect("decode")).expect("event");
    assert_eq!(
        event,
        DataEvent::Close {
            reason: 1,
            detail: "expiry".into(),
        }
    );
}

#[test]
fn pair_ready_is_a_websocket_control_signal_not_a_business_frame() {
    let frame = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
            sequence: 1,
            encrypted_payload: b"payload".to_vec(),
        })),
    };
    let encoded = encode_data_frame(&frame).expect("encode");
    assert!(!encoded
        .windows(b"ssh-mobile-relay-paired-v1:".len())
        .any(|window| window == b"ssh-mobile-relay-paired-v1:"));
}

#[test]
fn data_frame_version_must_be_two() {
    let frame = RelayDataFrame {
        version: 1,
        kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
            sequence: 1,
            encrypted_payload: vec![0u8; 16],
        })),
    };
    assert!(encode_data_frame(&frame).is_err());
}

#[test]
fn data_endpoint_normalization_requires_v2_reservation_path() {
    assert!(normalize_data_endpoint(
        "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"
    )
    .is_ok());
    // 错误 path（不是 /v2/relay/{32-hex}）必须被拒绝。
    assert!(normalize_data_endpoint("wss://relay.example.test/v2/relay/short").is_err());
    assert!(normalize_data_endpoint("wss://relay.example.test/v1/relay").is_err());
    assert!(normalize_data_endpoint("wss://relay.example.test").is_err());
}

#[tokio::test]
async fn rate_budget_gates_oversized_bursts() {
    let budget = RateBudget::new(1024.0, 1024.0);
    let budget = Arc::new(Mutex::new(budget));
    let (inbound_tx, inbound) = mpsc::channel(4);
    let client = RelayDataClient {
        data_url: Url::parse("wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d")
            .expect("url"),
        reservation_id: "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        local_token: (1..33).collect(),
        credential: "credential".into(),
        signing_key: SigningKey::from_bytes(&[0u8; 32]),
        outbound: None,
        inbound: Some(inbound),
        inbound_tx,
        rate_budget: budget,
        writer_task: None,
        reader_task: None,
        is_connected: Arc::new(RwLock::new(false)),
        disconnect_notified: Arc::new(AtomicBool::new(false)),
        intentional_disconnect: Arc::new(AtomicBool::new(false)),
    };
    // 未连接时在出站队列阶段报 NotConnected（速率预算已通过）。
    assert!(matches!(
        client.send(1, &vec![0u8; 1024]).await,
        Err(RelayError::NotConnected)
    ));
}

/// 回归 #1：Go 端 connectRelayData 在升级前要求 reservation 本地 token
/// （`?token=` 或 `X-Relay-Token`），升级请求必须携带 hex 编码的 token 头。
#[test]
fn data_upgrade_request_carries_reservation_token_header() {
    let client = RelayDataClient::new(
        "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        (1..33).collect(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let request = client
        .build_data_upgrade_request()
        .expect("upgrade request");
    assert_eq!(
        request
            .headers()
            .get("X-Relay-Token")
            .expect("token header")
            .to_str()
            .expect("ascii header"),
        hex::encode(&client.local_token)
    );
    // 设备认证头仍然保留。
    assert!(request.headers().get("Authorization").is_some());
}

/// 回归 #14a：主动断开必须向事件通道发出终态事件，否则消费者阻塞在 recv()
/// 上永久驻留（Arc<RelayDataClient> + 事件通道泄漏）。
#[tokio::test]
async fn request_disconnect_emits_terminal_close_event() {
    let mut client = RelayDataClient::new(
        "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
        (1..33).collect(),
        "credential".into(),
        [0u8; 32],
    )
    .expect("client");
    let mut events = client.take_events().expect("events");
    client.request_disconnect().await;
    assert_eq!(
        events.recv().await,
        Some(DataEvent::Close {
            reason: 0,
            detail: "intentional disconnect".into(),
        })
    );
}
