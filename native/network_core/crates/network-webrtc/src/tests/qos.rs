use super::*;

fn frame(kind: MediaKind, sequence: u64, keyframe: bool, now: Instant) -> MediaFrame {
    MediaFrame::new(
        kind,
        sequence,
        0,
        keyframe,
        vec![1, 2],
        now,
        Duration::from_secs(1),
    )
}

#[test]
fn video_queue_discards_old_frames_and_requests_keyframe() {
    let now = Instant::now();
    let mut qos = MediaQos::default();
    qos.enqueue(frame(MediaKind::Video, 1, true, now), now)
        .unwrap();
    for sequence in 2..=6 {
        qos.enqueue(frame(MediaKind::Video, sequence, false, now), now)
            .unwrap();
    }
    assert!(qos.stats().dropped_overflow > 0);
    assert!(qos.queued_frames(MediaKind::Video) <= MediaQosPolicy::video().max_frames);
    qos.on_connection_lost();
    assert_eq!(qos.queued_frames(MediaKind::Video), 0);
    assert!(qos.take_keyframe_request());
}

#[test]
fn expired_frames_are_not_replayed() {
    let now = Instant::now();
    let mut qos = MediaQos::default();
    let expired = MediaFrame::new(MediaKind::Audio, 1, 0, false, vec![1], now, Duration::ZERO);
    assert_eq!(
        qos.enqueue(expired, now),
        Ok(EnqueueResult::DroppedIncoming)
    );
    assert!(qos.pop_next(now).is_none());
}

#[test]
fn data_channel_queue_uses_backpressure() {
    let now = Instant::now();
    let config = MediaQosConfig {
        data_channel: MediaQosPolicy {
            max_frames: 1,
            max_bytes: 2,
            ..MediaQosPolicy::data_channel()
        },
        ..Default::default()
    };
    let mut qos = MediaQos::from_config(config);
    qos.enqueue(frame(MediaKind::DataChannel, 1, false, now), now)
        .unwrap();
    assert_eq!(
        qos.enqueue(frame(MediaKind::DataChannel, 2, false, now), now),
        Err(QosError::QueueFull)
    );
}

#[test]
fn qos_rejects_empty_and_oversized_payloads_and_prioritizes_data() {
    let now = Instant::now();
    let mut qos = MediaQos::default();
    let empty = MediaFrame::new(
        MediaKind::Audio,
        1,
        0,
        false,
        Vec::new(),
        now,
        Duration::from_secs(1),
    );
    assert_eq!(qos.enqueue(empty, now), Err(QosError::EmptyPayload));
    let oversized = MediaFrame::new(
        MediaKind::Audio,
        2,
        0,
        false,
        vec![0; MediaQosPolicy::audio().max_bytes + 1],
        now,
        Duration::from_secs(1),
    );
    assert_eq!(qos.enqueue(oversized, now), Err(QosError::PayloadTooLarge));
    qos.enqueue(frame(MediaKind::Audio, 3, false, now), now)
        .unwrap();
    qos.enqueue(frame(MediaKind::DataChannel, 4, false, now), now)
        .unwrap();
    assert_eq!(qos.pop_next(now).unwrap().kind, MediaKind::DataChannel);
    assert_eq!(qos.pop_next(now).unwrap().kind, MediaKind::Audio);
}

#[test]
fn video_keyframes_clear_old_frames_and_disconnect_drops_audio_video_only() {
    let now = Instant::now();
    let mut qos = MediaQos::default();
    qos.enqueue(frame(MediaKind::Video, 1, false, now), now)
        .unwrap();
    qos.enqueue(frame(MediaKind::Audio, 2, false, now), now)
        .unwrap();
    qos.enqueue(frame(MediaKind::DataChannel, 3, false, now), now)
        .unwrap();
    qos.enqueue(frame(MediaKind::Video, 4, true, now), now)
        .unwrap();
    assert_eq!(qos.queued_frames(MediaKind::Video), 1);
    qos.on_connection_lost();
    assert_eq!(qos.queued_frames(MediaKind::Audio), 0);
    assert_eq!(qos.queued_frames(MediaKind::Video), 0);
    assert_eq!(qos.queued_frames(MediaKind::DataChannel), 1);
    assert!(qos.take_keyframe_request());
    assert!(!qos.take_keyframe_request());
    assert_eq!(qos.stats().dropped_on_disconnect, 2);
}

#[test]
fn qos_evicts_expired_frames_and_reports_overflow_drops() {
    let now = Instant::now();
    let mut qos = MediaQos::from_config(MediaQosConfig {
        audio: MediaQosPolicy {
            max_frames: 1,
            max_bytes: 2,
            ..MediaQosPolicy::audio()
        },
        ..Default::default()
    });
    qos.enqueue(frame(MediaKind::Audio, 1, false, now), now)
        .unwrap();
    qos.enqueue(
        MediaFrame::new(
            MediaKind::Audio,
            2,
            0,
            false,
            vec![3, 4],
            now,
            Duration::from_secs(1),
        ),
        now,
    )
    .unwrap();
    assert_eq!(qos.stats().dropped_overflow, 1);
    assert!(qos.queued_bytes(MediaKind::Audio) <= 2);
    assert!(qos
        .enqueue(
            MediaFrame::new(MediaKind::Audio, 3, 0, false, vec![5], now, Duration::ZERO,),
            now,
        )
        .is_ok());
    assert!(qos.pop_next(now).is_some());
    assert!(qos.stats().dropped_expired >= 1);
}
