use std::time::Instant;

use rtc::peer_connection::configuration::media_engine::{
    MediaEngine, MIME_TYPE_H264, MIME_TYPE_OPUS,
};
use rtc::rtp_transceiver::rtp_sender::{
    RTCPFeedback, RTCRtpCodec, RTCRtpCodecParameters, RtpCodecKind,
};
use rtc::rtp_transceiver::RTCRtpSenderId;

use crate::peer::{rtc_error, MediaDirection, WebRtcError, WebRtcPeer};

use super::{
    EncodedVideoFrame, KeyframeRequestReason, RtpPacketizer, RtpReassembler, VideoEnqueueResult,
    VideoQueue,
};

const H264_RTP_PAYLOAD_TYPE: u8 = 102;
const H264_RTP_MTU: usize = 1_200;

pub(crate) struct H264ScreenVideo {
    sender_id: Option<RTCRtpSenderId>,
    outbound: VideoQueue,
    inbound: VideoQueue,
    packetizer: Option<RtpPacketizer>,
    reassembler: RtpReassembler,
    accepts_inbound: bool,
}

impl H264ScreenVideo {
    fn new(sender_id: Option<RTCRtpSenderId>, ssrc: Option<u32>, accepts_inbound: bool) -> Self {
        Self {
            sender_id,
            outbound: VideoQueue::new(),
            inbound: VideoQueue::new(),
            packetizer: ssrc.map(|ssrc| {
                RtpPacketizer::new(
                    H264_RTP_MTU,
                    H264_RTP_PAYLOAD_TYPE,
                    ssrc,
                    (ssrc as u16).wrapping_add(1),
                )
            }),
            reassembler: RtpReassembler::new(),
            accepts_inbound,
        }
    }

    pub(crate) fn on_ice_restart(&mut self) {
        self.outbound
            .request_keyframe(KeyframeRequestReason::IceRestart);
    }

    pub(crate) fn on_connection_lost(&mut self) {
        self.outbound.on_disconnect();
        self.inbound.on_disconnect();
        self.reassembler.reset();
    }
}

impl WebRtcPeer {
    /// Configures the peer's one native H.264 screen-video track.
    ///
    /// The track and RTP sender stay owned by this native peer. Callers enqueue
    /// encoded access units only; they never receive a PeerConnection, sender,
    /// or DataChannel handle.
    pub fn configure_h264_screen_video(
        &mut self,
        direction: MediaDirection,
        ssrc: Option<u32>,
    ) -> Result<(), WebRtcError> {
        if self.screen_video.is_some() {
            return Err(WebRtcError::ScreenVideoAlreadyConfigured);
        }
        let sends = matches!(
            direction,
            MediaDirection::Sendonly | MediaDirection::Sendrecv
        );
        if sends != ssrc.is_some() {
            return Err(WebRtcError::InvalidConfiguration(
                "a screen-video SSRC is required exactly for a sending H.264 transceiver".into(),
            ));
        }

        self.add_media_transceiver(crate::qos::MediaKind::Video, direction, ssrc)?;
        let sender_id = if sends {
            Some(self.peer.get_senders().last().ok_or_else(|| {
                WebRtcError::Rtc("screen-video RTP sender was not created".to_owned())
            })?)
        } else {
            None
        };
        self.screen_video = Some(H264ScreenVideo::new(
            sender_id,
            ssrc,
            matches!(
                direction,
                MediaDirection::Recvonly | MediaDirection::Sendrecv
            ),
        ));
        Ok(())
    }

    /// Enqueues one native H.264 access unit. It is bounded before it reaches
    /// RTP and cannot use the DataChannel path.
    pub fn enqueue_h264_screen_video(
        &mut self,
        frame: EncodedVideoFrame,
        now: Instant,
    ) -> Result<VideoEnqueueResult, WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if video.sender_id.is_none() {
            return Err(WebRtcError::ScreenVideoNotConfigured);
        }
        video.outbound.enqueue(frame, now).map_err(Into::into)
    }

    /// Writes all eligible native H.264 frames to the RTP sender. The I/O
    /// driver drains the resulting SRTP packets over its UDP socket.
    pub fn flush_h264_screen_video(&mut self, now: Instant) -> Result<usize, WebRtcError> {
        let sender_id = self
            .screen_video
            .as_ref()
            .and_then(|video| video.sender_id)
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if self.signaling.state() != crate::signaling::SignalingState::Connected {
            return Err(WebRtcError::ScreenVideoNotReady);
        }
        let mut packet_count = 0;
        loop {
            let packets = {
                let video = self
                    .screen_video
                    .as_mut()
                    .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
                let Some(frame) = video.outbound.pop(now) else {
                    break;
                };
                video
                    .packetizer
                    .as_mut()
                    .ok_or(WebRtcError::ScreenVideoNotConfigured)?
                    .packetize(&frame)?
            };
            let mut sender = self
                .peer
                .rtp_sender(sender_id)
                .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
            for packet in packets {
                sender.write_rtp(packet).map_err(rtc_error)?;
                packet_count += 1;
            }
        }
        Ok(packet_count)
    }

    /// Runtime-only variant used by the I/O owner. A peer without a sending
    /// screen track, or one that has not finished SDP negotiation, simply has
    /// no media work to drain yet.
    pub(crate) fn flush_pending_h264_screen_video(
        &mut self,
        now: Instant,
    ) -> Result<usize, WebRtcError> {
        if self
            .screen_video
            .as_ref()
            .is_none_or(|video| video.sender_id.is_none())
            || self.signaling.state() != crate::signaling::SignalingState::Connected
        {
            return Ok(0);
        }
        self.flush_h264_screen_video(now)
    }

    /// Accepts an RTP packet only inside the native media owner and stores a
    /// completed encoded access unit in the bounded incoming queue.
    pub fn receive_h264_screen_video_rtp(
        &mut self,
        packet: &rtc::rtp::Packet,
        now: Instant,
    ) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if !video.accepts_inbound {
            return Err(WebRtcError::ScreenVideoNotConfigured);
        }
        if let Some(frame) = video.reassembler.push_at(packet, now)? {
            let _ = video.inbound.enqueue(frame, now)?;
        }
        Ok(())
    }

    /// Returns an encoded remote H.264 access unit to another native owner.
    /// It is intentionally never exposed through the Dart/FFI event stream.
    pub fn pop_remote_h264_screen_video(&mut self, now: Instant) -> Option<EncodedVideoFrame> {
        self.screen_video
            .as_mut()
            .and_then(|video| video.inbound.pop(now))
    }

    pub fn pending_h264_screen_video_frames(&self) -> usize {
        self.screen_video
            .as_ref()
            .map_or(0, |video| video.outbound.len())
    }

    pub fn reset_h264_screen_video_decoder(&mut self) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        video.reassembler.reset();
        video.inbound.on_decoder_reset();
        Ok(())
    }

    pub fn take_h264_screen_video_keyframe_request(&mut self) -> Option<KeyframeRequestReason> {
        self.screen_video.as_mut().and_then(|video| {
            video
                .outbound
                .take_keyframe_request()
                .or_else(|| video.inbound.take_keyframe_request())
        })
    }
}

pub(crate) fn h264_media_engine() -> Result<MediaEngine, WebRtcError> {
    let mut media_engine = MediaEngine::default();
    media_engine
        .register_codec(
            RTCRtpCodecParameters {
                rtp_codec: RTCRtpCodec {
                    mime_type: MIME_TYPE_OPUS.to_owned(),
                    clock_rate: 48_000,
                    channels: 2,
                    sdp_fmtp_line: "minptime=10;useinbandfec=1".to_owned(),
                    rtcp_feedback: Vec::new(),
                },
                payload_type: 111,
            },
            RtpCodecKind::Audio,
        )
        .map_err(rtc_error)?;
    media_engine
        .register_codec(h264_codec_parameters(), RtpCodecKind::Video)
        .map_err(rtc_error)?;
    Ok(media_engine)
}

pub(crate) fn h264_codec_parameters() -> RTCRtpCodecParameters {
    RTCRtpCodecParameters {
        rtp_codec: RTCRtpCodec {
            mime_type: MIME_TYPE_H264.to_owned(),
            clock_rate: 90_000,
            channels: 0,
            sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
                .to_owned(),
            rtcp_feedback: vec![
                RTCPFeedback {
                    typ: "nack".to_owned(),
                    parameter: "".to_owned(),
                },
                RTCPFeedback {
                    typ: "nack".to_owned(),
                    parameter: "pli".to_owned(),
                },
                RTCPFeedback {
                    typ: "ccm".to_owned(),
                    parameter: "fir".to_owned(),
                },
            ],
        },
        payload_type: H264_RTP_PAYLOAD_TYPE,
    }
}
