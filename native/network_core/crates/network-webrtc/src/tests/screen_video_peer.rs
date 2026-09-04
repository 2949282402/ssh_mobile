use std::time::{Duration, Instant};

use crate::{
    EncodedVideoFrame, KeyframeRequestReason, MediaDirection, VideoCodec, VideoEnqueueResult,
    WebRtcConfig, WebRtcError, WebRtcPeer,
};

const SCREEN_SSRC: u32 = 0x1357_2468;

fn access_unit(sequence: u64, timestamp: u64) -> EncodedVideoFrame {
    let mut payload = vec![
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1f, 0xe5, 0x88, 0x68, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80, 0,
        0, 0, 1, 0x65,
    ];
    payload.extend((0..512).map(|index| (index as u8).wrapping_mul(29)));
    EncodedVideoFrame::new(
        VideoCodec::H264,
        sequence,
        timestamp,
        1_920,
        1_080,
        true,
        payload,
        Instant::now() + Duration::from_secs(1),
    )
}

#[test]
fn screen_video_offer_advertises_h264_without_video_codec_fallbacks() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    peer.configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("screen video sender");

    let offer = peer.create_offer().expect("offer");
    assert!(offer.sdp.contains("H264"));
    for forbidden in ["VP8", "VP9", "AV1", "H265", "HEVC"] {
        assert!(
            !offer.sdp.contains(forbidden),
            "screen-video SDP must not advertise {forbidden} fallback"
        );
    }
}

#[test]
fn screen_video_requires_a_configured_h264_sender_and_stays_off_data_channels() {
    let now = Instant::now();
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    assert!(matches!(
        peer.enqueue_h264_screen_video(access_unit(1, 90_000), now),
        Err(WebRtcError::ScreenVideoNotConfigured)
    ));
    assert!(matches!(
        peer.flush_h264_screen_video(now),
        Err(WebRtcError::ScreenVideoNotConfigured)
    ));

    peer.configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("screen video sender");
    assert!(matches!(
        peer.enqueue_h264_screen_video(access_unit(2, 93_000), now),
        Ok(VideoEnqueueResult::Accepted)
    ));
    assert!(matches!(
        peer.flush_h264_screen_video(now),
        Err(WebRtcError::ScreenVideoNotReady)
    ));
    assert_eq!(peer.pending_h264_screen_video_frames(), 1);
}

#[test]
fn screen_video_configuration_fails_closed_for_invalid_direction_or_ssrc() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Sendonly, None),
        Err(WebRtcError::InvalidConfiguration(_))
    ));
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Recvonly, Some(SCREEN_SSRC)),
        Err(WebRtcError::InvalidConfiguration(_))
    ));
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Recvonly, None),
        Err(WebRtcError::ScreenVideoAlreadyConfigured)
    ));
}

#[test]
fn screen_video_recovery_requests_a_keyframe_for_ice_restart_and_decoder_reset() {
    let mut sender = WebRtcPeer::new(WebRtcConfig::default()).expect("sender");
    sender
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("sender config");
    sender.restart_ice().expect("ICE restart");
    assert_eq!(
        sender.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::IceRestart)
    );

    let mut receiver = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    receiver
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    receiver
        .reset_h264_screen_video_decoder()
        .expect("decoder reset");
    assert_eq!(
        receiver.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::DecoderReset)
    );
}
