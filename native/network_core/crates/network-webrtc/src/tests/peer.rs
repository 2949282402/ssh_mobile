use super::*;
use crate::qos::EnqueueResult;

#[test]
fn peer_offer_contains_media_and_data_sections() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();
    peer.add_media_transceiver(MediaKind::Audio, MediaDirection::Recvonly, None)
        .unwrap();
    peer.add_media_transceiver(MediaKind::Video, MediaDirection::Recvonly, None)
        .unwrap();
    peer.create_data_channel("control", DataChannelReliability::default())
        .unwrap();

    let offer = peer.create_offer().unwrap();
    assert_eq!(offer.kind, DescriptionType::Offer);
    assert!(offer.sdp.contains("m=audio"));
    assert!(offer.sdp.contains("m=video"));
    assert!(offer.sdp.contains("m=application"));
    assert_eq!(peer.signaling_state(), SignalingState::LocalOffer);
}

#[test]
fn invalid_data_channel_payload_is_rejected_before_rtc() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();
    let channel = peer
        .create_data_channel("control", DataChannelReliability::default())
        .unwrap();
    assert!(peer.send_data(channel, &[]).is_err());
    assert!(peer
        .send_data(channel, &[0; MAX_DATA_CHANNEL_PAYLOAD_BYTES + 1])
        .is_err());
}

#[test]
fn peer_configuration_and_data_channel_boundaries_fail_closed() {
    let too_many_servers = WebRtcConfig {
        ice_servers: (0..9)
            .map(|index| IceServerConfig::stun(format!("stun:server-{index}")))
            .collect(),
        ..Default::default()
    };
    assert!(matches!(
        WebRtcPeer::new(too_many_servers),
        Err(WebRtcError::InvalidConfiguration(message)) if message.contains("eight")
    ));
    assert!(WebRtcPeer::new(WebRtcConfig {
        ice_servers: vec![IceServerConfig::stun(String::new())],
        ..Default::default()
    })
    .is_err());
    assert!(WebRtcPeer::new(WebRtcConfig {
        ice_servers: vec![IceServerConfig::stun("x".repeat(2049))],
        ..Default::default()
    })
    .is_err());

    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();
    assert!(peer
        .create_data_channel("", DataChannelReliability::default())
        .is_err());
    assert!(peer
        .create_data_channel(&"x".repeat(257), DataChannelReliability::default())
        .is_err());
    assert!(peer
        .create_data_channel(
            "conflicting",
            DataChannelReliability {
                max_packet_life_time: Some(1),
                max_retransmits: Some(1),
                ..Default::default()
            },
        )
        .is_err());
    assert!(matches!(
        peer.send_data(99, b"missing"),
        Err(WebRtcError::DataChannelNotFound(_))
    ));
}

#[test]
fn peer_media_directions_and_signaling_types_cover_invalid_branches() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();
    assert!(matches!(
        peer.add_media_transceiver(MediaKind::DataChannel, MediaDirection::Recvonly, None),
        Err(WebRtcError::InvalidConfiguration(message)) if message.contains("RTP")
    ));
    assert!(peer
        .add_media_transceiver(MediaKind::Audio, MediaDirection::Sendonly, None)
        .is_err());
    assert!(peer
        .add_media_transceiver(MediaKind::Video, MediaDirection::Sendrecv, Some(42))
        .is_ok());
    assert!(peer
        .add_media_transceiver(MediaKind::Audio, MediaDirection::Recvonly, None)
        .is_ok());

    let offer = SessionDescription::new(DescriptionType::Offer, "v=0\r\n".into()).unwrap();
    let answer = SessionDescription::new(DescriptionType::Answer, "v=0\r\n".into()).unwrap();
    assert!(matches!(
        peer.accept_remote_offer(answer.clone()),
        Err(WebRtcError::InvalidConfiguration(message)) if message.contains("offer")
    ));
    assert!(matches!(
        peer.accept_remote_answer(offer),
        Err(WebRtcError::InvalidConfiguration(message)) if message.contains("answer")
    ));
    assert!(peer.restart_ice().is_ok());
    assert_eq!(peer.signaling_state(), SignalingState::Restarting);
    peer.close().unwrap();
    assert_eq!(peer.signaling_state(), SignalingState::Closed);
}

#[test]
fn peers_complete_offer_answer_and_candidate_lifecycle() {
    let mut offerer = WebRtcPeer::new(WebRtcConfig {
        ice_servers: vec![IceServerConfig::turn(
            "turn:relay.example:3478",
            "user",
            "credential",
        )],
        relay_only: true,
        ..Default::default()
    })
    .unwrap();
    let mut answerer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();

    let channel = offerer
        .create_data_channel(
            "control",
            DataChannelReliability {
                ordered: false,
                max_retransmits: Some(2),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(offerer.send_data(channel, b"queued-before-connect").is_ok());
    let offer = offerer.create_offer().unwrap();
    answerer.accept_remote_offer(offer).unwrap();
    let answer = answerer.create_answer().unwrap();
    offerer.accept_remote_answer(answer).unwrap();
    assert_eq!(offerer.signaling_state(), SignalingState::Connected);
    assert_eq!(answerer.signaling_state(), SignalingState::LocalAnswer);

    let end = IceCandidate::end_of_candidates();
    offerer.add_local_ice_candidate(end.clone()).unwrap();
    answerer.add_remote_ice_candidate(end).unwrap();

    let _ = offerer.poll_network_packet();
    assert!(offerer.poll_message().is_none());
    let _ = offerer.poll_event();
    let _ = offerer.poll_timeout();
    offerer.handle_timeout(Instant::now()).unwrap();
    offerer.close().unwrap();
    answerer.close().unwrap();
}

#[test]
fn peer_qos_and_runtime_polling_methods_delegate_without_leaking_rtc_state() {
    let now = Instant::now();
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).unwrap();
    let frame = MediaFrame::new(
        MediaKind::Audio,
        1,
        10,
        false,
        vec![1, 2, 3],
        now,
        std::time::Duration::from_secs(1),
    );
    assert_eq!(peer.enqueue_frame(frame, now), Ok(EnqueueResult::Accepted));
    assert_eq!(peer.pop_frame(now).unwrap().sequence, 1);
    assert!(!peer.take_keyframe_request());
    peer.on_connection_lost();
    assert!(peer.take_keyframe_request());
    assert_eq!(peer.qos().stats().dequeued, 1);
    assert!(peer.poll_network_packet().is_none());
    assert!(peer.poll_message().is_none());
    assert!(peer.poll_event().is_none());
    assert!(peer.handle_timeout(now).is_err());
    peer.close().unwrap();
}
