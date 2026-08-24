//! Runtime event classification, byte admission, and bounded lane scheduling.

use network_protocol::{network_event, NetworkEvent};
use prost::Message;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::mpsc::UnboundedSender;

/// Native events are split before FFI polling so a data flood cannot block
/// command results, peer state, or relay lifecycle events.
pub(crate) const CONTROL_EVENT_MAILBOX_CAPACITY: usize = 256;
pub(crate) const DATA_EVENT_MAILBOX_CAPACITY: usize = 128;
pub(crate) const MAX_CONTROL_EVENT_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_DATA_EVENT_QUEUE_BYTES: usize = 8 * 1024 * 1024;
/// Compatibility names retained by the frozen protocol contract inventory;
/// actual limits are enforced independently by the two lanes above.
#[allow(dead_code)]
pub(crate) const EVENT_MAILBOX_CAPACITY: usize = CONTROL_EVENT_MAILBOX_CAPACITY;
#[allow(dead_code)]
pub(crate) const MAX_EVENT_QUEUE_BYTES: usize =
    MAX_CONTROL_EVENT_QUEUE_BYTES + MAX_DATA_EVENT_QUEUE_BYTES;
pub(crate) const MAX_EVENT_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_CONSECUTIVE_CONTROL_EVENTS: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeEventLane {
    Control,
    Data,
}

/// Owns the runtime's event-lane policy and constructs the paired endpoints.
pub(crate) struct BoundedEventLanes;

impl BoundedEventLanes {
    fn classify(event: &NetworkEvent) -> RuntimeEventLane {
        match event.payload.as_ref() {
            Some(network_event::Payload::TransferProgress(_))
            | Some(network_event::Payload::PeerTransferProgress(_))
            | Some(network_event::Payload::ChannelMessage(_))
            | Some(network_event::Payload::SshStreamDataReceived(_)) => RuntimeEventLane::Data,
            _ => RuntimeEventLane::Control,
        }
    }

    pub(crate) fn channel() -> (EventSender, EventReceiver) {
        let (control_sender, control_receiver) = mpsc::channel(CONTROL_EVENT_MAILBOX_CAPACITY);
        let (data_sender, data_receiver) = mpsc::channel(DATA_EVENT_MAILBOX_CAPACITY);
        let control_queued_bytes = Arc::new(AtomicUsize::new(0));
        let data_queued_bytes = Arc::new(AtomicUsize::new(0));
        (
            EventSender::Bounded {
                control_sender,
                data_sender,
                control_queued_bytes: Arc::clone(&control_queued_bytes),
                data_queued_bytes: Arc::clone(&data_queued_bytes),
            },
            EventReceiver {
                control_receiver,
                data_receiver,
                control_queued_bytes,
                data_queued_bytes,
                consecutive_control: 0,
                control_closed: false,
                data_closed: false,
            },
        )
    }
}

/// A bounded production event sender with an unbounded test adapter.
///
/// The test adapter keeps focused unit tests able to observe events without
/// introducing a second production queue. `NetworkRuntime::new` always uses
/// the bounded variant from [`BoundedEventLanes`].
#[derive(Clone)]
pub(crate) enum EventSender {
    Bounded {
        control_sender: mpsc::Sender<NetworkEvent>,
        data_sender: mpsc::Sender<NetworkEvent>,
        control_queued_bytes: Arc<AtomicUsize>,
        data_queued_bytes: Arc<AtomicUsize>,
    },
    #[cfg(test)]
    Unbounded(tokio::sync::mpsc::UnboundedSender<NetworkEvent>),
}

pub(crate) struct EventReceiver {
    control_receiver: mpsc::Receiver<NetworkEvent>,
    data_receiver: mpsc::Receiver<NetworkEvent>,
    control_queued_bytes: Arc<AtomicUsize>,
    data_queued_bytes: Arc<AtomicUsize>,
    consecutive_control: usize,
    control_closed: bool,
    data_closed: bool,
}

impl EventSender {
    pub(crate) fn send(&self, event: NetworkEvent) -> Result<(), ()> {
        let bytes = event.encoded_len();
        if bytes > MAX_EVENT_BYTES {
            return Err(());
        }
        match self {
            Self::Bounded {
                control_sender,
                data_sender,
                control_queued_bytes,
                data_queued_bytes,
            } => {
                let (sender, queued_bytes, max_bytes) = match BoundedEventLanes::classify(&event) {
                    RuntimeEventLane::Control => (
                        control_sender,
                        control_queued_bytes,
                        MAX_CONTROL_EVENT_QUEUE_BYTES,
                    ),
                    RuntimeEventLane::Data => {
                        (data_sender, data_queued_bytes, MAX_DATA_EVENT_QUEUE_BYTES)
                    }
                };
                let mut current = queued_bytes.load(Ordering::Acquire);
                loop {
                    let next = current.saturating_add(bytes);
                    if next > max_bytes {
                        return Err(());
                    }
                    match queued_bytes.compare_exchange_weak(
                        current,
                        next,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    ) {
                        Ok(_) => break,
                        Err(observed) => current = observed,
                    }
                }
                if sender.try_send(event).is_err() {
                    queued_bytes.fetch_sub(bytes, Ordering::AcqRel);
                    return Err(());
                }
                Ok(())
            }
            #[cfg(test)]
            Self::Unbounded(sender) => sender.send(event).map_err(|_| ()),
        }
    }
}

#[cfg(test)]
impl From<UnboundedSender<NetworkEvent>> for EventSender {
    fn from(sender: UnboundedSender<NetworkEvent>) -> Self {
        Self::Unbounded(sender)
    }
}

impl EventReceiver {
    fn release(&self, event: &NetworkEvent) {
        let counter = match BoundedEventLanes::classify(event) {
            RuntimeEventLane::Control => &self.control_queued_bytes,
            RuntimeEventLane::Data => &self.data_queued_bytes,
        };
        counter.fetch_sub(event.encoded_len(), Ordering::AcqRel);
    }

    fn received(&mut self, event: NetworkEvent) -> NetworkEvent {
        match BoundedEventLanes::classify(&event) {
            RuntimeEventLane::Control => {
                self.consecutive_control = self.consecutive_control.saturating_add(1);
            }
            RuntimeEventLane::Data => {
                self.consecutive_control = 0;
            }
        }
        self.release(&event);
        event
    }

    pub(crate) fn try_recv(&mut self) -> Option<NetworkEvent> {
        if self.consecutive_control >= MAX_CONSECUTIVE_CONTROL_EVENTS {
            if let Ok(event) = self.data_receiver.try_recv() {
                return Some(self.received(event));
            }
        }
        if let Ok(event) = self.control_receiver.try_recv() {
            return Some(self.received(event));
        }
        self.data_receiver
            .try_recv()
            .ok()
            .map(|event| self.received(event))
    }

    pub(crate) async fn recv(&mut self) -> Option<NetworkEvent> {
        loop {
            if let Some(event) = self.try_recv() {
                return Some(event);
            }
            if self.control_closed && self.data_closed {
                return None;
            }

            let prefer_data = self.consecutive_control >= MAX_CONSECUTIVE_CONTROL_EVENTS;
            let (event, lane) = match (self.control_closed, self.data_closed, prefer_data) {
                (true, false, _) => (self.data_receiver.recv().await, RuntimeEventLane::Data),
                (false, true, _) => (
                    self.control_receiver.recv().await,
                    RuntimeEventLane::Control,
                ),
                (false, false, true) => {
                    tokio::select! {
                        biased;
                        event = self.data_receiver.recv() => (event, RuntimeEventLane::Data),
                        event = self.control_receiver.recv() => (event, RuntimeEventLane::Control),
                    }
                }
                (false, false, false) => {
                    tokio::select! {
                        biased;
                        event = self.control_receiver.recv() => (event, RuntimeEventLane::Control),
                        event = self.data_receiver.recv() => (event, RuntimeEventLane::Data),
                    }
                }
                (true, true, _) => unreachable!(),
            };
            match event {
                Some(event) => return Some(self.received(event)),
                None => match lane {
                    RuntimeEventLane::Control => self.control_closed = true,
                    RuntimeEventLane::Data => self.data_closed = true,
                },
            }
        }
    }
}

#[cfg(test)]
#[path = "tests/runtime_event_lanes.rs"]
mod tests;
