use super::*;

/// Guards the fragile cross-crate relative path to the frozen contract.
#[test]
fn proto_file_exists_at_documented_relative_path() {
    let proto = "../../../../protocol/proto/relay/v2/relay_v2.proto";
    assert!(
        std::path::Path::new(proto).exists(),
        "relay v2 proto missing at {proto} (run tests from the crate root)"
    );
}

#[test]
fn constants_match_manifest() {
    // Spot-check the values that most easily drift from manifest.json.
    assert_eq!(RELAY_V2_VERSION, 2);
    assert_eq!(FRAME_LENGTH_PREFIX_BYTES, 4);
    assert_eq!(MAX_RELAY_FRAME_BYTES, 4 + 512 * 1024);
    assert_eq!(MAX_RELAY_DATA_FRAME_BYTES, 4 + 512 * 1024);
    assert_eq!(MAX_DEVICE_ID_BYTES, 128);
    assert_eq!(MAX_ATTEMPT_ID_BYTES, 128);
    assert_eq!(MAX_REALTIME_SIGNAL_PAYLOAD_BYTES, 256 * 1024);
    assert_eq!(RESERVATION_ID_BYTES, 16);
    assert_eq!(RESERVATION_ID_HEX_CHARS, 32);
    assert_eq!(RESERVATION_TOKEN_BYTES, 32);
    assert_eq!(HEARTBEAT_INTERVAL_S, 20);
    assert_eq!(PRESENCE_TTL_S, 60);
    assert_eq!(DIRECT_CONNECT_WINDOW_MS, 4000);
}

#[test]
fn encode_frame_prepends_big_endian_length() {
    let ready = Ready {
        protocol_version: 2,
        device_id: "11111111111111111111111111111111".to_string(),
        server_time_ms: 1723840800123,
        heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
        presence_ttl_s: PRESENCE_TTL_S,
    };
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::Ready(ready)),
    };
    let encoded = encode_frame(&frame);
    assert!(encoded.len() > FRAME_LENGTH_PREFIX_BYTES);
    let mut prefix = [0u8; 4];
    prefix.copy_from_slice(&encoded[..4]);
    assert_eq!(u32::from_be_bytes(prefix) as usize, encoded.len() - 4);
}

#[test]
fn frame_error_is_displayable() {
    let errors = [
        FrameError::TooShort,
        FrameError::LengthMismatch {
            prefix: 10,
            actual: 9,
        },
        FrameError::TooLarge {
            max: 12,
            actual: 13,
        },
        FrameError::InvalidVersion {
            version: 1,
            expected: RELAY_V2_VERSION,
        },
        FrameError::Decode("invalid protobuf".to_owned()),
    ];
    for error in errors {
        assert!(!error.to_string().is_empty());
    }
}

#[test]
fn data_route_rejects_malformed_and_wrong_version_frames() {
    assert!(matches!(
        decode_data(&[0, 0, 0, 1, 0xff]),
        Err(FrameError::Decode(_))
    ));

    let wrong_version = RelayDataFrame {
        version: 1,
        kind: None,
    };
    assert!(matches!(
        decode_data(&encode_frame(&wrong_version)),
        Err(FrameError::InvalidVersion {
            version: 1,
            expected: RELAY_V2_VERSION,
        })
    ));

    assert!(matches!(
        decode_control(&[0, 0, 0, 1, 0xff]),
        Err(FrameError::Decode(_))
    ));
}
