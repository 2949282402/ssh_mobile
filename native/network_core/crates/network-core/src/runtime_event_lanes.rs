//! Runtime event classification, byte admission, and bounded lane scheduling.

use network_protocol::{network_event, NetworkEvent};
use prost::Message;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
#[cfg(test)]
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{mpsc, Notify};

/// Native events are split before FFI polling so terminal command results
/// cannot be dropped behind lifecycle or data traffic.
pub(crate) const RESULT_EVENT_MAILBOX_CAPACITY: usize = 256;
pub(crate) const CONTROL_EVENT_MAILBOX_CAPACITY: usize = 256;
pub(crate) const DATA_EVENT_MAILBOX_CAPACITY: usize = 128;
pub(crate) const MAX_RESULT_EVENT_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_CONTROL_EVENT_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_DATA_EVENT_QUEUE_BYTES: usize = 8 * 1024 * 1024;
/// Compatibility names retained by the frozen protocol contract inventory;
/// actual limits are enforced independently by the three lanes above.
#[allow(dead_code)]
pub(crate) const EVENT_MAILBOX_CAPACITY: usize = CONTROL_EVENT_MAILBOX_CAPACITY;
#[allow(dead_code)]
pub(crate) const MAX_EVENT_QUEUE_BYTES: usize =
    MAX_RESULT_EVENT_QUEUE_BYTES + MAX_CONTROL_EVENT_QUEUE_BYTES + MAX_DATA_EVENT_QUEUE_BYTES;
pub(crate) const MAX_EVENT_BYTES: usize = 1024 * 1024;
pub(crate) const RESULT_EVENT_BURST: usize = 8;
pub(crate) const CONTROL_EVENT_BURST: usize = 8;
pub(crate) const DATA_EVENT_BURST: usize = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeEventLane {
    Result,
    Control,
    Data,
}

impl RuntimeEventLane {
    fn next(self) -> Self {
        match self {
            Self::Result => Self::Control,
            Self::Control => Self::Data,
            Self::Data => Self::Result,
        }
    }

    fn burst(self) -> usize {
        match self {
            Self::Result => RESULT_EVENT_BURST,
            Self::Control => CONTROL_EVENT_BURST,
            Self::Data => DATA_EVENT_BURST,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EventSendError {
    Closed,
    TooLarge,
    WrongLane,
}

/// Owns the runtime's event-lane policy and constructs the paired endpoints.
pub(crate) struct BoundedEventLanes;

impl BoundedEventLanes {
    fn classify(event: &NetworkEvent) -> RuntimeEventLane {
        match event.payload.as_ref() {
            Some(network_event::Payload::CommandResultV2(_)) => RuntimeEventLane::Result,
            Some(network_event::Payload::TransferProgress(_))
            | Some(network_event::Payload::PeerTransferProgress(_))
            | Some(network_event::Payload::ChannelMessage(_))
            | Some(network_event::Payload::SshStreamDataReceived(_)) => RuntimeEventLane::Data,
            _ => RuntimeEventLane::Control,
        }
    }

    pub(crate) fn channel() -> (EventSender, EventReceiver) {
        let (result_sender, result_receiver) = mpsc::channel(RESULT_EVENT_MAILBOX_CAPACITY);
        let (control_sender, control_receiver) = mpsc::channel(CONTROL_EVENT_MAILBOX_CAPACITY);
        let (data_sender, data_receiver) = mpsc::channel(DATA_EVENT_MAILBOX_CAPACITY);
        let result_queued_bytes = Arc::new(AtomicUsize::new(0));
        let control_queued_bytes = Arc::new(AtomicUsize::new(0));
        let data_queued_bytes = Arc::new(AtomicUsize::new(0));
        let result_bytes_released = Arc::new(Notify::new());
        (
            EventSender::Bounded {
                result_sender,
                control_sender,
                data_sender,
                result_queued_bytes: Arc::clone(&result_queued_bytes),
                control_queued_bytes: Arc::clone(&control_queued_bytes),
                data_queued_bytes: Arc::clone(&data_queued_bytes),
                result_bytes_released: Arc::clone(&result_bytes_released),
            },
            EventReceiver {
                result_receiver,
                control_receiver,
                data_receiver,
                result_queued_bytes,
                control_queued_bytes,
                data_queued_bytes,
                result_bytes_released,
                scheduled_lane: RuntimeEventLane::Result,
                scheduled_burst: 0,
                result_closed: false,
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
        result_sender: mpsc::Sender<NetworkEvent>,
        control_sender: mpsc::Sender<NetworkEvent>,
        data_sender: mpsc::Sender<NetworkEvent>,
        result_queued_bytes: Arc<AtomicUsize>,
        control_queued_bytes: Arc<AtomicUsize>,
        data_queued_bytes: Arc<AtomicUsize>,
        result_bytes_released: Arc<Notify>,
    },
    #[cfg(test)]
    Unbounded(tokio::sync::mpsc::UnboundedSender<NetworkEvent>),
}

pub(crate) struct EventReceiver {
    result_receiver: mpsc::Receiver<NetworkEvent>,
    control_receiver: mpsc::Receiver<NetworkEvent>,
    data_receiver: mpsc::Receiver<NetworkEvent>,
    result_queued_bytes: Arc<AtomicUsize>,
    control_queued_bytes: Arc<AtomicUsize>,
    data_queued_bytes: Arc<AtomicUsize>,
    result_bytes_released: Arc<Notify>,
    scheduled_lane: RuntimeEventLane,
    scheduled_burst: usize,
    result_closed: bool,
    control_closed: bool,
    data_closed: bool,
}

struct QueuedByteReservation {
    counter: Arc<AtomicUsize>,
    bytes: usize,
    committed: bool,
    released: Option<Arc<Notify>>,
}

impl QueuedByteReservation {
    fn try_new(
        counter: Arc<AtomicUsize>,
        bytes: usize,
        limit: usize,
        released: Option<Arc<Notify>>,
    ) -> Option<Self> {
        let mut current = counter.load(Ordering::Acquire);
        loop {
            let next = current.saturating_add(bytes);
            if next > limit {
                return None;
            }
            match counter.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => {
                    return Some(Self {
                        counter,
                        bytes,
                        committed: false,
                        released,
                    });
                }
                Err(observed) => current = observed,
            }
        }
    }

    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for QueuedByteReservation {
    fn drop(&mut self) {
        if !self.committed {
            self.counter.fetch_sub(self.bytes, Ordering::AcqRel);
            if let Some(released) = self.released.as_ref() {
                released.notify_waiters();
            }
        }
    }
}

impl EventSender {
    /// Best-effort bounded delivery for lifecycle, state, progress, and data
    /// events. Terminal command results must use [`Self::send_result`].
    pub(crate) fn send(&self, event: NetworkEvent) -> Result<(), ()> {
        let bytes = event.encoded_len();
        if bytes > MAX_EVENT_BYTES
            || BoundedEventLanes::classify(&event) == RuntimeEventLane::Result
        {
            return Err(());
        }
        match self {
            Self::Bounded {
                control_sender,
                data_sender,
                control_queued_bytes,
                data_queued_bytes,
                ..
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
                    RuntimeEventLane::Result => unreachable!("result lane handled above"),
                };
                let reservation = QueuedByteReservation::try_new(
                    Arc::clone(queued_bytes),
                    bytes,
                    max_bytes,
                    None,
                )
                .ok_or(())?;
                sender.try_send(event).map_err(|_| ())?;
                reservation.commit();
                Ok(())
            }
            #[cfg(test)]
            Self::Unbounded(sender) => sender.send(event).map_err(|_| ()),
        }
    }

    /// Reliably enqueue one terminal command result. Capacity and byte
    /// pressure suspend the command worker instead of dropping the event.
    pub(crate) async fn send_result(&self, event: NetworkEvent) -> Result<(), EventSendError> {
        if BoundedEventLanes::classify(&event) != RuntimeEventLane::Result {
            return Err(EventSendError::WrongLane);
        }
        let bytes = event.encoded_len();
        if bytes > MAX_EVENT_BYTES {
            return Err(EventSendError::TooLarge);
        }
        match self {
            Self::Bounded {
                result_sender,
                result_queued_bytes,
                result_bytes_released,
                ..
            } => {
                let reservation = loop {
                    let released = result_bytes_released.notified();
                    if let Some(reservation) = QueuedByteReservation::try_new(
                        Arc::clone(result_queued_bytes),
                        bytes,
                        MAX_RESULT_EVENT_QUEUE_BYTES,
                        Some(Arc::clone(result_bytes_released)),
                    ) {
                        break reservation;
                    }
                    tokio::select! {
                        () = released => {}
                        () = result_sender.closed() => return Err(EventSendError::Closed),
                    }
                };
                result_sender
                    .send(event)
                    .await
                    .map_err(|_| EventSendError::Closed)?;
                reservation.commit();
                Ok(())
            }
            #[cfg(test)]
            Self::Unbounded(sender) => sender.send(event).map_err(|_| EventSendError::Closed),
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
    fn release(&self, lane: RuntimeEventLane, event: &NetworkEvent) {
        let counter = match lane {
            RuntimeEventLane::Result => &self.result_queued_bytes,
            RuntimeEventLane::Control => &self.control_queued_bytes,
            RuntimeEventLane::Data => &self.data_queued_bytes,
        };
        counter.fetch_sub(event.encoded_len(), Ordering::AcqRel);
        if lane == RuntimeEventLane::Result {
            self.result_bytes_released.notify_waiters();
        }
    }

    fn received(&mut self, lane: RuntimeEventLane, event: NetworkEvent) -> NetworkEvent {
        if self.scheduled_lane != lane {
            self.scheduled_lane = lane;
            self.scheduled_burst = 0;
        }
        self.scheduled_burst = self.scheduled_burst.saturating_add(1);
        self.release(lane, &event);
        event
    }

    fn advance_schedule(&mut self) {
        self.scheduled_lane = self.scheduled_lane.next();
        self.scheduled_burst = 0;
    }

    fn try_recv_lane(&mut self, lane: RuntimeEventLane) -> Option<NetworkEvent> {
        let event = match lane {
            RuntimeEventLane::Result => self.result_receiver.try_recv().ok(),
            RuntimeEventLane::Control => self.control_receiver.try_recv().ok(),
            RuntimeEventLane::Data => self.data_receiver.try_recv().ok(),
        }?;
        Some(self.received(lane, event))
    }

    pub(crate) fn try_recv(&mut self) -> Option<NetworkEvent> {
        for _ in 0..3 {
            if self.scheduled_burst >= self.scheduled_lane.burst() {
                self.advance_schedule();
            }
            if let Some(event) = self.try_recv_lane(self.scheduled_lane) {
                return Some(event);
            }
            self.advance_schedule();
        }
        None
    }

    pub(crate) async fn recv(&mut self) -> Option<NetworkEvent> {
        loop {
            if let Some(event) = self.try_recv() {
                return Some(event);
            }
            if self.result_closed && self.control_closed && self.data_closed {
                return None;
            }

            let (event, lane) = tokio::select! {
                event = self.result_receiver.recv(), if !self.result_closed => {
                    (event, RuntimeEventLane::Result)
                }
                event = self.control_receiver.recv(), if !self.control_closed => {
                    (event, RuntimeEventLane::Control)
                }
                event = self.data_receiver.recv(), if !self.data_closed => {
                    (event, RuntimeEventLane::Data)
                }
            };
            match event {
                Some(event) => return Some(self.received(lane, event)),
                None => match lane {
                    RuntimeEventLane::Result => self.result_closed = true,
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
