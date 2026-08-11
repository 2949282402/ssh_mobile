use std::collections::VecDeque;
use std::time::{Duration, Instant};

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MediaKind {
    Audio,
    Video,
    DataChannel,
}

impl MediaKind {
    fn index(self) -> usize {
        match self {
            Self::Audio => 0,
            Self::Video => 1,
            Self::DataChannel => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaQosPolicy {
    pub max_frames: usize,
    pub max_bytes: usize,
    pub ttl: Duration,
    pub priority: u8,
    pub discard_old: bool,
}

impl MediaQosPolicy {
    pub const fn audio() -> Self {
        Self {
            max_frames: 64,
            max_bytes: 256 * 1024,
            ttl: Duration::from_millis(250),
            priority: 2,
            discard_old: true,
        }
    }

    pub const fn video() -> Self {
        Self {
            max_frames: 4,
            max_bytes: 4 * 1024 * 1024,
            ttl: Duration::from_millis(250),
            priority: 1,
            discard_old: true,
        }
    }

    pub const fn data_channel() -> Self {
        Self {
            max_frames: 64,
            max_bytes: 1024 * 1024,
            ttl: Duration::from_secs(5),
            priority: 3,
            discard_old: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaQosConfig {
    pub audio: MediaQosPolicy,
    pub video: MediaQosPolicy,
    pub data_channel: MediaQosPolicy,
}

impl Default for MediaQosConfig {
    fn default() -> Self {
        Self {
            audio: MediaQosPolicy::audio(),
            video: MediaQosPolicy::video(),
            data_channel: MediaQosPolicy::data_channel(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaFrame {
    pub kind: MediaKind,
    pub sequence: u64,
    pub timestamp_ms: u64,
    pub keyframe: bool,
    pub expires_at: Instant,
    pub payload: Vec<u8>,
}

impl MediaFrame {
    pub fn new(
        kind: MediaKind,
        sequence: u64,
        timestamp_ms: u64,
        keyframe: bool,
        payload: Vec<u8>,
        now: Instant,
        ttl: Duration,
    ) -> Self {
        Self {
            kind,
            sequence,
            timestamp_ms,
            keyframe,
            expires_at: now + ttl,
            payload,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnqueueResult {
    Accepted,
    AcceptedAfterDropping { count: usize },
    DroppedIncoming,
}

#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum QosError {
    #[error("media frame payload is empty")]
    EmptyPayload,
    #[error("media frame payload exceeds the channel limit")]
    PayloadTooLarge,
    #[error("reliable media queue is full")]
    QueueFull,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct QosStats {
    pub enqueued: u64,
    pub dequeued: u64,
    pub dropped_expired: u64,
    pub dropped_overflow: u64,
    pub dropped_on_disconnect: u64,
    pub rejected_backpressure: u64,
    pub keyframe_requests: u64,
}

pub struct MediaQos {
    policies: [MediaQosPolicy; 3],
    queues: [VecDeque<MediaFrame>; 3],
    queue_bytes: [usize; 3],
    stats: QosStats,
    keyframe_requested: bool,
}

impl Default for MediaQos {
    fn default() -> Self {
        Self::from_config(MediaQosConfig::default())
    }
}

impl MediaQos {
    pub fn from_config(config: MediaQosConfig) -> Self {
        Self {
            policies: [config.audio, config.video, config.data_channel],
            queues: std::array::from_fn(|_| VecDeque::new()),
            queue_bytes: [0; 3],
            stats: QosStats::default(),
            keyframe_requested: false,
        }
    }

    pub fn enqueue(&mut self, frame: MediaFrame, now: Instant) -> Result<EnqueueResult, QosError> {
        let index = frame.kind.index();
        let policy = self.policies[index];
        if frame.payload.is_empty() {
            return Err(QosError::EmptyPayload);
        }
        if frame.payload.len() > policy.max_bytes {
            return Err(QosError::PayloadTooLarge);
        }
        if frame.expires_at <= now {
            self.stats.dropped_expired = self.stats.dropped_expired.saturating_add(1);
            return Ok(EnqueueResult::DroppedIncoming);
        }

        self.evict_expired(now);
        if frame.kind == MediaKind::Video && frame.keyframe {
            self.drop_all(index);
        } else if frame.kind == MediaKind::Video
            && !frame.keyframe
            && self.queues[index].iter().any(|item| item.keyframe)
            && (self.queues[index].len() >= policy.max_frames
                || self.queue_bytes[index].saturating_add(frame.payload.len()) > policy.max_bytes)
        {
            self.stats.dropped_overflow = self.stats.dropped_overflow.saturating_add(1);
            return Ok(EnqueueResult::DroppedIncoming);
        }

        let mut dropped = 0;
        while self.queues[index].len() >= policy.max_frames
            || self.queue_bytes[index].saturating_add(frame.payload.len()) > policy.max_bytes
        {
            if !policy.discard_old {
                self.stats.rejected_backpressure =
                    self.stats.rejected_backpressure.saturating_add(1);
                return Err(QosError::QueueFull);
            }
            if self.queues[index].pop_front().is_some_and(|old| {
                self.queue_bytes[index] = self.queue_bytes[index].saturating_sub(old.payload.len());
                true
            }) {
                dropped += 1;
                self.stats.dropped_overflow = self.stats.dropped_overflow.saturating_add(1);
            } else {
                break;
            }
        }

        self.queue_bytes[index] = self.queue_bytes[index].saturating_add(frame.payload.len());
        self.queues[index].push_back(frame);
        self.stats.enqueued = self.stats.enqueued.saturating_add(1);
        Ok(if dropped == 0 {
            EnqueueResult::Accepted
        } else {
            EnqueueResult::AcceptedAfterDropping { count: dropped }
        })
    }

    pub fn pop_next(&mut self, now: Instant) -> Option<MediaFrame> {
        self.evict_expired(now);
        let index = (0..self.queues.len())
            .filter(|index| !self.queues[*index].is_empty())
            .max_by_key(|index| self.policies[*index].priority)?;
        let frame = self.queues[index].pop_front()?;
        self.queue_bytes[index] = self.queue_bytes[index].saturating_sub(frame.payload.len());
        self.stats.dequeued = self.stats.dequeued.saturating_add(1);
        Some(frame)
    }

    pub fn on_connection_lost(&mut self) {
        for index in [MediaKind::Audio.index(), MediaKind::Video.index()] {
            let dropped = self.queues[index].len() as u64;
            if dropped != 0 {
                self.stats.dropped_on_disconnect =
                    self.stats.dropped_on_disconnect.saturating_add(dropped);
            }
            self.drop_all(index);
        }
        self.request_keyframe();
    }

    pub fn take_keyframe_request(&mut self) -> bool {
        let requested = self.keyframe_requested;
        self.keyframe_requested = false;
        requested
    }

    pub fn stats(&self) -> QosStats {
        self.stats
    }

    pub fn queued_frames(&self, kind: MediaKind) -> usize {
        self.queues[kind.index()].len()
    }

    pub fn queued_bytes(&self, kind: MediaKind) -> usize {
        self.queue_bytes[kind.index()]
    }

    fn request_keyframe(&mut self) {
        if !self.keyframe_requested {
            self.keyframe_requested = true;
            self.stats.keyframe_requests = self.stats.keyframe_requests.saturating_add(1);
        }
    }

    fn drop_all(&mut self, index: usize) {
        self.queues[index].clear();
        self.queue_bytes[index] = 0;
    }

    fn evict_expired(&mut self, now: Instant) {
        for index in 0..self.queues.len() {
            while self.queues[index]
                .front()
                .is_some_and(|frame| frame.expires_at <= now)
            {
                if let Some(frame) = self.queues[index].pop_front() {
                    self.queue_bytes[index] =
                        self.queue_bytes[index].saturating_sub(frame.payload.len());
                    self.stats.dropped_expired = self.stats.dropped_expired.saturating_add(1);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
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
}
